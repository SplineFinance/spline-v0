/// Contract representing `Cauchy` liquidity profile.
/// This contract facilitates mint and burn of fungible liquidity tokens
/// in pools with Cauchy liquidity profile.
#[starknet::contract]
pub mod CauchyProfile {
    use ekubo::interfaces::core::UpdatePositionParameters;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use spline_v0::profile::ILiquidityProfile;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    struct Storage {
        params: Map<PoolKey, (i129, i129, i129, i129)> // l0, mu, gamma, rho
    }

    #[abi(embed_v0)]
    pub impl ILiquidityProfileImpl of ILiquidityProfile<ContractState> {
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

        fn get_liquidity_updates(
            ref self: ContractState, pool_key: PoolKey, liquidity_factor: i129,
        ) -> Span<UpdatePositionParameters> {
            array![].span()
        }
    }
}
