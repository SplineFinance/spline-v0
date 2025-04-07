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
        params: Map<PoolKey, (i129, i129, i129, i129)>, // l0, mu, gamma, rho
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
            0
        }

        fn description(ref self: ContractState) -> (ByteArray, ByteArray) {
            ("Cauchy", "CAUCHY")
        }

        fn set_liquidity_profile(ref self: ContractState, pool_key: PoolKey, params: Span<i129>) {}

        fn get_liquidity_profile(ref self: ContractState, pool_key: PoolKey) -> Span<i129> {
            array![].span()
        }

        fn get_liquidity_at_tick(
            ref self: ContractState, pool_key: PoolKey, liquidity_factor: i129, tick: i129,
        ) -> i129 {
            let (_, mu, gamma, _) = self.params.read(pool_key);
            let denom: u256 = gamma.mag.try_into().unwrap() * gamma.mag.try_into().unwrap()
                + (tick - mu).mag.try_into().unwrap() * (tick - mu).mag.try_into().unwrap();
            let num: u256 = gamma.mag.try_into().unwrap() * gamma.mag.try_into().unwrap();

            // TODO: check whether felt252 can overflow given from u256. if so just do a require
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
