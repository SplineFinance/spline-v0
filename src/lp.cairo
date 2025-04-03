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

    /// adds an amount of liquidity factor to pool with ekubo key `pool_key`
    fn add_liquidity(ref self: TStorage, pool_key: ekubo::types::keys::PoolKey, amount: u128);

    /// removes an amount of liquidity factor from pool with ekubo key `pool_key`
    fn remove_liquidity(ref self: TStorage, pool_key: ekubo::types::keys::PoolKey, amount: u128);
}

#[starknet::contract]
pub mod LiquidityProvider {
    use core::felt252_div;
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use ekubo::components::shared_locker::{
        call_core_with_callback, consume_callback_data, handle_delta,
    };
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
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_token::erc20::interface::{
        IERC20Dispatcher, IERC20DispatcherTrait, IERC20MetadataDispatcher,
        IERC20MetadataDispatcherTrait,
    };
    use openzeppelin_utils::interfaces::{
        IUniversalDeployerDispatcher, IUniversalDeployerDispatcherTrait,
    };
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ClassHash, ContractAddress, get_caller_address, get_contract_address};
    use crate::profile::{ILiquidityProfileDispatcher, ILiquidityProfileDispatcherTrait};
    use crate::token::{ILiquidityProviderTokenDispatcher, ILiquidityProviderTokenDispatcherTrait};
    use super::ILiquidityProvider;

    const UDC_ADDRESS: felt252 = 0x041a78e741e5af2fec34b695679bc6891742439f7afb8484ecd7766661ad02bf;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    pub struct Storage {
        core: ICoreDispatcher,
        profile: ILiquidityProfileDispatcher,
        pool_reserves: Map<PoolKey, (u128, u128)>,
        pool_liquidity_factors: Map<PoolKey, u128>,
        pool_tokens: Map<PoolKey, ContractAddress>,
        pool_token_class_hash: felt252,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        core: ICoreDispatcher,
        profile: ILiquidityProfileDispatcher,
        owner: ContractAddress,
        pool_token_class_hash: felt252,
    ) {
        self.ownable.initializer(owner);
        self.profile.write(profile);
        self.core.write(core);
        self.pool_token_class_hash.write(pool_token_class_hash);

        // TODO: separate fee harvester escrow or save as snapshot on ekubo so dont have issues with
        // handle_delta TODO: where transfer in assumes no balance in this contract
        core
            .set_call_points(
                CallPoints {
                    before_initialize_pool: true,
                    after_initialize_pool: true,
                    before_swap: false, // TODO: set to true with fee harvesting
                    after_swap: true,
                    before_update_position: false, // TODO: set to true with fee harvesting
                    after_update_position: true,
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
            self.ownable.assert_only_owner();
            self.check_pool_key(pool_key);

            // set liquidity profile parameters
            let profile = self.profile.read();
            profile.set_liquidity_profile(pool_key, profile_params);

            // deploy pool token erc20
            let pool_token = self.deploy_pool_token(pool_key, profile);
            self.pool_tokens.write(pool_key, pool_token);

            // initialize pool on ekubo core adding initial liquidity from profile
            let core = self.core.read();
            core.initialize_pool(pool_key, initial_tick);
        }

        fn add_liquidity(ref self: ContractState, pool_key: PoolKey, amount: u128) {
            self.check_pool_key(pool_key);
            self.check_pool_initialized(pool_key);

            // obtain core lock. should also effectively lock this contract for unique pool key
            let core = self.core.read();
            let caller = get_caller_address();
            let liquidity_factor_delta = i129 { mag: amount, sign: true };
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_factor_delta, caller));

            let pool_token = self.pool_tokens.read(pool_key);
            let total_shares = IERC20Dispatcher { contract_address: pool_token }.total_supply();
            let liquidity_factor = self.pool_liquidity_factors.read(pool_key);
            let shares = self
                .calculate_shares(total_shares, liquidity_factor_delta, liquidity_factor);

            // add amount to liquidity factor in storage
            let new_liquidity_factor = liquidity_factor + amount;
            self.pool_liquidity_factors.write(pool_key, new_liquidity_factor);

            // mint pool token shares to caller
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }.mint(caller, shares);
        }

        fn remove_liquidity(ref self: ContractState, pool_key: PoolKey, amount: u128) {
            self.check_pool_key(pool_key);
            self.check_pool_initialized(pool_key);

            // obtain core lock. should also effectively lock this contract for unique pool key
            let core = self.core.read();
            let caller = get_caller_address();
            let liquidity_factor_delta = i129 { mag: amount, sign: false };
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_factor_delta, caller));

            let pool_token = self.pool_tokens.read(pool_key);
            let total_shares = IERC20Dispatcher { contract_address: pool_token }.total_supply();
            let liquidity_factor = self.pool_liquidity_factors.read(pool_key);
            let shares = self
                .calculate_shares(total_shares, liquidity_factor_delta, liquidity_factor);

            // remove amount from liquidity factor in storage
            assert(liquidity_factor >= amount, 'Not enough liquidity');
            let new_liquidity_factor = liquidity_factor - amount;
            self.pool_liquidity_factors.write(pool_key, new_liquidity_factor);

            // burn pool token shares from caller
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }.burn(caller, shares);
        }
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn check_pool_key(ref self: ContractState, pool_key: PoolKey) {
            assert(pool_key.extension == get_contract_address(), 'Extension not this contract');
        }

        fn check_pool_initialized(ref self: ContractState, pool_key: PoolKey) {
            assert(
                self.pool_tokens.read(pool_key) != Zero::<ContractAddress>::zero(),
                'Pool token not deployed',
            );
        }

        fn get_pool_token_description(
            ref self: ContractState, pool_key: PoolKey, profile: ILiquidityProfileDispatcher,
        ) -> (ByteArray, ByteArray) {
            let (profile_name, profile_symbol) = profile.description();

            let token0_symbol = IERC20MetadataDispatcher { contract_address: pool_key.token0 }
                .symbol();
            let token1_symbol = IERC20MetadataDispatcher { contract_address: pool_key.token1 }
                .symbol();

            let name = format!(
                "Spline v0 {}/{} {} LP Token", token0_symbol, token1_symbol, profile_name,
            );
            let symbol = format!("SPLV0-{}/{}-{}-LP", token0_symbol, token1_symbol, profile_symbol);
            return (name, symbol);
        }

        fn deploy_pool_token(
            ref self: ContractState, pool_key: PoolKey, profile: ILiquidityProfileDispatcher,
        ) -> ContractAddress {
            let dispatcher = IUniversalDeployerDispatcher {
                contract_address: UDC_ADDRESS.try_into().unwrap(),
            };

            let class_hash: ClassHash = self.pool_token_class_hash.read().try_into().unwrap();
            let (name, symbol) = self.get_pool_token_description(pool_key, profile);
            let calldata = serialize::<(ByteArray, ByteArray)>(@(name, symbol)).span();
            let salt: felt252 = poseidon_hash_span(calldata);

            let pool_token = dispatcher.deploy_contract(class_hash, salt, true, calldata);
            self.pool_tokens.write(pool_key, pool_token);

            let owner = get_caller_address();
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }.initialize(owner);

            return pool_token;
        }

        fn update_positions(
            self: @ContractState, pool_key: PoolKey, liquidity_factor_delta: i129,
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
                amount0: i129 { mag: pool_reserve0, sign: true },
                amount1: i129 { mag: pool_reserve1, sign: true },
            };

            let new_reserve_delta = reserve_delta + delta;
            self
                .pool_reserves
                .write(pool_key, (new_reserve_delta.amount0.mag, new_reserve_delta.amount1.mag));
        }

        /// Calculates amount of shares to mint or burn based on liquidity delta and factor
        /// @dev total_shares, liquidity delta, and factor are values *before* liquidity delta is
        /// applied
        fn calculate_shares(
            self: @ContractState, total_shares: u256, delta: i129, factor: u128,
        ) -> u256 {
            assert(total_shares > 0, 'Total shares is 0');
            assert(factor > 0, 'Factor is 0');

            let denom: u256 = if delta.sign {
                factor.try_into().unwrap() + delta.mag.try_into().unwrap()
            } else {
                factor.try_into().unwrap()
            };
            let num: u256 = delta.mag.try_into().unwrap();
            assert(num <= denom, 'Numerator > denominator');

            // into felt for muldiv
            let denom_felt252: felt252 = denom.try_into().unwrap();
            let num_felt252: felt252 = num.try_into().unwrap();
            let total_shares_felt252: felt252 = total_shares.try_into().unwrap();

            let shares_felt252 = total_shares_felt252
                * felt252_div(num_felt252, denom_felt252.try_into().unwrap());
            return shares_felt252.try_into().unwrap();
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
            assert(caller == get_contract_address(), 'Only lp can initialize');
        }

        // adds initial liquidity to pool according to profile liquidity scalar
        fn after_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129,
        ) {
            let profile = self.profile.read();
            let initial_liquidity_factor = profile.initial_liquidity_factor(pool_key, initial_tick);

            let core = self.core.read();
            let liquidity_factor_delta = i129 { mag: initial_liquidity_factor, sign: true };
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_factor_delta, caller));

            // add liquidity factor in storage
            self.pool_liquidity_factors.write(pool_key, initial_liquidity_factor);

            // mint pool token shares to this address (burning initial lp tokens) as caller is this
            // contract
            let pool_token = self.pool_tokens.read(pool_key);
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }
                .mint(caller, initial_liquidity_factor.try_into().unwrap());
        }

        // TODO: use before and after swap to cache prior tick and final tick, then collect fees
        // TODO: for all liquidity in between
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
            self.update_reserves(pool_key, delta);
        }

        fn before_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters,
        ) {
            assert(caller == get_contract_address(), 'Only lp can update position');
        }

        fn after_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters,
            delta: Delta,
        ) {
            self.update_reserves(pool_key, delta);
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
