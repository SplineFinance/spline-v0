use core::num::traits::Zero;
use ekubo::components::util::serialize;
use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::profile::{
    ILiquidityProfile, ILiquidityProfileDispatcher, ILiquidityProfileDispatcherTrait,
};
use spline_v0::profiles::cauchy::CauchyLiquidityProfile;
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

fn setup() -> (PoolKey, ILiquidityProfileDispatcher, Span<i129>) {
    let class = declare("CauchyLiquidityProfile").unwrap().contract_class();
    let cauchy_address = deploy_contract(class, array![]);

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
        extension: get_contract_address() // need this for set liq profile check
    };

    // s, res, tick_start, tick_max
    let params = array![
        i129 { mag: 1000, sign: false },
        i129 { mag: 4, sign: false },
        i129 { mag: 0, sign: false },
        i129 { mag: 10000, sign: false },
        i129 { mag: 1000000000000000000, sign: false },
        i129 { mag: 0, sign: false },
        i129 { mag: 2000, sign: false },
        i129 { mag: 80000, sign: false },
    ]
        .span();

    (pool_key, ILiquidityProfileDispatcher { contract_address: cauchy_address }, params)
}

#[test]
fn test_set_liquidity_profile_updates_storage() {
    let (pool_key, cauchy, params) = setup();
    cauchy.set_liquidity_profile(pool_key, params);
    assert_eq!(cauchy.get_liquidity_profile(pool_key), params);
}

#[test]
fn test_initial_liquidity_factor() {
    let (pool_key, cauchy, params) = setup();
    cauchy.set_liquidity_profile(pool_key, params);

    let l0 = cauchy.initial_liquidity_factor(pool_key, Zero::<i129>::zero());
    assert_eq!(l0, 1000000000000000000);
}

#[test]
fn test_description() {
    let (_, cauchy, _) = setup();
    let (name, symbol) = cauchy.description();
    assert_eq!(name, "Cauchy");
    assert_eq!(symbol, "CAUCHY");
}
