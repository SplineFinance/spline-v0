#[starknet::interface]
pub trait ILiquidityProfile<TStorage> {
    // Returns the initial liquidity factor used on pool initialization
    // for desired initial tick to center liquidity around
    // Should be small as this is the amount of initial liquidity that will be burned
    fn initial_liquidity_factor(
        self: @TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        initial_tick: ekubo::types::i129::i129,
    ) -> u128;

    // Returns the name and symbol of the profile
    fn description(self: @TStorage) -> (ByteArray, ByteArray);

    // Sets the liquidity profile parameters for a given pool key
    fn set_liquidity_profile(
        ref self: TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        params: Span<ekubo::types::i129::i129>,
    );

    // Returns the liquidity profile parameters for a given pool key
    fn get_liquidity_profile(
        self: @TStorage, pool_key: ekubo::types::keys::PoolKey,
    ) -> Span<ekubo::types::i129::i129>;

    // Returns the liquidity updates to add/remove liquidity
    fn get_liquidity_updates(
        self: @TStorage,
        pool_key: ekubo::types::keys::PoolKey,
        liquidity_factor: ekubo::types::i129::i129,
    ) -> Span<ekubo::interfaces::core::UpdatePositionParameters>;
}
