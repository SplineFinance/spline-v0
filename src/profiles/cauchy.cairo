/// Contract representing `Cauchy` liquidity profile.
/// This contract facilitates mint and burn of fungible liquidity tokens
/// in pools with Cauchy liquidity profile.
#[starknet::contract]
pub mod CauchyLiquidityProfile {
    use core::felt252_div;
    use core::num::traits::Zero;
    use ekubo::interfaces::core::UpdatePositionParameters;
    use ekubo::types::bounds::Bounds;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use spline_v0::profile::ILiquidityProfile;
    use spline_v0::profiles::symmetric::SymmetricLiquidityProfileComponent;
    use starknet::get_caller_address;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    component!(
        path: SymmetricLiquidityProfileComponent,
        storage: symmetric,
        event: SymmetricLiquidityProfileEvent,
    );

    //https://en.wikipedia.org/wiki/Approximations_of_π#:~:text=Depending%20on%20the%20purpose%20of,8·10%E2%88%928).
    const PI_NUM_FELT252: felt252 = 355;
    const PI_DENOM_FELT252: felt252 = 113;

    // TODO: fill in for actual ekubo values and not just uni v3 values * 100 (since ekubo ticks are
    // 0.01 bps)
    const MIN_TICK: i129 = i129 { mag: 88727200, sign: true };
    const MAX_TICK: i129 = i129 { mag: 88727200, sign: false };

    #[abi(embed_v0)]
    impl SymmetricLiquidityProfileImpl =
        SymmetricLiquidityProfileComponent::SymmetricLiquidityProfile<ContractState>;
    impl SymmetricLiquidityProfileInternalImpl =
        SymmetricLiquidityProfileComponent::SymmetricLiquidityProfileInternalImpl<ContractState>;

    #[storage]
    struct Storage {
        params: Map<PoolKey, (u128, i129, u64, i129)>, // l0, mu, gamma, rho
        #[substorage(v0)]
        symmetric: SymmetricLiquidityProfileComponent::Storage // s, resolution, tick_start, tick_max
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        SymmetricLiquidityProfileEvent: SymmetricLiquidityProfileComponent::Event,
    }

    #[abi(embed_v0)]
    pub impl ICauchyLiquidityProfileImpl of ILiquidityProfile<ContractState> {
        fn initial_liquidity_factor(
            ref self: ContractState, pool_key: PoolKey, initial_tick: i129,
        ) -> u128 {
            let (l0, _, _, _) = self.params.read(pool_key);
            l0
        }

        fn description(ref self: ContractState) -> (ByteArray, ByteArray) {
            ("Cauchy", "CAUCHY")
        }

        fn set_liquidity_profile(ref self: ContractState, pool_key: PoolKey, params: Span<i129>) {
            assert(pool_key.extension == get_caller_address(), 'Not extension');
            assert(params.len() == 8, 'Invalid params length');

            // first 4 params are for symmetric
            self.symmetric._set_grid_for_bounds(pool_key, params.slice(0, 4));

            // last 4 params are for cauchy
            assert(!*params[4].sign, 'Invalid params l0 sign');
            assert(!*params[6].sign, 'Invalid params gamma sign');
            let (l0, mu, gamma, rho) = (
                *params[4].mag, *params[5], (*params[6].mag).try_into().unwrap(), *params[7],
            );
            self.params.write(pool_key, (l0, mu, gamma, rho));
        }

        fn get_liquidity_profile(ref self: ContractState, pool_key: PoolKey) -> Span<i129> {
            let (l0, mu, gamma, rho) = self.params.read(pool_key);
            let l0_i129: i129 = i129 { mag: l0, sign: false };
            let mu_i129: i129 = mu;
            let gamma_i129: i129 = i129 { mag: gamma.try_into().unwrap(), sign: false };
            let rho_i129: i129 = rho;
            array![l0_i129, mu_i129, gamma_i129, rho_i129].span()
        }

        fn get_liquidity_updates(
            ref self: ContractState, pool_key: PoolKey, liquidity_factor: i129,
        ) -> Span<UpdatePositionParameters> {
            let bounds = self.symmetric.get_bounds_for_liquidity_updates(pool_key);
            let n = bounds.len();

            // full range constant base liquidity, defined by tick = rho on cauchy liquidity
            // distribution
            let (_, mu, gamma, rho) = self.params.read(pool_key);
            let lower_fr: i129 = MIN_TICK
                + i129 { mag: MIN_TICK.mag % pool_key.tick_spacing, sign: false };
            let upper_fr: i129 = MAX_TICK
                - i129 { mag: MAX_TICK.mag % pool_key.tick_spacing, sign: false };
            let mut updates = array![
                UpdatePositionParameters {
                    salt: 0,
                    bounds: Bounds { lower: lower_fr, upper: upper_fr },
                    liquidity_delta: self
                        ._get_liquidity_at_tick(
                            pool_key,
                            liquidity_factor,
                            mu,
                            gamma,
                            i129 { mag: rho.try_into().unwrap(), sign: false },
                        ),
                },
            ];

            // go from furthest tick out to nearest to center for non-constant cauchy profile
            let mut cumulative: i129 = Zero::<i129>::zero();
            for i in n..0 {
                let bound = bounds[i];
                // @dev use upper bound on positive tick side so discretization <= continuous curve
                // at all points
                let l: i129 = self
                    ._get_liquidity_at_tick(pool_key, liquidity_factor, mu, gamma, *bound.upper);
                updates
                    .append(
                        UpdatePositionParameters {
                            salt: 0, bounds: *bound, liquidity_delta: l - cumulative,
                        },
                    );
                cumulative += l;
            }
            updates.span()
        }
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        // Returns Cauchy distribution liquidity profile:
        // l(l0, gamma, tick) = (l0 / (pi * gamma)) * (1 / (1 + ((tick - mu) / gamma)^2))
        fn _get_liquidity_at_tick(
            ref self: ContractState,
            pool_key: PoolKey,
            liquidity_factor: i129,
            mu: i129,
            gamma: u64,
            tick: i129,
        ) -> i129 {
            // felt252 has max value of 2^{251} + 17 * 2^{192} + 1 or ~2**224
            let gamma_u256: u256 = gamma.try_into().unwrap();
            let shifted_tick_mag_256: u256 = (tick - mu).mag.try_into().unwrap();

            // TODO: check max tick so does not overflow (100x uni v3/v4 max_tick given ticks in
            // 0.01 bps? univ3/v4 tick_max fits in int24)
            let denom: u256 = gamma_u256 * gamma_u256 + shifted_tick_mag_256 * shifted_tick_mag_256;
            let num: u256 = gamma_u256 * gamma_u256;

            let denom_felt252: felt252 = denom.try_into().unwrap();
            let num_felt252: felt252 = num.try_into().unwrap();

            let l: u128 = (liquidity_factor.mag.try_into().unwrap()
                * felt252_div(num_felt252, denom_felt252.try_into().unwrap()))
                .try_into()
                .unwrap();

            let pi_felt252_div = felt252_div(PI_NUM_FELT252, PI_DENOM_FELT252.try_into().unwrap());
            let l_felt252: felt252 = l.try_into().unwrap();
            let l_scaled: felt252 = felt252_div(
                l_felt252, (pi_felt252_div * gamma_u256.try_into().unwrap()).try_into().unwrap(),
            );
            i129 { mag: l_scaled.try_into().unwrap(), sign: liquidity_factor.sign }
        }
    }
}
