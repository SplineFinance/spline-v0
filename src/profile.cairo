#[starknet::interface]
pub trait ILiquidityProfile<TStorage> {
    // Returns the liquidity scalar used to calculate the liquidity factor on pool initialization
    fn liquidity_scalar(
        ref self: TStorage, pool_key: ekubo::types::keys::PoolKey, tick: ekubo::types::i129::i129,
    ) -> felt252;
    // Returns the name and symbol of the profile
    fn description(ref self: TStorage) -> (ByteArray, ByteArray);
    // Sets the liquidity profile parameters for a given pool key
    fn set_liquidity_profile(
        ref self: TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        params: Span<ekubo::types::i129::i129>,
    );
    // Returns the liquidity updates to add/remove liquidity for a given pool key and liquidity
    // factor
    fn get_liquidity_updates(
        ref self: TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        liquidity_factor: ekubo::types::i129::i129,
    ) -> Span<ekubo::interfaces::core::UpdatePositionParameters>;
}
