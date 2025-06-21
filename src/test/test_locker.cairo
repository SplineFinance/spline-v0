#[starknet::interface]
pub trait ITestLocker<TContractState> {
    fn execute(
        ref self: TContractState, core: ekubo::interfaces::core::ICoreDispatcher, callback: bool,
    ) -> Option<()>;
}

#[starknet::contract]
pub mod TestLocker {
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker};
    use spline_v0::shared_locker::try_call_core_with_callback;
    use super::ITestLocker;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    pub impl ILockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            panic!("LOCKED_NOT_IMPLEMENTED");
            array![].span()
        }
    }

    #[abi(embed_v0)]
    pub impl ITestLockerImpl of ITestLocker<ContractState> {
        fn execute(ref self: ContractState, core: ICoreDispatcher, callback: bool) -> Option<()> {
            try_call_core_with_callback::<(bool,), ()>(core, @(callback,))
        }
    }
}
