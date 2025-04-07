#[starknet::interface]
pub trait ITestSymmetricLiquidityProfile<TContractState> {
    fn set_grid_for_bounds(
        ref self: TContractState,
        pool_key: ekubo::types::keys::PoolKey,
        params: Span<ekubo::types::i129::i129>,
    );
}

#[starknet::contract]
pub mod TestSymmetricLiquidityProfile {
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use spline_v0::profiles::symmetric::SymmetricLiquidityProfileComponent;
    use spline_v0::profiles::test_symmetric::ITestSymmetricLiquidityProfile;

    component!(
        path: SymmetricLiquidityProfileComponent,
        storage: symmetric,
        event: SymmetricLiquidityProfileEvent,
    );

    #[abi(embed_v0)]
    impl SymmetricLiquidityProfileImpl =
        SymmetricLiquidityProfileComponent::SymmetricLiquidityProfile<ContractState>;
    impl SymmetricLiquidityProfileInternalImpl =
        SymmetricLiquidityProfileComponent::SymmetricLiquidityProfileInternalImpl<ContractState>;

    #[storage]
    struct Storage {
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
    pub impl TestSymmetricLiquidityProfileImpl of ITestSymmetricLiquidityProfile<ContractState> {
        fn set_grid_for_bounds(ref self: ContractState, pool_key: PoolKey, params: Span<i129>) {
            self.symmetric._set_grid_for_bounds(pool_key, params);
        }
    }
}
