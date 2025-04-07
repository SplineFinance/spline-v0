#[starknet::contract]
pub mod TestSymmetricLiquidityProfile {
    use spline_v0::profiles::symmetric::SymmetricLiquidityProfileComponent;

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
        #[substorage(v0)]
        symmetric: SymmetricLiquidityProfileComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        SymmetricLiquidityProfileEvent: SymmetricLiquidityProfileComponentt::Event,
    }
}
