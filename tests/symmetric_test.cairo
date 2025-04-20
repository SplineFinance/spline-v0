use core::num::traits::Zero;
use ekubo::components::util::serialize;
use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::profiles::bounds::{
    ILiquidityProfileBoundsDispatcher, ILiquidityProfileBoundsDispatcherTrait,
};
use spline_v0::profiles::symmetric::SymmetricLiquidityProfileComponent;
use spline_v0::profiles::test_symmetric::{
    ITestSymmetricLiquidityProfileDispatcher, ITestSymmetricLiquidityProfileDispatcherTrait,
};
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

fn setup() -> (PoolKey, ILiquidityProfileBoundsDispatcher, Span<i129>) {
    let symmetric_class = declare("TestSymmetricLiquidityProfile").unwrap().contract_class();
    let symmetric_address = deploy_contract(symmetric_class, array![]);

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

    // s, res, tick_start, tick_max
    let params = array![
        i129 { mag: 1000, sign: false },
        i129 { mag: 4, sign: false },
        i129 { mag: 0, sign: false },
        i129 { mag: 8000, sign: false },
    ]
        .span();
    ITestSymmetricLiquidityProfileDispatcher { contract_address: symmetric_address }
        .set_grid_for_bounds(pool_key, params);

    (pool_key, ILiquidityProfileBoundsDispatcher { contract_address: symmetric_address }, params)
}

#[test]
fn test_symmetric_liquidity_profile_get_bounds_for_liquidity_updates() {
    let (pool_key, symmetric, _) = setup();
    let bounds = symmetric.get_bounds_for_liquidity_updates(pool_key);
    assert_eq!(bounds.len(), 16);

    let expected_bounds = array![
        Bounds { lower: i129 { mag: 250, sign: true }, upper: i129 { mag: 251, sign: false } },
        Bounds { lower: i129 { mag: 500, sign: true }, upper: i129 { mag: 501, sign: false } },
        Bounds { lower: i129 { mag: 750, sign: true }, upper: i129 { mag: 751, sign: false } },
        Bounds { lower: i129 { mag: 1000, sign: true }, upper: i129 { mag: 1001, sign: false } },
        Bounds { lower: i129 { mag: 1250, sign: true }, upper: i129 { mag: 1251, sign: false } },
        Bounds { lower: i129 { mag: 1500, sign: true }, upper: i129 { mag: 1501, sign: false } },
        Bounds { lower: i129 { mag: 1750, sign: true }, upper: i129 { mag: 1751, sign: false } },
        Bounds { lower: i129 { mag: 2000, sign: true }, upper: i129 { mag: 2001, sign: false } },
        Bounds { lower: i129 { mag: 2500, sign: true }, upper: i129 { mag: 2501, sign: false } },
        Bounds { lower: i129 { mag: 3000, sign: true }, upper: i129 { mag: 3001, sign: false } },
        Bounds { lower: i129 { mag: 3500, sign: true }, upper: i129 { mag: 3501, sign: false } },
        Bounds { lower: i129 { mag: 4000, sign: true }, upper: i129 { mag: 4001, sign: false } },
        Bounds { lower: i129 { mag: 5000, sign: true }, upper: i129 { mag: 5001, sign: false } },
        Bounds { lower: i129 { mag: 6000, sign: true }, upper: i129 { mag: 6001, sign: false } },
        Bounds { lower: i129 { mag: 7000, sign: true }, upper: i129 { mag: 7001, sign: false } },
        Bounds { lower: i129 { mag: 8000, sign: true }, upper: i129 { mag: 8001, sign: false } },
    ]
        .span();
    for i in 0..bounds.len() {
        assert_eq!(*bounds[i].lower, *expected_bounds[i].lower);
        assert_eq!(*bounds[i].upper, *expected_bounds[i].upper);
    }
}
