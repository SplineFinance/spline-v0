#[starknet::contract]
pub mod TestSweepable {
    use spline_v0::sweep::SweepableComponent;

    component!(path: SweepableComponent, storage: sweepable, event: SweepableEvent);

    #[abi(embed_v0)]
    impl SweepableImpl = SweepableComponent::Sweepable<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        sweepable: SweepableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        SweepableEvent: SweepableComponent::Event,
    }
}
