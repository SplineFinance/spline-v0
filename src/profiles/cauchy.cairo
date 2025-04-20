/// Contract representing `Cauchy` liquidity profile.
/// This contract facilitates mint and burn of fungible liquidity tokens
/// in pools with Cauchy liquidity profile.
#[starknet::contract]
pub mod CauchyLiquidityProfile {
    use core::num::traits::Zero;
    use ekubo::interfaces::core::UpdatePositionParameters;
    use ekubo::types::bounds::Bounds;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use spline_v0::math::muldiv;
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
    const PI_NUM_U256: u256 = 355;
    const PI_DENOM_U256: u256 = 113;

    const MIN_TICK: i129 = i129 { mag: 88722883, sign: true };
    const MAX_TICK: i129 = i129 { mag: 88722883, sign: false };

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
            self: @ContractState, pool_key: PoolKey, initial_tick: i129,
        ) -> u128 {
            let (l0, _, _, _) = self.params.read(pool_key);
            l0
        }

        fn description(self: @ContractState) -> (ByteArray, ByteArray) {
            ("Cauchy", "CAUCHY")
        }

        fn set_liquidity_profile(ref self: ContractState, pool_key: PoolKey, params: Span<i129>) {
            assert(pool_key.extension == get_caller_address(), 'Not extension');
            assert(params.len() == 8, 'Invalid params length');

            // first 4 params are for symmetric
            self.symmetric._set_grid_for_bounds(pool_key, params.slice(0, 4));

            // last 4 params are for cauchy
            assert(!*params[4].sign, 'Invalid params l0 sign');
            assert(
                *params[5].mag == *params[2].mag && *params[5].sign == *params[2].sign,
                'mu != symmetric::tick_start',
            );
            assert(!*params[6].sign, 'Invalid params gamma sign');
            let (l0, mu, gamma, rho) = (
                *params[4].mag, *params[5], (*params[6].mag).try_into().unwrap(), *params[7],
            );
            self.params.write(pool_key, (l0, mu, gamma, rho));
        }

        fn get_liquidity_profile(self: @ContractState, pool_key: PoolKey) -> Span<i129> {
            let (s, res, tick_start, tick_max) = self.symmetric._get_grid(pool_key);
            let s_i129: i129 = i129 { mag: s, sign: false };
            let res_i129: i129 = i129 { mag: res, sign: false };
            let tick_start_i129: i129 = tick_start;
            let tick_max_i129: i129 = tick_max;

            let (l0, mu, gamma, rho) = self.params.read(pool_key);
            let l0_i129: i129 = i129 { mag: l0, sign: false };
            let mu_i129: i129 = mu;
            let gamma_i129: i129 = i129 { mag: gamma.try_into().unwrap(), sign: false };
            let rho_i129: i129 = rho;

            array![
                s_i129,
                res_i129,
                tick_start_i129,
                tick_max_i129,
                l0_i129,
                mu_i129,
                gamma_i129,
                rho_i129,
            ]
                .span()
        }

        fn get_liquidity_updates(
            self: @ContractState, pool_key: PoolKey, liquidity_factor: i129,
        ) -> Span<UpdatePositionParameters> {
            let bounds = self.symmetric.get_bounds_for_liquidity_updates(pool_key);

            // full range constant base liquidity, defined by tick = rho on cauchy liquidity
            // distribution
            let (_, mu, gamma, rho) = self.params.read(pool_key);
            let lower_fr: i129 = MIN_TICK
                + i129 { mag: MIN_TICK.mag % pool_key.tick_spacing, sign: false };
            let upper_fr: i129 = MAX_TICK
                - i129 { mag: MAX_TICK.mag % pool_key.tick_spacing, sign: false };

            let mut updates = array![];
            let liquidity_delta_fr = self
                ._get_liquidity_at_tick(pool_key, liquidity_factor, mu, gamma, rho);
            updates
                .append(
                    UpdatePositionParameters {
                        salt: 0,
                        bounds: Bounds { lower: lower_fr, upper: upper_fr },
                        liquidity_delta: liquidity_delta_fr,
                    },
                );

            // go from furthest tick out to nearest to center for non-constant cauchy profile
            let n = bounds.len();
            let mut prior: i129 = Zero::<i129>::zero();
            for i in 0..n {
                let j = n - i - 1;
                let bound = bounds[j];
                // @dev use lower bound given pool.liquidity = sum over liquidity deltas up to and
                // including current pool tick, so upper = -bound.lower + pool_key.tick_spacing
                let l: i129 = self
                    ._get_liquidity_at_tick(pool_key, liquidity_factor, mu, gamma, *bound.lower);
                updates
                    .append(
                        UpdatePositionParameters {
                            salt: 0, bounds: *bound, liquidity_delta: l - prior,
                        },
                    );
                prior = l;
            }

            updates.span()
        }
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        // Returns Cauchy distribution liquidity profile:
        // l(l0, gamma, tick) = (l0 / (pi * gamma)) * (1 / (1 + ((tick - mu) / gamma)^2))
        fn _get_liquidity_at_tick(
            self: @ContractState,
            pool_key: PoolKey,
            liquidity_factor: i129,
            mu: i129,
            gamma: u64,
            tick: i129,
        ) -> i129 {
            let gamma_u256: u256 = gamma.try_into().unwrap();
            let shifted_tick_mag_256: u256 = (tick - mu).mag.try_into().unwrap();

            let denom: u256 = gamma_u256 * gamma_u256 + shifted_tick_mag_256 * shifted_tick_mag_256;
            let num: u256 = gamma_u256 * gamma_u256;

            let liquidity_factor_u256: u256 = liquidity_factor.mag.try_into().unwrap();
            let l_u256: u256 = muldiv(liquidity_factor_u256, num, denom);

            let l_scaled_u256: u256 = muldiv(l_u256, PI_DENOM_U256, PI_NUM_U256 * gamma_u256);
            let l_scaled: u128 = l_scaled_u256.try_into().unwrap();
            i129 { mag: l_scaled, sign: liquidity_factor.sign }
        }
    }
}
