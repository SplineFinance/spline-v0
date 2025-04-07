use core::num::traits::Zero;
use ekubo::components::util::serialize;
use ekubo::types::keys::PoolKey;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::profiles::bounds::{
    ILiquidityProfileBoundsDispatcher, ILiquidityProfileBoundsDispatcherTrait,
};
use spline_v0::profiles::symmetric::SymmetricLiquidityProfileComponent;
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

fn setup() -> (PoolKey, ILiquidityProfileBoundsDispatcher) {
    let symmetric_class = declare("TestSymmetricLiquidityProfile").unwrap().contract_class();
    let symmetric = deploy_contract(symmetric_class, array![]);

    // TODO:

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

    let pool_key = PoolKey {
        token0: token0.contract_address,
        token1: token1.contract_address,
        fee: 34028236692093846346337460743176821, // 1 bps (= 2**128 / 10000)
        tick_spacing: 1, // 0.01 bps
        extension: Zero::<ContractAddress>::zero(),
    };

    (pool_key, ILiquidityProfileBoundsDispatcher { contract_address: symmetric })
}

#[test]
fn test_symmetric_liquidity_profile_get_bounds_for_liquidity_updates() {
    let (pool_key, symmetric) = setup();
    let bounds = symmetric.get_bounds_for_liquidity_updates(pool_key);
}
