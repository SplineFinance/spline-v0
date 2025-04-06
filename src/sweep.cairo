#[starknet::interface]
pub trait ISweepable<TContractState> {
    fn sweep(
        self: @TContractState,
        token: starknet::ContractAddress,
        recipient: starknet::ContractAddress,
        amount_min: u256,
    );
}

#[starknet::component]
pub mod SweepableComponent {
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, get_contract_address};

    #[storage]
    pub struct Storage {}

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {}

    #[embeddable_as(Sweepable)]
    impl SweepableImpl<
        TContractState, +HasComponent<TContractState>,
    > of super::ISweepable<ComponentState<TContractState>> {
        fn sweep(
            self: @ComponentState<TContractState>,
            token: ContractAddress,
            recipient: ContractAddress,
            amount_min: u256,
        ) {
            let balance = IERC20Dispatcher { contract_address: token }
                .balance_of(get_contract_address());
            assert(balance >= amount_min, 'Insufficient balance');
            IERC20Dispatcher { contract_address: token }.transfer(recipient, balance);
        }
    }
}
