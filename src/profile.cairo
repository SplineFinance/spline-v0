#[starknet::interface]
pub trait ILiquidityProfile<TStorage> {
    fn set_liquidity_profile(
        ref self: TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        params: Span<ekubo::types::i129::i129>,
    );
    fn get_liquidity_updates(
        ref self: TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        liquidity_factor: ekubo::types::i129::i129,
    ) -> Span<ekubo::interfaces::core::UpdatePositionParameters>;
}
