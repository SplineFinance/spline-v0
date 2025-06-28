#[starknet::interface]
pub trait ITestCore<TContractState> {
    fn lock(ref self: TContractState, data: Span<felt252>) -> Span<felt252>;
}

#[starknet::contract]
pub mod TestCore {
    use ekubo::interfaces::core::{ILockerDispatcher, ILockerDispatcherTrait};
    use starknet::get_caller_address;
    use super::ITestCore;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    pub impl ITestCoreImpl of ITestCore<ContractState> {
        fn lock(ref self: ContractState, mut data: Span<felt252>) -> Span<felt252> {
            let should_call_locked: bool = Serde::deserialize(ref data)
                .expect('DESERIALIZE_RESULT_FAILED');
            assert(should_call_locked, 'SHOULD_CALL_LOCKED_FALSE');

            let locker: ILockerDispatcher = ILockerDispatcher {
                contract_address: get_caller_address(),
            };
            locker.locked(0, data)
        }
    }
}
