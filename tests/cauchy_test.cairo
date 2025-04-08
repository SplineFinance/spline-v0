use core::num::traits::Zero;
use ekubo::components::util::serialize;
use ekubo::interfaces::core::UpdatePositionParameters;
use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::math::muldiv;
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

    // s, res, tick_start, tick_max, l0, mu, gamma, rho
    let params = array![
        i129 { mag: 1000, sign: false },
        i129 { mag: 4, sign: false },
        i129 { mag: 0, sign: false },
        i129 { mag: 8000, sign: false },
        i129 { mag: 1000000000000000000, sign: false },
        i129 { mag: 0, sign: false },
        i129 { mag: 2000, sign: false },
        i129 { mag: 8000, sign: false },
    ]
        .span();

    (pool_key, ILiquidityProfileDispatcher { contract_address: cauchy_address }, params)
}

// assumes params from setup()
fn updates(sign: bool) -> Span<UpdatePositionParameters> {
    array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 88727200, sign: true },
                upper: i129 { mag: 88727200, sign: false },
            },
            liquidity_delta: i129 { mag: 9362055475993, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 8000, sign: true }, upper: i129 { mag: 8000, sign: false },
            },
            liquidity_delta: i129 { mag: 9362055475993, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 7000, sign: true }, upper: i129 { mag: 7000, sign: false },
            },
            liquidity_delta: i129 { mag: 2649638342263, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 6000, sign: true }, upper: i129 { mag: 6000, sign: false },
            },
            liquidity_delta: i129 { mag: 3903800490933, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 5000, sign: true }, upper: i129 { mag: 5000, sign: false },
            },
            liquidity_delta: i129 { mag: 6036911634520, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 4000, sign: true }, upper: i129 { mag: 4000, sign: false },
            },
            liquidity_delta: i129 { mag: 9878582674670, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 3500, sign: true }, upper: i129 { mag: 3500, sign: false },
            },
            liquidity_delta: i129 { mag: 7345612758087, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 3000, sign: true }, upper: i129 { mag: 3000, sign: false },
            },
            liquidity_delta: i129 { mag: 9794150344117, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 2500, sign: true }, upper: i129 { mag: 2500, sign: false },
            },
            liquidity_delta: i129 { mag: 13138494364059, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 2000, sign: true }, upper: i129 { mag: 2000, sign: false },
            },
            liquidity_delta: i129 { mag: 17468225461305, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 1750, sign: true }, upper: i129 { mag: 1750, sign: false },
            },
            liquidity_delta: i129 { mag: 10563381178666, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 1500, sign: true }, upper: i129 { mag: 1500, sign: false },
            },
            liquidity_delta: i129 { mag: 11718310854200, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 1250, sign: true }, upper: i129 { mag: 1250, sign: false },
            },
            liquidity_delta: i129 { mag: 12589334824347, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 1000, sign: true }, upper: i129 { mag: 1000, sign: false },
            },
            liquidity_delta: i129 { mag: 12875456070356, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 750, sign: true }, upper: i129 { mag: 750, sign: false },
            },
            liquidity_delta: i129 { mag: 12209146319378, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 500, sign: true }, upper: i129 { mag: 500, sign: false },
            },
            liquidity_delta: i129 { mag: 10259786823007, sign: sign },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: i129 { mag: 250, sign: true }, upper: i129 { mag: 250, sign: false },
            },
            liquidity_delta: i129 { mag: 6913517889965, sign: sign },
        },
    ]
        .span()
}

fn one() -> u256 {
    1000000000000000000 // one == 1e18
}

fn assert_close(a: i129, b: i129, tol: u256) {
    assert_eq!(a.sign, b.sign, "Signs are different");
    let (min, max): (u256, u256) = if a.mag > b.mag {
        (b.mag.into(), a.mag.into())
    } else {
        (a.mag.into(), b.mag.into())
    };
    assert_lt!(muldiv(max - min, one(), min), tol);
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

#[test]
fn test_get_liquidity_updates_with_positive_liquidity_factor() {
    let (pool_key, cauchy, params) = setup();
    cauchy.set_liquidity_profile(pool_key, params);

    let sign = false;
    let liquidity_factor = i129 { mag: 1000000000000000000, sign: sign };
    let liquidity_updates = cauchy.get_liquidity_updates(pool_key, liquidity_factor);
    assert_eq!(liquidity_updates.len(), 17);

    let expected_updates = updates(sign);
    for i in 0..liquidity_updates.len() {
        assert_eq!(*liquidity_updates[i].salt, *expected_updates[i].salt);
        assert_eq!(*liquidity_updates[i].bounds.lower, *expected_updates[i].bounds.lower);
        assert_eq!(*liquidity_updates[i].bounds.upper, *expected_updates[i].bounds.upper);
        assert_close(
            *liquidity_updates[i].liquidity_delta,
            *expected_updates[i].liquidity_delta,
            one() / 1000000 // 1e-6
        );
    }
}

#[test]
fn test_get_liquidity_updates_with_negative_liquidity_factor() {
    let (pool_key, cauchy, params) = setup();
    cauchy.set_liquidity_profile(pool_key, params);

    let sign = true;
    let liquidity_factor = i129 { mag: 1000000000000000000, sign: sign };
    let liquidity_updates = cauchy.get_liquidity_updates(pool_key, liquidity_factor);
    assert_eq!(liquidity_updates.len(), 17);

    let expected_updates = updates(sign);
    for i in 0..liquidity_updates.len() {
        assert_eq!(*liquidity_updates[i].salt, *expected_updates[i].salt);
        assert_eq!(*liquidity_updates[i].bounds.lower, *expected_updates[i].bounds.lower);
        assert_eq!(*liquidity_updates[i].bounds.upper, *expected_updates[i].bounds.upper);
        assert_close(
            *liquidity_updates[i].liquidity_delta,
            *expected_updates[i].liquidity_delta,
            one() / 1000000 // 1e-6
        );
    }
}
