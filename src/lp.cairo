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

    /// compounds any existing fees on pool with ekubo key `pool_key` into the liquidity factor
    fn compound_fees(ref self: TStorage, pool_key: ekubo::types::keys::PoolKey) -> u128;

    /// adds an amount of liquidity factor to pool with ekubo key `pool_key`, minting shares to
    /// caller
    fn add_liquidity(
        ref self: TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        factor: u128,
        amount0_max: u128,
        amount1_max: u128,
    ) -> u256;

    /// removes an amount of liquidity factor from pool with ekubo key `pool_key`
    fn remove_liquidity(
        ref self: TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        shares: u256,
        amount0_min: u128,
        amount1_min: u128,
    ) -> u128;

    /// sweeps any tokens in this contract to recipient. only callable by owner
    fn sweep(
        ref self: TStorage,
        token: starknet::ContractAddress,
        recipient: starknet::ContractAddress,
        amount: u256,
    );

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

    // returns the current reserves available for swaps on pool with ekubo key `pool_key`,
    // excludes fees accumulated on pool
    fn pool_reserves(self: @TStorage, pool_key: ekubo::types::keys::PoolKey) -> (u128, u128);

    /// returns the minimum liquidity factor for pool with ekubo key `pool_key` for pool price at
    /// given tick
    fn pool_minimum_liquidity_factor(
        self: @TStorage, pool_key: ekubo::types::keys::PoolKey, tick: ekubo::types::i129::i129,
    ) -> u128;
}

#[starknet::contract]
pub mod LiquidityProvider {
    use core::cmp::min;
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use ekubo::components::owned::Owned as OwnedComponent;
    use ekubo::components::shared_locker::{call_core_with_callback, consume_callback_data};
    use ekubo::components::upgradeable::{IHasInterface, Upgradeable as UpgradeableComponent};
    use ekubo::components::util::serialize;
    use ekubo::interfaces::core::{
        ICoreDispatcher, ICoreDispatcherTrait, IExtension, ILocker, SwapParameters,
        UpdatePositionParameters,
    };
    use ekubo::interfaces::mathlib::{
        IMathLibDispatcher, IMathLibDispatcherTrait, dispatcher as math_lib_dispatcher,
    };
    use ekubo::types::bounds::Bounds;
    use ekubo::types::call_points::CallPoints;
    use ekubo::types::delta::Delta;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::{PoolKey, PositionKey};
    use ekubo::types::pool_price::PoolPrice;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_utils::interfaces::{
        IUniversalDeployerDispatcher, IUniversalDeployerDispatcherTrait,
    };
    use spline_v0::math::muldiv;
    use spline_v0::profile::{ILiquidityProfileDispatcher, ILiquidityProfileDispatcherTrait};
    use spline_v0::shared_locker::{handle_delta, try_call_core_with_callback};
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

    // @dev protocol fee denom must be > 1
    const PROTOCOL_FEE_DENOM: u128 = 2; // 50% of total swap fees
    const MAX_U128: u128 = 340282366920938463463374607431768211455; // 2**128 - 1
    const MAX_AMOUNTS: Delta = Delta {
        amount0: i129 { mag: MAX_U128, sign: false }, amount1: i129 { mag: MAX_U128, sign: false },
    };

    component!(path: OwnedComponent, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = OwnedComponent::OwnedImpl<ContractState>;
    impl OwnableImpl = OwnedComponent::OwnableImpl<ContractState>;

    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    #[abi(embed_v0)]
    impl UpgradeableImpl = UpgradeableComponent::UpgradeableImpl<ContractState>;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        profile: ILiquidityProfileDispatcher,
        pool_liquidity_factors: Map<PoolKey, u128>,
        pool_tokens: Map<PoolKey, ContractAddress>,
        pool_token_class_hash: ClassHash,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        owned: OwnedComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        LiquidityUpdated: LiquidityUpdated,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        OwnedEvent: OwnedComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct LiquidityUpdated {
        #[key]
        pub indexed_pool_key: PoolKey,
        #[key]
        pub indexed_sender: ContractAddress,
        pub pool_key: PoolKey, 
        pub sender: ContractAddress,
        pub liquidity_factor: i129,
        pub shares: u256,
        pub amount0: i129,
        pub amount1: i129,
        pub protocol_fees0: u128,
        pub protocol_fees1: u128,
    }

    #[abi(embed_v0)]
    impl HasInterfaceImpl of IHasInterface<ContractState> {
        fn get_primary_interface_id(self: @ContractState) -> felt252 {
            return selector!("spline_v0::lp::LiquidityProvider");
        }
    }

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
                    after_swap: false,
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
            // @dev initial liquidity also sets harvest fees dust limit to avoid rounding issues
            let initial_liquidity_factor = profile.initial_liquidity_factor(pool_key, initial_tick);
            let liquidity_factor_delta = i129 { mag: initial_liquidity_factor, sign: false };

            // add liquidity factor in storage
            self.pool_liquidity_factors.write(pool_key, initial_liquidity_factor);

            // add initial liquidity to pool on ekubo core
            let caller = get_caller_address();
            let shares = initial_liquidity_factor.try_into().unwrap();
            call_core_with_callback::<
                (PoolKey, i129, i129, u256, Delta, ContractAddress), (),
            >(
                core,
                @(
                    pool_key,
                    liquidity_factor_delta,
                    Zero::<i129>::zero(),
                    shares,
                    MAX_AMOUNTS,
                    caller,
                ),
            );

            // lock initial minted lp tokens forever in the pool token contract
            let pool_token = self.pool_tokens.read(pool_key);
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }
                .mint(pool_token, shares);
        }

        fn compound_fees(ref self: ContractState, pool_key: PoolKey) -> u128 {
            self.check_pool_key(pool_key);
            self.check_pool_initialized(pool_key);

            // calculate fees to collect from core and autocompound into liquidity factor
            let liquidity_fees: u128 = self.calculate_fees(pool_key);

            // obtain core lock. should also effectively lock this contract for unique pool key
            let core = self.core.read();
            let caller = get_caller_address();
            let liquidity_fees_delta = i129 { mag: liquidity_fees, sign: false };

            // use try call core so ignores if fee compounding fails due to e.g. dust fee amounts
            // with rounding issues
            let result: Option<()> = try_call_core_with_callback::<
                (PoolKey, i129, i129, u256, Delta, ContractAddress), (),
            >(
                core,
                @(
                    pool_key,
                    Zero::<i129>::zero(),
                    liquidity_fees_delta,
                    0,
                    Zero::<Delta>::zero(),
                    caller,
                ),
            );

            // if core call fails, return 0 as no fees to compound
            if result.is_none() {
                return 0;
            }

            // update liquidity factor in storage and return added liquidity factor from fees
            let liquidity_factor = self.pool_liquidity_factors.read(pool_key);
            self.pool_liquidity_factors.write(pool_key, liquidity_factor + liquidity_fees);

            liquidity_fees
        }

        fn add_liquidity(
            ref self: ContractState,
            pool_key: PoolKey,
            factor: u128,
            amount0_max: u128,
            amount1_max: u128,
        ) -> u256 {
            // compound fees if possible. also checks pool key and pool initialized
            self.compound_fees(pool_key);

            // calculate shares to mint
            let liquidity_factor_delta = i129 { mag: factor, sign: false };
            self.check_liquidity_factor_delta(pool_key, liquidity_factor_delta);

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
                (PoolKey, i129, i129, u256, Delta, ContractAddress), (),
            >(
                core,
                @(
                    pool_key,
                    liquidity_factor_delta,
                    Zero::<i129>::zero(),
                    shares,
                    Delta {
                        amount0: i129 { mag: amount0_max, sign: false },
                        amount1: i129 { mag: amount1_max, sign: false },
                    },
                    caller,
                ),
            );

            // mint pool token shares to caller
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }.mint(caller, shares);

            shares
        }

        fn remove_liquidity(
            ref self: ContractState,
            pool_key: PoolKey,
            shares: u256,
            amount0_min: u128,
            amount1_min: u128,
        ) -> u128 {
            // compound fees if possible. also checks pool key and pool initialized
            self.compound_fees(pool_key);

            // calculate liquidity factor to remove
            let pool_token = self.pool_tokens.read(pool_key);
            let total_shares = IERC20Dispatcher { contract_address: pool_token }.total_supply();
            let liquidity_factor = self.pool_liquidity_factors.read(pool_key);

            let factor = self.calculate_factor(liquidity_factor, shares, total_shares);
            let liquidity_factor_delta = i129 { mag: factor, sign: true };
            self.check_liquidity_factor_delta(pool_key, liquidity_factor_delta);

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
                (PoolKey, i129, i129, u256, Delta, ContractAddress), (),
            >(
                core,
                @(
                    pool_key,
                    liquidity_factor_delta,
                    Zero::<i129>::zero(),
                    shares,
                    Delta {
                        amount0: i129 { mag: amount0_min, sign: true },
                        amount1: i129 { mag: amount1_min, sign: true },
                    },
                    caller,
                ),
            );

            factor
        }

        fn sweep(
            ref self: ContractState,
            token: starknet::ContractAddress,
            recipient: starknet::ContractAddress,
            amount: u256,
        ) {
            self.require_owner();
            IERC20Dispatcher { contract_address: token }.transfer(recipient, amount);
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
            let core = self.core.read();
            let pool_price = core.get_pool_price(pool_key);
            let math_lib = math_lib_dispatcher();
            let profile = self.profile.read();
            let liquidity_update_params = profile
                .get_liquidity_updates(pool_key, Zero::<i129>::zero());

            let mut delta: Delta = Zero::<Delta>::zero();
            for params in liquidity_update_params {
                let position_key = PositionKey {
                    salt: (*params.salt).try_into().unwrap(), // @dev salt must fit within u64
                    owner: get_contract_address(),
                    bounds: *params.bounds,
                };
                let position = core.get_position(pool_key, position_key);
                delta += math_lib
                    .liquidity_delta_to_amount_delta(
                        pool_price.sqrt_ratio,
                        i129 { mag: position.liquidity, sign: false },
                        math_lib.tick_to_sqrt_ratio(*params.bounds.lower),
                        math_lib.tick_to_sqrt_ratio(*params.bounds.upper),
                    );
            }
            (delta.amount0.mag, delta.amount1.mag)
        }

        fn pool_minimum_liquidity_factor(
            self: @ContractState, pool_key: PoolKey, tick: i129,
        ) -> u128 {
            let profile = self.profile();
            profile.initial_liquidity_factor(pool_key, tick)
        }
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn check_pool_key(self: @ContractState, pool_key: PoolKey) {
            assert(pool_key.extension == get_contract_address(), 'Extension not this contract');
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

        fn check_liquidity_factor_delta(
            self: @ContractState, pool_key: PoolKey, liquidity_factor_delta: i129,
        ) {
            let core = self.core.read();
            let pool_price = core.get_pool_price(pool_key);
            let min_liquidity_factor = self
                .pool_minimum_liquidity_factor(pool_key, pool_price.tick);
            assert(
                liquidity_factor_delta.mag >= min_liquidity_factor, 'Liq factor delta mag < min',
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
                if (*params.liquidity_delta).is_non_zero() {
                    delta += core.update_position(pool_key, *params);
                }
            }
            return delta;
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
            let denom: u256 = total_shares;
            let num: u256 = shares;

            let total_factor_u256: u256 = total_factor.try_into().unwrap();
            let factor_u256: u256 = muldiv(total_factor_u256, num, denom);

            let factor: u128 = factor_u256.try_into().unwrap();
            factor
        }

        fn calculate_fees(ref self: ContractState, pool_key: PoolKey) -> u128 {
            let core = self.core.read();
            let profile = self.profile.read();
            let liquidity_update_params = profile
                .get_liquidity_updates(pool_key, Zero::<i129>::zero());

            // get min liquidity from profile
            let pool_price: PoolPrice = core.get_pool_price(pool_key);
            let min_liquidity_fees = self.pool_minimum_liquidity_factor(pool_key, pool_price.tick);

            let mut delta = Zero::<Delta>::zero();
            for params in liquidity_update_params {
                let position_key = PositionKey {
                    salt: (*params.salt).try_into().unwrap(), // @dev salt must fit within u64
                    owner: get_contract_address(),
                    bounds: *params.bounds,
                };
                let result = core.get_position_with_fees(pool_key, position_key);
                delta.amount0 += i129 { mag: result.fees0, sign: false };
                delta.amount1 += i129 { mag: result.fees1, sign: false };
            }

            // get min of liquidity factors could generate from fee collection
            let liquidity_factor: u128 = self.pool_liquidity_factors.read(pool_key);
            // @dev pool reserves exclude accumulated swap, protocol fees
            let (pool_reserve0, pool_reserve1): (u128, u128) = self.pool_reserves(pool_key);
            if pool_reserve0 == 0 || pool_reserve1 == 0 {
                return 0;
            }

            // fees delta to add as compounded liquidity should exclude protocol amounts
            let protocol_fees_delta = Delta {
                amount0: self.calculate_protocol_fees(delta.amount0),
                amount1: self.calculate_protocol_fees(delta.amount1),
            };
            delta -= protocol_fees_delta;

            let liquidity_fees0: u128 = self
                .calculate_factor(
                    liquidity_factor,
                    delta.amount0.mag.try_into().unwrap(),
                    pool_reserve0.try_into().unwrap(),
                );
            let liquidity_fees1: u128 = self
                .calculate_factor(
                    liquidity_factor,
                    delta.amount1.mag.try_into().unwrap(),
                    pool_reserve1.try_into().unwrap(),
                );
            let liquidity_fees: u128 = min(liquidity_fees0, liquidity_fees1);
            if (liquidity_fees < min_liquidity_fees) {
                return 0;
            }

            liquidity_fees
        }

        fn calculate_protocol_fees(ref self: ContractState, total_fees_delta: i129) -> i129 {
            let protocol_fees_delta = i129 {
                mag: total_fees_delta.mag / PROTOCOL_FEE_DENOM, sign: total_fees_delta.sign,
            };
            protocol_fees_delta
        }

        fn collect_fees(ref self: ContractState, pool_key: PoolKey) -> Delta {
            let core = self.core.read();
            let profile = self.profile.read();
            let liquidity_update_params = profile
                .get_liquidity_updates(pool_key, Zero::<i129>::zero());
            let mut delta = Zero::<Delta>::zero();
            // @dev length of returned array can cause gas cost to be high, so be careful with this
            for params in liquidity_update_params {
                delta += core.collect_fees(pool_key, *params.salt, *params.bounds);
            }
            delta
        }

        fn harvest_fees(
            ref self: ContractState, pool_key: PoolKey, liquidity_fees_delta: i129,
        ) -> (Delta, Delta) {
            if liquidity_fees_delta == Zero::<i129>::zero() {
                return (Zero::<Delta>::zero(), Zero::<Delta>::zero());
            }
            // collect fees from core and autocompound as liquidity fees on core positions
            assert(liquidity_fees_delta >= Zero::<i129>::zero(), 'Liq fees delta must be >= 0');
            let collected_fees_delta = self.collect_fees(pool_key); // negative as out from core
            let fees_delta = self
                .update_positions(pool_key, liquidity_fees_delta); // positive as in to core

            let mut excess_fees_delta = collected_fees_delta + fees_delta;
            assert(
                excess_fees_delta.amount0 <= Zero::<i129>::zero(),
                'Collected must be > added fees0',
            );
            assert(
                excess_fees_delta.amount1 <= Zero::<i129>::zero(),
                'Collected must be > added fees1',
            );

            // require protocol fees delta to be less than excess remaining
            let mut protocol_fees_delta = Zero::<Delta>::zero();
            protocol_fees_delta
                .amount0 =
                    i129 {
                        mag: fees_delta.amount0.mag / (PROTOCOL_FEE_DENOM - 1),
                        sign: fees_delta.amount0.sign,
                    };

            if protocol_fees_delta.amount0 > -excess_fees_delta.amount0 {
                protocol_fees_delta.amount0 = -excess_fees_delta.amount0;
            }

            protocol_fees_delta
                .amount1 =
                    i129 {
                        mag: fees_delta.amount1.mag / (PROTOCOL_FEE_DENOM - 1),
                        sign: fees_delta.amount1.sign,
                    };

            if protocol_fees_delta.amount1 > -excess_fees_delta.amount1 {
                protocol_fees_delta.amount1 = -excess_fees_delta.amount1;
            }

            // remove protocol fees from excess remaining and refund any back to core
            excess_fees_delta += protocol_fees_delta;
            if excess_fees_delta != Zero::<Delta>::zero() {
                // refund any excess unused collected fees back to core
                let core = self.core.read();
                let amount0: u128 = excess_fees_delta.amount0.mag;
                let amount1: u128 = excess_fees_delta.amount1.mag;
                // @dev require full range liquidity on profile so never get zero liquidity error
                let liquidity: u128 = core.get_pool_liquidity(pool_key);
                if liquidity > 0 {
                    core.accumulate_as_fees(pool_key, amount0, amount1);
                } else {
                    // sweep into protocol fees delta since no liquidity to accumulate fees into
                    protocol_fees_delta.amount0 += i129 { mag: amount0, sign: false };
                    protocol_fees_delta.amount1 += i129 { mag: amount1, sign: false };
                }
            }

            (fees_delta, protocol_fees_delta)
        }
    }

    #[abi(embed_v0)]
    impl LockedImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            let (
                pool_key,
                liquidity_factor_delta,
                liquidity_fees_delta,
                shares,
                amounts_limit,
                caller,
            ) =
                consume_callback_data::<
                (PoolKey, i129, i129, u256, Delta, ContractAddress),
            >(core, data);

            // harvest fees from core
            let (_, protocol_fees_delta) = self.harvest_fees(pool_key, liquidity_fees_delta);

            // modify liquidity profile positions on ekubo core
            let balance_delta = self.update_positions(pool_key, liquidity_factor_delta);

            // check slippage limits if liquidity factor delta is non-zero
            assert(
                liquidity_factor_delta.is_zero() || balance_delta.amount0 <= amounts_limit.amount0,
                'Slippage exceeded on amount0',
            );
            assert(
                liquidity_factor_delta.is_zero() || balance_delta.amount1 <= amounts_limit.amount1,
                'Slippage exceeded on amount1',
            );

            // settle up balance deltas with core
            handle_delta(core, pool_key.token0, balance_delta.amount0, caller);
            handle_delta(core, pool_key.token1, balance_delta.amount1, caller);

            // negative as used same sign as fees delta which autocompounds in to core
            let owner = self.owned.get_owner();
            handle_delta(core, pool_key.token0, -protocol_fees_delta.amount0, owner);
            handle_delta(core, pool_key.token1, -protocol_fees_delta.amount1, owner);

            self
                .emit(
                    LiquidityUpdated {
                        indexed_pool_key: pool_key,
                        indexed_sender: caller,
                        pool_key: pool_key,
                        sender: caller,
                        liquidity_factor: liquidity_factor_delta,
                        shares: shares,
                        amount0: balance_delta.amount0,
                        amount1: balance_delta.amount1,
                        protocol_fees0: protocol_fees_delta.amount0.mag,
                        protocol_fees1: protocol_fees_delta.amount1.mag,
                    },
                );

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
            panic!("Not used");
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
