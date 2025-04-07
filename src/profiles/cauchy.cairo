/// Contract representing `Cauchy` liquidity profile.
/// This contract facilitates mint and burn of fungible liquidity tokens
/// in pools with Cauchy liquidity profile.
#[starknet::contract]
pub mod CauchyLiquidityProfile {
    use core::felt252_div;
    use core::num::traits::Zero;
    use ekubo::interfaces::core::UpdatePositionParameters;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use spline_v0::profile::ILiquidityProfile;
    use spline_v0::profiles::bounds::ILiquidityProfileBounds;
    use spline_v0::profiles::symmetric::SymmetricLiquidityProfileComponent;
    use starknet::get_caller_address;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    component!(
        path: SymmetricLiquidityProfileComponent,
        storage: symmetric,
        event: SymmetricLiquidityProfileEvent,
    );

    #[abi(embed_v0)]
    impl SymmetricLiquidityProfileImpl =
        SymmetricLiquidityProfileComponent::SymmetricLiquidityProfile<ContractState>;

    #[storage]
    struct Storage {
        params: Map<PoolKey, (u128, i129, u64, i129)>, // l0, mu, gamma, rho
        #[substorage(v0)]
        symmetric: SymmetricLiquidityProfileComponent::Storage,
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
            assert(params.len() == 4, 'Invalid params length');
            assert(!*params[0].sign, 'Invalid liquidity factor sign');
            assert(!*params[2].sign, 'Invalid gamma sign');

            let l0: u128 = *params[0].mag;
            let mu: i129 = *params[1];
            let gamma: u64 = (*params[2].mag).try_into().unwrap();
            let rho: i129 = *params[3];
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

        fn get_liquidity_at_tick(
            ref self: ContractState, pool_key: PoolKey, liquidity_factor: i129, tick: i129,
        ) -> i129 {
            let (_, mu, gamma, _) = self.params.read(pool_key);

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

            i129 { mag: l, sign: liquidity_factor.sign }
        }

        fn get_liquidity_updates(
            ref self: ContractState, pool_key: PoolKey, liquidity_factor: i129,
        ) -> Span<UpdatePositionParameters> {
            let bounds = self.symmetric.get_bounds_for_liquidity_updates(pool_key);
            let n = bounds.len();

            // go from furthest tick out to nearest to center
            let mut updates = array![];
            let mut cumulative: i129 = Zero::<i129>::zero();
            for i in n..0 {
                let bound = bounds[i];
                // @dev use upper bound on positive tick side so discretization <= continuous curve
                // at all points
                let l = self.get_liquidity_at_tick(pool_key, liquidity_factor, *bound.upper);
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
}
