use ekubo::components::util::serialize;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::sweep::{ISweepableDispatcher, ISweepableDispatcherTrait};
use starknet::{ContractAddress, get_contract_address};

fn deploy_contract(class: @ContractClass, calldata: Array<felt252>) -> ContractAddress {
    let (contract_address, _) = class.deploy(@calldata).expect('Deploy contract failed');
    contract_address
}

fn deploy_token(
    class: @ContractClass,
    name: ByteArray,
    symbol: ByteArray,
    recipient: ContractAddress,
    amount: u256,
) -> IERC20Dispatcher {
    let (contract_address, _) = class
        .deploy(
            @serialize::<
                (ByteArray, ByteArray, ContractAddress, u256),
            >(@(name, symbol, recipient, amount)),
        )
        .expect('Deploy token failed');

    IERC20Dispatcher { contract_address }
}

fn setup() -> (ISweepableDispatcher, IERC20Dispatcher) {
    let sweepable_class = declare("TestSweepable").unwrap().contract_class();
    let sweepable = deploy_contract(sweepable_class, array![]);
    let token_class = declare("TestToken").unwrap().contract_class();

    let token = deploy_token(token_class, "Token A", "A", sweepable, 1000000000000000000);
    (ISweepableDispatcher { contract_address: sweepable }, token)
}

#[test]
fn test_sweep() {
    let (sweepable, token) = setup();
    let recipient = get_contract_address();
    assert_eq!(token.balance_of(recipient), 0);
    assert_eq!(token.balance_of(sweepable.contract_address), 1000000000000000000);
    sweepable.sweep(token.contract_address, recipient, 1000000000000000000);
    assert_eq!(token.balance_of(recipient), 1000000000000000000);
}

#[test]
#[should_panic(expected: 'Insufficient balance')]
fn test_sweep_insufficient_balance() {
    let (sweepable, token) = setup();
    let recipient = get_contract_address();
    assert_eq!(token.balance_of(recipient), 0);
    assert_eq!(token.balance_of(sweepable.contract_address), 1000000000000000000);
    sweepable.sweep(token.contract_address, recipient, 1000000000000000001);
}
