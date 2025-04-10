use core::num::traits::Zero;
use ekubo::components::util::serialize;
use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, UpdatePositionParameters};
use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount};
use ekubo::types::bounds::Bounds;
use ekubo::types::delta::Delta;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::lp::{ILiquidityProviderDispatcher, ILiquidityProviderDispatcherTrait};
use spline_v0::math::muldiv;
use spline_v0::profile::{
    ILiquidityProfile, ILiquidityProfileDispatcher, ILiquidityProfileDispatcherTrait,
};
use spline_v0::profiles::cauchy::CauchyLiquidityProfile;
use spline_v0::sweep::{ISweepableDispatcher, ISweepableDispatcherTrait};
use spline_v0::token::{ILiquidityProviderTokenDispatcher, ILiquidityProviderTokenDispatcherTrait};
use starknet::{ClassHash, ContractAddress, contract_address_const, get_contract_address};

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

fn setup() -> (
    PoolKey, ILiquidityProfileDispatcher, Span<i129>, IERC20Dispatcher, IERC20Dispatcher,
) {
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
        i129 { mag: 64000, sign: false },
    ]
        .span();

    (
        pool_key,
        ILiquidityProfileDispatcher { contract_address: cauchy_address },
        params,
        token0,
        token1,
    )
}

fn tick_limits_from_ekubo_core() -> (i129, i129) {
    const MIN_TICK: i129 = i129 { mag: 88722883, sign: true };
    const MAX_TICK: i129 = i129 { mag: 88722883, sign: false };
    (MIN_TICK, MAX_TICK)
}

// assumes params from setup()
fn updates(pool_key: PoolKey, sign: bool) -> Span<UpdatePositionParameters> {
    let (MIN_TICK, MAX_TICK) = tick_limits_from_ekubo_core();
    array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: MIN_TICK + i129 { mag: MIN_TICK.mag % pool_key.tick_spacing, sign: false },
                upper: MAX_TICK - i129 { mag: MAX_TICK.mag % pool_key.tick_spacing, sign: false },
            },
            liquidity_delta: i129 { mag: 155273115211, sign: sign },
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
    let (pool_key, cauchy, params, _, _) = setup();
    cauchy.set_liquidity_profile(pool_key, params);
    assert_eq!(cauchy.get_liquidity_profile(pool_key), params);
}

#[test]
fn test_initial_liquidity_factor() {
    let (pool_key, cauchy, params, _, _) = setup();
    cauchy.set_liquidity_profile(pool_key, params);

    let l0 = cauchy.initial_liquidity_factor(pool_key, Zero::<i129>::zero());
    assert_eq!(l0, 1000000000000000000);
}

#[test]
fn test_description() {
    let (_, cauchy, _, _, _) = setup();
    let (name, symbol) = cauchy.description();
    assert_eq!(name, "Cauchy");
    assert_eq!(symbol, "CAUCHY");
}

#[test]
fn test_get_liquidity_updates_with_positive_liquidity_factor() {
    let (pool_key, cauchy, params, _, _) = setup();
    cauchy.set_liquidity_profile(pool_key, params);

    let sign = false;
    let liquidity_factor = i129 { mag: 1000000000000000000, sign: sign };
    let liquidity_updates = cauchy.get_liquidity_updates(pool_key, liquidity_factor);
    assert_eq!(liquidity_updates.len(), 17);

    let expected_updates = updates(pool_key, sign);
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
    let (pool_key, cauchy, params, _, _) = setup();
    cauchy.set_liquidity_profile(pool_key, params);

    let sign = true;
    let liquidity_factor = i129 { mag: 1000000000000000000, sign: sign };
    let liquidity_updates = cauchy.get_liquidity_updates(pool_key, liquidity_factor);
    assert_eq!(liquidity_updates.len(), 17);

    let expected_updates = updates(pool_key, sign);
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

fn ekubo_core() -> ICoreDispatcher {
    ICoreDispatcher {
        contract_address: contract_address_const::<
            0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b,
        >(),
    }
}

fn router() -> IRouterDispatcher {
    IRouterDispatcher {
        contract_address: contract_address_const::<
            0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e,
        >(),
    }
}

fn setup_with_liquidity_provider() -> (
    PoolKey,
    ILiquidityProviderDispatcher,
    ContractAddress,
    ILiquidityProfileDispatcher,
    Span<i129>,
    IERC20Dispatcher,
    IERC20Dispatcher,
) {
    let (pool_key, cauchy, params, token0, token1) = setup();

    let contract_class = declare("LiquidityProvider").unwrap().contract_class();
    let core: ICoreDispatcher = ekubo_core();
    let owner: ContractAddress = get_contract_address();
    let pool_token_class_hash: ClassHash = *declare("LiquidityProviderToken")
        .unwrap()
        .contract_class()
        .class_hash;
    let constructor_calldata: Array<felt252> = serialize::<
        (ContractAddress, ContractAddress, ContractAddress, ClassHash),
    >(@(core.contract_address, cauchy.contract_address, owner, pool_token_class_hash));

    let lp = ILiquidityProviderDispatcher {
        contract_address: deploy_contract(contract_class, constructor_calldata),
    };

    token0.approve(lp.contract_address, 0xffffffffffffffffffffffffffffffff);
    token1.approve(lp.contract_address, 0xffffffffffffffffffffffffffffffff);

    let new_pool_key = PoolKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        fee: 0,
        tick_spacing: pool_key.tick_spacing,
        extension: lp.contract_address,
    };

    (new_pool_key, lp, owner, cauchy, params, token0, token1)
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_with_cauchy_profile() {
    let (pool_key, lp, owner, cauchy, params, token0, token1) = setup_with_liquidity_provider();
    let initial_tick = i129 { mag: 0, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = 1000000000000000000;
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());

    lp.create_and_initialize_pool(pool_key, initial_tick, params);

    let core = ekubo_core();
    let liquidity = core.get_pool_liquidity(pool_key);

    assert_close(
        i129 { mag: liquidity, sign: false },
        i129 {
            mag: 156861678621077, sign: false,
        }, // result from np.cumsum on discretized python model
        one() / 1000000,
    ); // value at initial tick = 0 should be some of range position liquidity deltas

    // go through the liquidity delta updates and verify liquidity delta net values
    let expected_updates = updates(pool_key, false);
    for i in 0..expected_updates.len() {
        let (liquidity_net_lower, liquidity_net_upper) = (
            core.get_pool_tick_liquidity_delta(pool_key, *expected_updates[i].bounds.lower),
            core.get_pool_tick_liquidity_delta(pool_key, *expected_updates[i].bounds.upper),
        );

        assert_close(
            liquidity_net_lower,
            i129 { mag: *expected_updates[i].liquidity_delta.mag, sign: false },
            one() / 1000000 // 1e-6
        );
        assert_close(
            liquidity_net_upper,
            i129 { mag: *expected_updates[i].liquidity_delta.mag, sign: true },
            one() / 1000000 // 1e-6
        );
    }
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_with_cauchy_profile() {
    let (pool_key, lp, owner, cauchy, params, token0, token1) = setup_with_liquidity_provider();
    let initial_tick = i129 { mag: 0, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = 100000000000000000000; // 100 * 1e18
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());
    lp.create_and_initialize_pool(pool_key, initial_tick, params);

    // add liquidity
    let factor = 99000000000000000000; // 99 * 1e18
    let shares: u256 = lp.add_liquidity(pool_key, factor);
    assert_eq!(shares, 99000000000000000000);

    let core = ekubo_core();
    let liquidity = core.get_pool_liquidity(pool_key);

    assert_close(
        i129 { mag: liquidity, sign: false },
        i129 { mag: 156861678621077 * 100, sign: false },
        one() / 1000000,
    ); // value at initial tick = 0 should be some of range position liquidity deltas

    // go through the liquidity delta updates and verify liquidity delta net values
    let expected_updates = updates(pool_key, false);
    for i in 0..expected_updates.len() {
        let (liquidity_net_lower, liquidity_net_upper) = (
            core.get_pool_tick_liquidity_delta(pool_key, *expected_updates[i].bounds.lower),
            core.get_pool_tick_liquidity_delta(pool_key, *expected_updates[i].bounds.upper),
        );

        assert_close(
            liquidity_net_lower,
            i129 { mag: *expected_updates[i].liquidity_delta.mag * 100, sign: false },
            one() / 1000000 // 1e-6
        );
        assert_close(
            liquidity_net_upper,
            i129 { mag: *expected_updates[i].liquidity_delta.mag * 100, sign: true },
            one() / 1000000 // 1e-6
        );
    }
}

#[test]
#[fork("mainnet")]
fn test_remove_liquidity_with_cauchy_profile() {
    let (pool_key, lp, owner, cauchy, params, token0, token1) = setup_with_liquidity_provider();
    let initial_tick = i129 { mag: 0, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = 100000000000000000000; // 100 * 1e18
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());
    lp.create_and_initialize_pool(pool_key, initial_tick, params);

    // add liquidity
    let factor = 99000000000000000000; // 99 * 1e18
    lp.add_liquidity(pool_key, factor);

    // remove liquidity
    let shares_removed: u256 = 10000000000000000000; // 10 * 1e18 (10% of total shares)
    let factor_removed: u128 = lp.remove_liquidity(pool_key, shares_removed);
    assert_eq!(factor_removed, 10000000000000000000);

    let core = ekubo_core();
    let liquidity = core.get_pool_liquidity(pool_key);

    assert_close(
        i129 { mag: liquidity, sign: false },
        i129 { mag: 156861678621077 * 90, sign: false },
        one() / 1000000,
    ); // value at initial tick = 0 should be some of range position liquidity deltas

    // go through the liquidity delta updates and verify liquidity delta net values
    let expected_updates = updates(pool_key, false);
    for i in 0..expected_updates.len() {
        let (liquidity_net_lower, liquidity_net_upper) = (
            core.get_pool_tick_liquidity_delta(pool_key, *expected_updates[i].bounds.lower),
            core.get_pool_tick_liquidity_delta(pool_key, *expected_updates[i].bounds.upper),
        );

        assert_close(
            liquidity_net_lower,
            i129 { mag: *expected_updates[i].liquidity_delta.mag * 90, sign: false },
            one() / 1000000 // 1e-6
        );
        assert_close(
            liquidity_net_upper,
            i129 { mag: *expected_updates[i].liquidity_delta.mag * 90, sign: true },
            one() / 1000000 // 1e-6
        );
    }
}

#[test]
#[fork("mainnet")]
fn test_swap_with_cauchy_profile() {
    let (pool_key, lp, owner, cauchy, params, token0, token1) = setup_with_liquidity_provider();
    let initial_tick = i129 { mag: 0, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = 10000000000000000000000; // 10_000 * 1e18
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());
    lp.create_and_initialize_pool(pool_key, initial_tick, params);

    // add liquidity
    let factor =
        10000000000000000000000000000; // 10_000_000_000 * 1e18 for ~ (1000, 1000) in (x, y) reserves
    lp.add_liquidity(pool_key, factor);

    // get the excess tokens back for swapping
    ISweepableDispatcher { contract_address: lp.contract_address }
        .sweep(pool_key.token0, get_contract_address(), 0);
    ISweepableDispatcher { contract_address: lp.contract_address }
        .sweep(pool_key.token1, get_contract_address(), 0);

    // swap  50% of y reserves into pool
    let buy_token = IERC20Dispatcher { contract_address: token1.contract_address };
    let (_, reserve1) = lp.pool_reserves(pool_key);
    let amount_in = reserve1 / 4;
    buy_token.transfer(router().contract_address, amount_in.into());

    let (_, max_tick) = tick_limits_from_ekubo_core();
    let swap_delta = router()
        .swap(
            node: RouteNode {
                pool_key, sqrt_ratio_limit: mathlib().tick_to_sqrt_ratio(max_tick), skip_ahead: 0,
            },
            token_amount: TokenAmount {
                token: buy_token.contract_address, amount: i129 { mag: amount_in, sign: false },
            },
        );

    // check low slippage due to cauchy profile even on significant percentage of reserves in
    assert_eq!(swap_delta.amount1, i129 { mag: amount_in, sign: false });
    assert_close(
        swap_delta.amount1, i129 { mag: amount_in, sign: false }, one() / 1000,
    ); // within 10 bps
}
