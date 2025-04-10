#[starknet::interface]
pub trait ILiquidityProvider<TStorage> {
    /// creates and initializes a pool with ekubo key `pool_key` with initial tick `initial_tick`.
    /// only owner of liquidity provider can initialize
    fn create_and_initialize_pool(
        ref self: TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        initial_tick: ekubo::types::i129::i129,
        profile_params: Span<ekubo::types::i129::i129>,
    );

    /// adds an amount of liquidity factor to pool with ekubo key `pool_key`, minting shares to
    /// caller
    fn add_liquidity(
        ref self: TStorage, pool_key: ekubo::types::keys::PoolKey, factor: u128,
    ) -> u256;

    /// removes an amount of liquidity factor from pool with ekubo key `pool_key`
    fn remove_liquidity(
        ref self: TStorage, pool_key: ekubo::types::keys::PoolKey, shares: u256,
    ) -> u128;

    /// returns the ekubo core for pools deployed by this liquidity provider
    fn core(self: @TStorage) -> ekubo::interfaces::core::ICoreDispatcher;

    /// returns the profile for pools deployed by this liquidity provider
    fn profile(self: @TStorage) -> spline_v0::profile::ILiquidityProfileDispatcher;

    /// returns the liquidity provider token for pool with ekubo key `pool_key`
    fn pool_token(
        self: @TStorage, pool_key: ekubo::types::keys::PoolKey,
    ) -> starknet::ContractAddress;

    // returns the current liquidity factor for pool with ekubo key `pool_key`
    fn pool_liquidity_factor(self: @TStorage, pool_key: ekubo::types::keys::PoolKey) -> u128;

    // returns the current reserves added by liquidity provider for pool with ekubo key `pool_key`
    fn pool_reserves(self: @TStorage, pool_key: ekubo::types::keys::PoolKey) -> (u128, u128);
}

#[starknet::contract]
pub mod LiquidityProvider {
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use ekubo::components::owned::Owned as OwnedComponent;
    use ekubo::components::shared_locker::{
        call_core_with_callback, check_caller_is_core, consume_callback_data, handle_delta,
    };
    use ekubo::components::upgradeable::{IHasInterface, Upgradeable as UpgradeableComponent};
    use ekubo::components::util::serialize;
    use ekubo::interfaces::core::{
        ICoreDispatcher, ICoreDispatcherTrait, IExtension, ILocker, SwapParameters,
        UpdatePositionParameters,
    };
    use ekubo::types::bounds::Bounds;
    use ekubo::types::call_points::CallPoints;
    use ekubo::types::delta::Delta;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_utils::interfaces::{
        IUniversalDeployerDispatcher, IUniversalDeployerDispatcherTrait,
    };
    use spline_v0::math::muldiv;
    use spline_v0::profile::{ILiquidityProfileDispatcher, ILiquidityProfileDispatcherTrait};
    use spline_v0::sweep::SweepableComponent;
    use spline_v0::token::{
        ILiquidityProviderTokenDispatcher, ILiquidityProviderTokenDispatcherTrait,
    };
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ClassHash, ContractAddress, get_caller_address, get_contract_address};
    use super::ILiquidityProvider;

    const UDC_ADDRESS: felt252 = 0x04a64cd09a853868621d94cae9952b106f2c36a3f81260f85de6696c6b050221;

    component!(path: OwnedComponent, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = OwnedComponent::OwnedImpl<ContractState>;
    impl OwnableImpl = OwnedComponent::OwnableImpl<ContractState>;

    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    #[abi(embed_v0)]
    impl UpgradeableImpl = UpgradeableComponent::UpgradeableImpl<ContractState>;

    component!(path: SweepableComponent, storage: sweepable, event: SweepableEvent);
    #[abi(embed_v0)]
    impl SweepableImpl = SweepableComponent::Sweepable<ContractState>;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        profile: ILiquidityProfileDispatcher,
        pool_reserves: Map<PoolKey, (u128, u128)>,
        pool_liquidity_factors: Map<PoolKey, u128>,
        pool_tokens: Map<PoolKey, ContractAddress>,
        pool_token_class_hash: ClassHash,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        owned: OwnedComponent::Storage,
        #[substorage(v0)]
        sweepable: SweepableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        OwnedEvent: OwnedComponent::Event,
        SweepableEvent: SweepableComponent::Event,
    }

    #[abi(embed_v0)]
    impl HasInterfaceImpl of IHasInterface<ContractState> {
        fn get_primary_interface_id(self: @ContractState) -> felt252 {
            return selector!("spline_v0::lp::LiquidityProvider");
        }
    }

    // TODO: handle swap fees fungibly with protocol fee rate charged
    // TODO: should revert if balance delta is zero
    #[constructor]
    fn constructor(
        ref self: ContractState,
        core: ICoreDispatcher,
        profile: ILiquidityProfileDispatcher,
        owner: ContractAddress,
        pool_token_class_hash: ClassHash,
    ) {
        self.initialize_owned(owner);
        self.profile.write(profile);
        self.core.write(core);
        self.pool_token_class_hash.write(pool_token_class_hash);

        core
            .set_call_points(
                CallPoints {
                    before_initialize_pool: true,
                    after_initialize_pool: false,
                    before_swap: false,
                    after_swap: true,
                    before_update_position: true,
                    after_update_position: false,
                    before_collect_fees: false,
                    after_collect_fees: false,
                },
            );
    }

    #[abi(embed_v0)]
    pub impl LiquidityProviderImpl of ILiquidityProvider<ContractState> {
        fn create_and_initialize_pool(
            ref self: ContractState,
            pool_key: PoolKey,
            initial_tick: i129,
            profile_params: Span<i129>,
        ) {
            self.require_owner();
            self.check_pool_key(pool_key);
            self.check_pool_not_initialized(pool_key);

            // set liquidity profile parameters
            let profile = self.profile.read();
            profile.set_liquidity_profile(pool_key, profile_params);

            // deploy pool token erc20
            let pool_token = self.deploy_pool_token(pool_key, profile);
            self.pool_tokens.write(pool_key, pool_token);

            // initialize pool on ekubo core adding initial liquidity from profile
            let core = self.core.read();
            core.initialize_pool(pool_key, initial_tick);

            // initial tick is tick want to center liquidity around
            let initial_liquidity_factor = profile.initial_liquidity_factor(pool_key, initial_tick);
            let liquidity_factor_delta = i129 { mag: initial_liquidity_factor, sign: false };

            // add liquidity factor in storage
            self.pool_liquidity_factors.write(pool_key, initial_liquidity_factor);

            // add initial liquidity to pool on ekubo core
            let caller = get_caller_address();
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_factor_delta, caller));

            // lock initial minted lp tokens forever in this contract
            let pool_token = self.pool_tokens.read(pool_key);
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }
                .mint(get_contract_address(), initial_liquidity_factor.try_into().unwrap());
        }

        fn add_liquidity(ref self: ContractState, pool_key: PoolKey, factor: u128) -> u256 {
            self.check_pool_key(pool_key);
            self.check_pool_initialized(pool_key);

            // calculate shares to mint
            let liquidity_factor_delta = i129 { mag: factor, sign: false };
            let pool_token = self.pool_tokens.read(pool_key);
            let total_shares = IERC20Dispatcher { contract_address: pool_token }.total_supply();

            let liquidity_factor = self.pool_liquidity_factors.read(pool_key);
            let shares = self.calculate_shares(total_shares, factor, liquidity_factor);

            // add amount to liquidity factor in storage
            let new_liquidity_factor = liquidity_factor + factor;
            self.pool_liquidity_factors.write(pool_key, new_liquidity_factor);

            // obtain core lock. should also effectively lock this contract for unique pool key
            let core = self.core.read();
            let caller = get_caller_address();
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_factor_delta, caller));

            // mint pool token shares to caller
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }.mint(caller, shares);

            shares
        }

        fn remove_liquidity(ref self: ContractState, pool_key: PoolKey, shares: u256) -> u128 {
            self.check_pool_key(pool_key);
            self.check_pool_initialized(pool_key);

            // calculate liquidity factor to remove
            let pool_token = self.pool_tokens.read(pool_key);
            let total_shares = IERC20Dispatcher { contract_address: pool_token }.total_supply();
            let liquidity_factor = self.pool_liquidity_factors.read(pool_key);

            let factor = self.calculate_factor(liquidity_factor, shares, total_shares);
            let liquidity_factor_delta = i129 { mag: factor, sign: true };

            // remove amount from liquidity factor in storage
            assert(liquidity_factor >= factor, 'Not enough liquidity');
            let new_liquidity_factor = liquidity_factor - factor;
            self.pool_liquidity_factors.write(pool_key, new_liquidity_factor);

            // burn pool token shares from caller
            let caller = get_caller_address();
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }.burn(caller, shares);

            // obtain core lock. should also effectively lock this contract for unique pool key
            let core = self.core.read();
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_factor_delta, caller));

            factor
        }

        fn core(self: @ContractState) -> ICoreDispatcher {
            self.core.read()
        }

        fn profile(self: @ContractState) -> ILiquidityProfileDispatcher {
            self.profile.read()
        }

        fn pool_token(self: @ContractState, pool_key: PoolKey) -> ContractAddress {
            self.pool_tokens.read(pool_key)
        }

        fn pool_liquidity_factor(self: @ContractState, pool_key: PoolKey) -> u128 {
            self.pool_liquidity_factors.read(pool_key)
        }

        fn pool_reserves(self: @ContractState, pool_key: PoolKey) -> (u128, u128) {
            self.pool_reserves.read(pool_key)
        }
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn check_pool_key(self: @ContractState, pool_key: PoolKey) {
            assert(pool_key.extension == get_contract_address(), 'Extension not this contract');
            assert(pool_key.fee == 0, 'Pool key fee not zero');
        }

        fn check_pool_initialized(self: @ContractState, pool_key: PoolKey) {
            assert(
                self.pool_tokens.read(pool_key) != Zero::<ContractAddress>::zero(),
                'Pool token not deployed',
            );
        }

        fn check_pool_not_initialized(self: @ContractState, pool_key: PoolKey) {
            assert(
                self.pool_tokens.read(pool_key) == Zero::<ContractAddress>::zero(),
                'Pool token already deployed',
            );
        }

        fn get_pool_token_description(
            self: @ContractState, pool_key: PoolKey, profile: ILiquidityProfileDispatcher,
        ) -> (ByteArray, ByteArray) {
            let (profile_name, profile_symbol) = profile.description();
            let name = format!("Spline v0 {} LP Token", profile_name);
            let symbol = format!("SPLV0-{}-LP", profile_symbol);
            return (name, symbol);
        }

        fn deploy_pool_token(
            ref self: ContractState, pool_key: PoolKey, profile: ILiquidityProfileDispatcher,
        ) -> ContractAddress {
            let dispatcher = IUniversalDeployerDispatcher {
                contract_address: UDC_ADDRESS.try_into().unwrap(),
            };
            let class_hash: ClassHash = self.pool_token_class_hash.read();
            let (name, symbol) = self.get_pool_token_description(pool_key, profile);
            let calldata = serialize::<(PoolKey, ByteArray, ByteArray)>(@(pool_key, name, symbol))
                .span();

            let salt: felt252 = poseidon_hash_span(calldata);
            let pool_token = dispatcher.deploy_contract(class_hash, salt, false, calldata);
            return pool_token;
        }

        fn update_positions(
            ref self: ContractState, pool_key: PoolKey, liquidity_factor_delta: i129,
        ) -> Delta {
            let core = self.core.read();
            let profile = self.profile.read();
            let liquidity_update_params = profile
                .get_liquidity_updates(pool_key, liquidity_factor_delta);

            let mut delta = Zero::<Delta>::zero();
            // @dev length of returned array can cause gas cost to be high, so be careful with this
            for params in liquidity_update_params {
                delta += core.update_position(pool_key, *params);
            }
            return delta;
        }

        fn update_reserves(ref self: ContractState, pool_key: PoolKey, delta: Delta) {
            // update reserves in pool
            let (pool_reserve0, pool_reserve1) = self.pool_reserves.read(pool_key);
            let reserve_delta = Delta {
                amount0: i129 { mag: pool_reserve0, sign: false },
                amount1: i129 { mag: pool_reserve1, sign: false },
            };

            let new_reserve_delta = reserve_delta + delta;
            self
                .pool_reserves
                .write(pool_key, (new_reserve_delta.amount0.mag, new_reserve_delta.amount1.mag));
        }

        /// Calculates amount of shares to mint based on factor and total factor
        /// @dev total_shares, factor, and total_factor are values *before* delta applied
        fn calculate_shares(
            self: @ContractState, total_shares: u256, factor: u128, total_factor: u128,
        ) -> u256 {
            assert(total_factor > 0, 'Total factor is 0');
            let denom: u256 = total_factor.try_into().unwrap();
            let num: u256 = factor.try_into().unwrap();
            let shares: u256 = muldiv(total_shares, num, denom);
            shares
        }

        /// Calculates amount of factor to remove based on shares and total shares
        /// @dev total_factor, shares, and total_shares are values *before* delta applied
        fn calculate_factor(
            self: @ContractState, total_factor: u128, shares: u256, total_shares: u256,
        ) -> u128 {
            assert(total_shares > 0, 'Total shares is 0');
            let denom: u256 = total_shares.try_into().unwrap();
            let num: u256 = shares.try_into().unwrap();

            let total_factor_u256: u256 = total_factor.try_into().unwrap();
            let factor_u256: u256 = muldiv(total_factor_u256, num, denom);

            let factor: u128 = factor_u256.try_into().unwrap();
            factor
        }
    }

    #[abi(embed_v0)]
    impl LockedImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            let (pool_key, liquidity_factor_delta, caller) = consume_callback_data::<
                (PoolKey, i129, ContractAddress),
            >(core, data);

            // modify liquidity profile positions on ekubo core
            let balance_delta = self.update_positions(pool_key, liquidity_factor_delta);

            // update tracked reserves in storage
            self.update_reserves(pool_key, balance_delta);

            // settle up balance deltas with core
            handle_delta(core, pool_key.token0, balance_delta.amount0, caller);
            handle_delta(core, pool_key.token1, balance_delta.amount1, caller);

            array![].span()
        }
    }

    #[abi(embed_v0)]
    impl ExtensionImpl of IExtension<ContractState> {
        fn before_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129,
        ) {
            panic!("Only from liquidity provider");
        }

        fn after_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129,
        ) {
            panic!("Not used");
        }

        fn before_swap(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: SwapParameters,
        ) {
            panic!("Not used");
        }

        fn after_swap(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: SwapParameters,
            delta: Delta,
        ) {
            let core = self.core.read();
            check_caller_is_core(core);
            self.update_reserves(pool_key, delta);
        }

        fn before_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters,
        ) {
            panic!("Only from liquidity provider");
        }

        fn after_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters,
            delta: Delta,
        ) {
            panic!("Not used");
        }

        fn before_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds,
        ) {
            panic!("Not used");
        }
        fn after_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds,
            delta: Delta,
        ) {
            panic!("Not used");
        }
    }
}
