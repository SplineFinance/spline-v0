#[starknet::interface]
pub trait ILiquidityProfileBounds<TContractState> {
    fn get_bounds_for_liquidity_updates(
        self: @TContractState, pool_key: ekubo::types::keys::PoolKey,
    ) -> Span<ekubo::types::bounds::Bounds>;
}
