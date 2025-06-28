use core::num::traits::Zero;
use ekubo::components::util::serialize;
use ekubo::interfaces::core::{
    ICoreDispatcher, ICoreDispatcherTrait, ILockerDispatcher, ILockerDispatcherTrait,
};
use ekubo::types::keys::PoolKey;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::shared_locker::{handle_delta, safe_transfer_from, try_call_core_with_callback};
use spline_v0::test::test_locker::{ITestLocker, ITestLockerDispatcher, ITestLockerDispatcherTrait};
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

fn setup() -> (ICoreDispatcher, ITestLockerDispatcher, IERC20Dispatcher, IERC20Dispatcher) {
    let core_class = declare("TestCore").unwrap().contract_class();
    let core_address = deploy_contract(core_class, array![]);

    let locker_class = declare("TestLocker").unwrap().contract_class();
    let locker_address = deploy_contract(locker_class, array![]);

    let owner = get_contract_address();
    let token_class = declare("TestToken").unwrap().contract_class();
    let (tokenA, tokenB) = (
        deploy_token(token_class, "Token A", "A", owner, 0xffffffffffffffffffffffffffffffff),
        deploy_token(token_class, "Token B", "B", owner, 0xffffffffffffffffffffffffffffffff),
    );

    let (token0, token1) = if (tokenA.contract_address < tokenB.contract_address) {
        (tokenA, tokenB)
    } else {
        (tokenB, tokenA)
    };

    (
        ICoreDispatcher { contract_address: core_address },
        ITestLockerDispatcher { contract_address: locker_address },
        token0,
        token1,
    )
}

#[test]
fn test_try_call_core_with_callback_passes_when_revert_in_core() {
    let (core, locker, token0, token1) = setup();
    let result: Option<()> = locker.execute(core, false);
    assert(result.is_none(), 'REVERT_IN_CORE');
}

#[test]
fn test_try_call_core_with_callback_fails_when_revert_in_locker() {
    let (core, locker, token0, token1) = setup();
    let result: Option<()> = locker.execute(core, true);
    assert(result.is_none(), 'REVERT_IN_LOCKER');
}
