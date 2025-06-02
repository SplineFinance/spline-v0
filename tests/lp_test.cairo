use core::cmp::min;
use core::num::traits::Zero;
use ekubo::components::owned::{IOwnedDispatcher, IOwnedDispatcherTrait};
use ekubo::components::util::serialize;
use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, UpdatePositionParameters};
use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount};
use ekubo::types::bounds::Bounds;
use ekubo::types::call_points::CallPoints;
use ekubo::types::delta::Delta;
use ekubo::types::fees_per_liquidity::FeesPerLiquidity;
use ekubo::types::i129::i129;
use ekubo::types::keys::{PoolKey, PositionKey};
use ekubo::types::pool_price::PoolPrice;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClass, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, declare,
    spy_events, start_cheat_caller_address, stop_cheat_caller_address,
};
use spline_v0::lp::{
    ILiquidityProviderDispatcher, ILiquidityProviderDispatcherTrait, LiquidityProvider,
};
use spline_v0::math::muldiv;
use spline_v0::profile::{ILiquidityProfileDispatcher, ILiquidityProfileDispatcherTrait};
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

fn ekubo_core() -> ICoreDispatcher {
    ICoreDispatcher {
        contract_address: contract_address_const::<
            0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b,
        >(),
    }
}

fn positions() -> IPositionsDispatcher {
    IPositionsDispatcher {
        contract_address: contract_address_const::<
            0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067,
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

fn profile_params(liquidity_factor: u128, initial_tick: i129, step: u128, n: u128) -> Span<i129> {
    array![
        i129 { mag: liquidity_factor, sign: false },
        initial_tick,
        i129 { mag: step, sign: false },
        i129 { mag: n, sign: false },
    ]
        .span()
}

fn setup() -> (
    PoolKey,
    ILiquidityProviderDispatcher,
    ContractAddress,
    ILiquidityProfileDispatcher,
    Span<i129>,
    IERC20Dispatcher,
    IERC20Dispatcher,
) {
    let contract_class = declare("LiquidityProvider").unwrap().contract_class();

    let profile: ILiquidityProfileDispatcher = ILiquidityProfileDispatcher {
        contract_address: deploy_contract(
            declare("TestProfile").unwrap().contract_class(), array![],
        ),
    };
    let default_profile_params = profile_params(1000000000000000000, Zero::<i129>::zero(), 2000, 4);

    let core: ICoreDispatcher = ekubo_core();
    let owner: ContractAddress = get_contract_address();
    let pool_token_class_hash: ClassHash = *declare("LiquidityProviderToken")
        .unwrap()
        .contract_class()
        .class_hash;
    let constructor_calldata: Array<felt252> = serialize::<
        (ContractAddress, ContractAddress, ContractAddress, ClassHash),
    >(@(core.contract_address, profile.contract_address, owner, pool_token_class_hash));

    let lp = ILiquidityProviderDispatcher {
        contract_address: deploy_contract(contract_class, constructor_calldata),
    };

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

    assert(
        token0
            .approve(
                lp.contract_address,
                0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
            ),
        'token0 approve failed',
    );
    assert(
        token1
            .approve(
                lp.contract_address,
                0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
            ),
        'token1 approve failed',
    );

    let pool_key = PoolKey {
        token0: token0.contract_address,
        token1: token1.contract_address,
        fee: 136112946768375391908118547436404736, // 2**128 / 2500 or 4 bps
        tick_spacing: 1, // 0.01 bps
        extension: lp.contract_address,
    };

    (pool_key, lp, owner, profile, default_profile_params, token0, token1)
}

#[test]
#[fork("mainnet")]
fn test_constructor_sets_callpoints() {
    let (pool_key, _, _, _, _, _, _) = setup();
    assert_eq!(
        ekubo_core().get_call_points(pool_key.extension),
        CallPoints {
            before_initialize_pool: true,
            after_initialize_pool: false,
            before_swap: false,
            after_swap: false,
            before_update_position: true,
            after_update_position: false,
            before_collect_fees: false,
            after_collect_fees: false,
        },
    );
}

#[test]
#[fork("mainnet")]
fn test_constructor_sets_storage() {
    let (_, lp, owner, profile, _, _, _) = setup();
    let lp_profile: ContractAddress = lp.profile().contract_address;
    let lp_core: ContractAddress = lp.core().contract_address;
    let lp_owned: IOwnedDispatcher = IOwnedDispatcher { contract_address: lp.contract_address };
    let lp_owner: ContractAddress = lp_owned.get_owner();
    assert_eq!(lp_profile, profile.contract_address);
    assert_eq!(lp_core, ekubo_core().contract_address);
    assert_eq!(lp_owner, owner);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: "Only from liquidity provider")]
fn test_initialize_pool_fails_if_not_extension() {
    let (pool_key, _, _, _, _, _, _) = setup();
    ekubo_core().initialize_pool(pool_key, Zero::zero());
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_sets_liquidity_profile() {
    let (pool_key, lp, _, profile, default_profile_params, token0, token1) = setup();
    let initial_tick = i129 { mag: 0, sign: false };
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    assert_eq!(profile.get_liquidity_profile(pool_key), default_profile_params);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_deploys_pool_token() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let initial_tick = i129 { mag: 0, sign: false };
    assert_eq!(lp.pool_token(pool_key), Zero::<ContractAddress>::zero());
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    let pool_token = lp.pool_token(pool_key);
    assert_ne!(pool_token, Zero::<ContractAddress>::zero());

    let lp_token = ILiquidityProviderTokenDispatcher { contract_address: pool_token };
    assert_eq!(lp_token.authority(), lp.contract_address);
}

#[test]
#[fork("mainnet")]
fn test_multiple_create_and_initialize_pool_deploys_multiple_pool_tokens() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let initial_tick = i129 { mag: 0, sign: false };
    assert_eq!(lp.pool_token(pool_key), Zero::<ContractAddress>::zero());
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    let pool_token = lp.pool_token(pool_key);
    assert_ne!(pool_token, Zero::<ContractAddress>::zero());

    let lp_token = ILiquidityProviderTokenDispatcher { contract_address: pool_token };
    assert_eq!(lp_token.authority(), lp.contract_address);

    let new_pool_key = PoolKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        fee: 136112946768375391908118547436404736, // 2**128 / 2500 or 4 bps
        tick_spacing: 10,
        extension: lp.contract_address,
    };
    assert_eq!(lp.pool_token(new_pool_key), Zero::<ContractAddress>::zero());
    lp.create_and_initialize_pool(new_pool_key, initial_tick, default_profile_params);
    let new_pool_token = lp.pool_token(new_pool_key);
    assert_ne!(new_pool_token, Zero::<ContractAddress>::zero());

    let new_lp_token = ILiquidityProviderTokenDispatcher { contract_address: new_pool_token };
    assert_eq!(new_lp_token.authority(), lp.contract_address);
    assert_ne!(new_lp_token.contract_address, lp_token.contract_address);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_initializes_pool() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let initial_tick = i129 { mag: 100, sign: false };

    let core = ekubo_core();
    let price: PoolPrice = core.get_pool_price(pool_key);
    assert_eq!(price.sqrt_ratio, 0);
    assert_eq!(price.tick, Zero::<i129>::zero());

    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);

    let price: PoolPrice = core.get_pool_price(pool_key);
    assert_ne!(price.sqrt_ratio, 0);
    assert_eq!(price.tick, initial_tick);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_adds_initial_liquidity_to_pool() {
    let (pool_key, lp, _, profile, default_profile_params, token0, token1) = setup();
    let core: ICoreDispatcher = ekubo_core();
    let initial_tick = i129 { mag: 0, sign: false };
    assert_eq!(initial_tick, *default_profile_params[1]);

    let dt = i129 { mag: pool_key.tick_spacing, sign: false };
    let liquidity_factor = *default_profile_params[0];
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    assert_eq!(n.mag, 4);
    let liquidity_updates: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 1, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 2, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 3, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 4, sign: false },
        },
    ]
        .span();

    // check no liquidity at expected profile ticks
    for update in liquidity_updates {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_eq!(position.liquidity, 0);
    }
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);

    // check no liquidity at expected profile ticks
    // TODO: why is profile.liquidity_updates returning an empty array after initialize_pool?

    // check liquidity at expected profile ticks according to test profile
    for update in liquidity_updates {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_eq!(position.liquidity, *update.liquidity_delta.mag);
        assert!(!*update.liquidity_delta.sign, "Liquidity delta should be positive");
        assert!(*update.liquidity_delta.mag > 0, "Liquidity delta should be > 0");
    }
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_transfers_funds_to_pool() {
    let (pool_key, lp, _, profile, default_profile_params, token0, token1) = setup();
    let core: ICoreDispatcher = ekubo_core();
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let initial_tick = i129 { mag: 0, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = (step.mag * n.mag * (*default_profile_params[0].mag)) / (1900000);
    let ekubo_balance0 = token0.balance_of(core.contract_address);
    let ekubo_balance1 = token1.balance_of(core.contract_address);

    let balance0_before: u256 = token0.balance_of(get_contract_address());
    let balance1_before: u256 = token1.balance_of(get_contract_address());

    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);

    let balance0_after: u256 = token0.balance_of(get_contract_address());
    let balance1_after: u256 = token1.balance_of(get_contract_address());

    let amount0_transferred: u256 = balance0_before - balance0_after;
    let amount1_transferred: u256 = balance1_before - balance1_after;

    let (ekubo_balance0_after, ekubo_balance1_after) = (
        token0.balance_of(core.contract_address), token1.balance_of(core.contract_address),
    );
    assert_eq!(ekubo_balance0_after, ekubo_balance0 + amount0_transferred);
    assert_eq!(ekubo_balance1_after, ekubo_balance1 + amount1_transferred);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_mints_initial_shares_to_lp_token() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();

    let initial_liquidity_factor = *default_profile_params[0];
    let initial_tick = i129 { mag: 0, sign: false };

    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);

    let pool_token = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) };
    assert_eq!(
        pool_token.balance_of(pool_token.contract_address), initial_liquidity_factor.mag.into(),
    );
    assert_eq!(pool_token.total_supply(), initial_liquidity_factor.mag.into());
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_sets_initial_liquidity_factor() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let initial_liquidity_factor = *default_profile_params[0];
    let initial_tick = i129 { mag: 0, sign: false };
    assert_eq!(lp.pool_liquidity_factor(pool_key), 0);
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    assert_eq!(lp.pool_liquidity_factor(pool_key), initial_liquidity_factor.mag);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_updates_pool_reserves() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let initial_tick = i129 { mag: 0, sign: false };

    let (reserves0, reserves1) = lp.pool_reserves(pool_key);
    assert_eq!(reserves0, 0);
    assert_eq!(reserves1, 0);

    let balance0_before: u256 = token0.balance_of(get_contract_address());
    let balance1_before: u256 = token1.balance_of(get_contract_address());

    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);

    let balance0_after: u256 = token0.balance_of(get_contract_address());
    let balance1_after: u256 = token1.balance_of(get_contract_address());

    let amount0_transferred: u256 = balance0_before - balance0_after;
    let amount1_transferred: u256 = balance1_before - balance1_after;

    let (reserves0_after, reserves1_after) = lp.pool_reserves(pool_key);
    assert_close(reserves0_after.into(), reserves0.into() + amount0_transferred, one() / 1000000);
    assert_close(reserves1_after.into(), reserves1.into() + amount1_transferred, one() / 1000000);

    // same given no swaps yet
    assert_eq!(reserves0_after.into(), token0.balance_of(ekubo_core().contract_address));
    assert_eq!(reserves1_after.into(), token1.balance_of(ekubo_core().contract_address));
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_emits_liquidity_updated_event() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let initial_tick = i129 { mag: 0, sign: false };
    let initial_liquidity_factor = *default_profile_params[0];

    let core = ekubo_core();
    let core_balance0 = token0.balance_of(core.contract_address);
    let core_balance1 = token1.balance_of(core.contract_address);

    let mut spy = spy_events();
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);

    let amount0_delta = i129 {
        mag: (token0.balance_of(core.contract_address) - core_balance0).try_into().unwrap(),
        sign: false,
    };
    let amount1_delta = i129 {
        mag: (token1.balance_of(core.contract_address) - core_balance1).try_into().unwrap(),
        sign: false,
    };

    spy
        .assert_emitted(
            @array![
                (
                    lp.contract_address,
                    LiquidityProvider::Event::LiquidityUpdated(
                        LiquidityProvider::LiquidityUpdated {
                            pool_key: pool_key,
                            sender: get_contract_address(),
                            liquidity_factor: initial_liquidity_factor,
                            shares: initial_liquidity_factor.mag.into(),
                            amount0: amount0_delta,
                            amount1: amount1_delta,
                            protocol_fees0: 0,
                            protocol_fees1: 0,
                        },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('OWNER_ONLY',))]
fn test_create_and_initialize_pool_fails_if_not_owner() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let initial_tick = i129 { mag: 0, sign: false };
    start_cheat_caller_address(lp.contract_address, Zero::<ContractAddress>::zero());
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    stop_cheat_caller_address(lp.contract_address);
}


#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Pool token already deployed',))]
fn test_create_and_initialize_pool_fails_if_already_initialized() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let initial_tick = i129 { mag: 0, sign: false };
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    // should fail on second time
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Extension not this contract',))]
fn test_create_and_initialize_pool_fails_if_extension_not_liquidity_provider() {
    let (_, lp, _, _, default_profile_params, token0, token1) = setup();
    let initial_tick = i129 { mag: 0, sign: false };
    let new_pool_key = PoolKey {
        token0: token0.contract_address,
        token1: token1.contract_address,
        fee: 136112946768375391908118547436404736, // 2**128 / 2500 or 4 bps
        tick_spacing: 1, // 0.01 bps
        extension: Zero::<ContractAddress>::zero(),
    };
    lp.create_and_initialize_pool(new_pool_key, initial_tick, default_profile_params);
}

fn setup_add_liquidity() -> (
    PoolKey,
    ILiquidityProviderDispatcher,
    ContractAddress,
    ILiquidityProfileDispatcher,
    Span<i129>,
    IERC20Dispatcher,
    IERC20Dispatcher,
) {
    let (pool_key, lp, owner, profile, default_profile_params, token0, token1) = setup();
    let initial_tick = i129 { mag: 0, sign: false };
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    (pool_key, lp, owner, profile, default_profile_params, token0, token1)
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_updates_liquidity_factor() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup_add_liquidity();
    let initial_liquidity_factor = lp.pool_liquidity_factor(pool_key);
    assert_eq!(initial_liquidity_factor, 1000000000000000000);

    // now add more liquidity
    let factor = 100000000000000000000; // 100 * 1e18
    lp.add_liquidity(pool_key, factor, max_u128(), max_u128());
    assert_eq!(lp.pool_liquidity_factor(pool_key), initial_liquidity_factor + factor);
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_mints_shares() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup_add_liquidity();
    let initial_liquidity_factor = lp.pool_liquidity_factor(pool_key);
    assert_eq!(initial_liquidity_factor, 1000000000000000000);

    // state prior after create and initialize pool
    let factor = 100000000000000000000; // 100 * 1e18
    let pool_token: IERC20Dispatcher = IERC20Dispatcher {
        contract_address: lp.pool_token(pool_key),
    };
    let total_shares = pool_token.total_supply(); // 1e18 given initial liquidity factor of 1e18
    assert_eq!(pool_token.balance_of(pool_token.contract_address), total_shares);

    // now add more liquidity
    let shares = 100000000000000000000; // 100 * 1e18 given initial liquidity factor of 1e18
    assert_eq!(lp.add_liquidity(pool_key, factor, max_u128(), max_u128()), shares);
    assert_eq!(pool_token.balance_of(get_contract_address()), shares);
    assert_eq!(pool_token.total_supply(), total_shares + shares);
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_multiple_mints_shares() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup_add_liquidity();
    let initial_liquidity_factor = lp.pool_liquidity_factor(pool_key);
    assert_eq!(initial_liquidity_factor, 1000000000000000000);

    let factor = 100000000000000000000; // 100 * 1e18
    // state prior after create and initialize pool
    let pool_token: IERC20Dispatcher = IERC20Dispatcher {
        contract_address: lp.pool_token(pool_key),
    };
    let total_shares = pool_token.total_supply(); // 1e18 given initial liquidity factor of 1e18
    assert_eq!(pool_token.balance_of(pool_token.contract_address), total_shares);

    // now add more liquidity
    let shares = 100000000000000000000; // 100 * 1e18 given initial liquidity factor of 1e18
    let result_first: u256 = lp.add_liquidity(pool_key, factor, max_u128(), max_u128());
    let result_second: u256 = lp.add_liquidity(pool_key, 2 * factor, max_u128(), max_u128());
    assert_eq!(result_first, shares);
    assert_eq!(result_second, 2 * shares);
    assert_eq!(pool_token.balance_of(get_contract_address()), 3 * shares);
    assert_eq!(pool_token.total_supply(), total_shares + 3 * shares);
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_adds_liquidity_to_pool() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup_add_liquidity();
    let initial_tick = i129 { mag: 0, sign: false };
    let initial_liquidity_factor = lp.pool_liquidity_factor(pool_key);
    assert_eq!(initial_liquidity_factor, 1000000000000000000);

    let dt = i129 { mag: pool_key.tick_spacing, sign: false };
    let initial_liquidity_factor = *default_profile_params[0];
    let factor = 100000000000000000000; // 100 * 1e18
    let liquidity_factor: i129 = i129 { mag: factor, sign: false };
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    assert_eq!(n.mag, 4);
    let initial_liquidity_updates: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step + dt,
            },
            liquidity_delta: initial_liquidity_factor / i129 { mag: 1, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step + dt,
            },
            liquidity_delta: initial_liquidity_factor / i129 { mag: 2, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step + dt,
            },
            liquidity_delta: initial_liquidity_factor / i129 { mag: 3, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step + dt,
            },
            liquidity_delta: initial_liquidity_factor / i129 { mag: 4, sign: false },
        },
    ]
        .span();
    let liquidity_updates: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 1, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 2, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 3, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 4, sign: false },
        },
    ]
        .span();

    // check initial liquidity at expected profile ticks
    let core = ekubo_core();
    for update in initial_liquidity_updates {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_eq!(position.liquidity, *update.liquidity_delta.mag);
    }

    // now add the liquidity
    lp.add_liquidity(pool_key, factor, max_u128(), max_u128());

    // TODO: check why provider getter not working as expected in test (but works in contract)
    // check liquidity at expected profile ticks according to test profile
    let mut j = 0;
    for update in liquidity_updates {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_eq!(
            position.liquidity,
            *update.liquidity_delta.mag + *initial_liquidity_updates[j].liquidity_delta.mag,
        ); // should add liq to initial amount
        assert!(!*update.liquidity_delta.sign, "Liquidity delta should be positive");
        assert!(*update.liquidity_delta.mag > 0, "Liquidity delta should be > 0");
        j += 1;
    }
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_transfers_funds_to_pool() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup_add_liquidity();
    let initial_liquidity_factor = lp.pool_liquidity_factor(pool_key);
    assert_eq!(initial_liquidity_factor, 1000000000000000000);

    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let factor = 100000000000000000000; // 100 * 1e18
    let amount: u128 = (step.mag * n.mag * (factor)) / (1900000);

    let core = ekubo_core();
    let ekubo_balance0: u256 = token0.balance_of(core.contract_address);
    let ekubo_balance1: u256 = token1.balance_of(core.contract_address);

    let balance0_before: u256 = token0.balance_of(get_contract_address());
    let balance1_before: u256 = token1.balance_of(get_contract_address());

    lp.add_liquidity(pool_key, factor, max_u128(), max_u128());

    let balance0_after: u256 = token0.balance_of(get_contract_address());
    let balance1_after: u256 = token1.balance_of(get_contract_address());

    let amount0_transferred: u256 = balance0_before - balance0_after;
    let amount1_transferred: u256 = balance1_before - balance1_after;

    let (ekubo_balance0_after, ekubo_balance1_after) = (
        token0.balance_of(core.contract_address), token1.balance_of(core.contract_address),
    );
    assert_eq!(ekubo_balance0_after, ekubo_balance0 + amount0_transferred);
    assert_eq!(ekubo_balance1_after, ekubo_balance1 + amount1_transferred);
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_updates_pool_reserves() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup_add_liquidity();
    let initial_liquidity_factor = lp.pool_liquidity_factor(pool_key);
    assert_eq!(initial_liquidity_factor, 1000000000000000000);

    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let factor = 100000000000000000000; // 100 * 1e18
    let (reserves0, reserves1) = lp.pool_reserves(pool_key);

    let balance0_before: u256 = token0.balance_of(get_contract_address());
    let balance1_before: u256 = token1.balance_of(get_contract_address());

    lp.add_liquidity(pool_key, factor, max_u128(), max_u128());

    let balance0_after: u256 = token0.balance_of(get_contract_address());
    let balance1_after: u256 = token1.balance_of(get_contract_address());

    let amount0_transferred: u256 = balance0_before - balance0_after;
    let amount1_transferred: u256 = balance1_before - balance1_after;

    let (reserves0_after, reserves1_after) = lp.pool_reserves(pool_key);
    assert_close(reserves0_after.into(), reserves0.into() + amount0_transferred, one() / 1000000);
    assert_close(reserves1_after.into(), reserves1.into() + amount1_transferred, one() / 1000000);
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_emits_liquidity_updated_event() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup_add_liquidity();
    let initial_liquidity_factor = lp.pool_liquidity_factor(pool_key);
    assert_eq!(initial_liquidity_factor, 1000000000000000000);

    let factor = 100000000000000000000; // 100 * 1e18
    let core = ekubo_core();
    let balance0_before = token0.balance_of(core.contract_address);
    let balance1_before = token1.balance_of(core.contract_address);

    let mut spy = spy_events();
    let shares = lp.add_liquidity(pool_key, factor, max_u128(), max_u128());

    let balance0_after = token0.balance_of(core.contract_address);
    let balance1_after = token1.balance_of(core.contract_address);

    let liquidity_factor_delta = i129 { mag: factor, sign: false };
    let amount0_delta = i129 {
        mag: (balance0_after - balance0_before).try_into().unwrap(), sign: false,
    };
    let amount1_delta = i129 {
        mag: (balance1_after - balance1_before).try_into().unwrap(), sign: false,
    };

    spy
        .assert_emitted(
            @array![
                (
                    lp.contract_address,
                    LiquidityProvider::Event::LiquidityUpdated(
                        LiquidityProvider::LiquidityUpdated {
                            pool_key: pool_key,
                            sender: get_contract_address(),
                            liquidity_factor: liquidity_factor_delta,
                            shares: shares,
                            amount0: amount0_delta,
                            amount1: amount1_delta,
                            protocol_fees0: 0,
                            protocol_fees1: 0,
                        },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Extension not this contract',))]
fn test_add_liquidity_fails_if_extension_not_liquidity_provider() {
    let (_, lp, _, _, _, token0, token1) = setup_add_liquidity();
    let pool_key = PoolKey {
        token0: token0.contract_address,
        token1: token1.contract_address,
        fee: 136112946768375391908118547436404736, // 2**128 / 2500 or 4 bps
        tick_spacing: 1, // 0.01 bps
        extension: Zero::<ContractAddress>::zero(),
    };
    lp.add_liquidity(pool_key, 100000000000000000000, max_u128(), max_u128());
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Pool token not deployed',))]
fn test_add_liquidity_fails_if_not_initialized() {
    let (pool_key, lp, _, _, _, _, _) = setup();
    lp.add_liquidity(pool_key, 100000000000000000000, max_u128(), max_u128());
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: "Only from liquidity provider")]
fn test_update_position_fails_if_not_extension() {
    let (pool_key, _, _, _, _, _, _) = setup_add_liquidity();
    let liquidity = 100;
    let bounds = Bounds {
        lower: i129 { mag: 100, sign: true }, upper: i129 { mag: 101, sign: false },
    };
    // Try to deposit liquidity
    positions().mint_and_deposit(pool_key, bounds, liquidity);
}

fn setup_remove_liquidity() -> (
    PoolKey,
    ILiquidityProviderDispatcher,
    ContractAddress,
    ILiquidityProfileDispatcher,
    Span<i129>,
    IERC20Dispatcher,
    IERC20Dispatcher,
) {
    let (pool_key, lp, owner, profile, default_profile_params, token0, token1) =
        setup_add_liquidity();
    let factor = 100000000000000000000; // 100 * 1e18
    lp.add_liquidity(pool_key, factor, max_u128(), max_u128());
    (pool_key, lp, owner, profile, default_profile_params, token0, token1)
}

#[test]
#[fork("mainnet")]
fn test_remove_liquidity_updates_liquidity_factor() {
    let (pool_key, lp, _, _, _, _, _) = setup_remove_liquidity();
    let shares = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares / 4;

    let liquidity_factor_before: u128 = lp.pool_liquidity_factor(pool_key);
    let liquidity_factor_removed: u128 = 25000000000000000000;
    assert_eq!(lp.remove_liquidity(pool_key, shares_removed, 0, 0), liquidity_factor_removed);
    assert_eq!(
        lp.pool_liquidity_factor(pool_key), liquidity_factor_before - liquidity_factor_removed,
    );
}

#[test]
#[fork("mainnet")]
fn test_remove_liquidity_burns_shares() {
    let (pool_key, lp, _, _, _, _, _) = setup_remove_liquidity();
    let shares = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares / 4;

    let total_supply_before = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();
    lp.remove_liquidity(pool_key, shares_removed, 0, 0);

    let total_supply_after = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();
    let shares_after = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    assert_eq!(total_supply_after, total_supply_before - shares_removed);
    assert_eq!(shares_after, shares - shares_removed);
}

#[test]
#[fork("mainnet")]
fn test_remove_liquidity_removes_liquidity_from_pool() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup_remove_liquidity();
    let initial_tick = i129 { mag: 0, sign: false };
    let shares = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares / 4;

    let dt = i129 { mag: pool_key.tick_spacing, sign: false };
    let initial_liquidity_factor = *default_profile_params[0];
    let factor = 100000000000000000000; // 100 * 1e18
    let liquidity_factor_before: i129 = i129 { mag: factor, sign: false }
        + initial_liquidity_factor;
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    assert_eq!(n.mag, 4);
    let liquidity_updates_before: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_before / i129 { mag: 1, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_before / i129 { mag: 2, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_before / i129 { mag: 3, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_before / i129 { mag: 4, sign: false },
        },
    ]
        .span();

    let factor_removed: u128 = 25000000000000000000;
    let liquidity_factor_removed: i129 = i129 { mag: factor_removed, sign: false };
    let liquidity_updates: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_removed / i129 { mag: 1, sign: true },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_removed / i129 { mag: 2, sign: true },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_removed / i129 { mag: 3, sign: true },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_removed / i129 { mag: 4, sign: true },
        },
    ]
        .span();

    // check initial liquidity at expected profile ticks
    let core = ekubo_core();
    for update in liquidity_updates_before {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_eq!(position.liquidity, *update.liquidity_delta.mag);
    }

    // now remove the liquidity
    lp.remove_liquidity(pool_key, shares_removed, 0, 0);

    // TODO: check why provider getter not working as expected in test (but works in contract)

    // check liquidity at expected profile ticks according to test profile
    let mut j = 0;
    for update in liquidity_updates {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_eq!(
            position.liquidity,
            *liquidity_updates_before[j].liquidity_delta.mag - *update.liquidity_delta.mag,
        ); // should remove liq from initial amount
        assert!(*update.liquidity_delta.sign, "Liquidity delta should be negative");
        assert!(*update.liquidity_delta.mag > 0, "Liquidity delta should be > 0");
        j += 1;
    }
}

#[test]
#[fork("mainnet")]
fn test_remove_liquidity_transfers_funds_from_pool() {
    let (pool_key, lp, _, _, _, token0, token1) = setup_remove_liquidity();
    let shares = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares / 4;

    let core = ekubo_core();
    let (ekubo_balance0_before, ekubo_balance1_before) = (
        token0.balance_of(core.contract_address), token1.balance_of(core.contract_address),
    );
    let (user_balance0_before, user_balance1_before) = (
        token0.balance_of(get_contract_address()), token1.balance_of(get_contract_address()),
    );

    lp.remove_liquidity(pool_key, shares_removed, 0, 0);

    let (ekubo_balance0_after, ekubo_balance1_after) = (
        token0.balance_of(core.contract_address), token1.balance_of(core.contract_address),
    );
    let (user_balance0_after, user_balance1_after) = (
        token0.balance_of(get_contract_address()), token1.balance_of(get_contract_address()),
    );

    assert_lt!(ekubo_balance0_after, ekubo_balance0_before);
    assert_lt!(ekubo_balance1_after, ekubo_balance1_before);
    assert_gt!(user_balance0_after, user_balance0_before);
    assert_gt!(user_balance1_after, user_balance1_before);

    let amount0_transferred: u256 = ekubo_balance0_before - ekubo_balance0_after;
    let amount1_transferred: u256 = ekubo_balance1_before - ekubo_balance1_after;

    assert_eq!(user_balance0_after, user_balance0_before + amount0_transferred);
    assert_eq!(user_balance1_after, user_balance1_before + amount1_transferred);
}

#[test]
#[fork("mainnet")]
fn test_remove_liquidity_updates_pool_reserves() {
    let (pool_key, lp, _, _, _, token0, token1) = setup_remove_liquidity();
    let shares = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares / 4;

    let core = ekubo_core();
    let (ekubo_balance0_before, ekubo_balance1_before) = (
        token0.balance_of(core.contract_address), token1.balance_of(core.contract_address),
    );
    let (reserves0_before, reserves1_before) = lp.pool_reserves(pool_key);

    lp.remove_liquidity(pool_key, shares_removed, 0, 0);

    let (ekubo_balance0_after, ekubo_balance1_after) = (
        token0.balance_of(core.contract_address), token1.balance_of(core.contract_address),
    );

    let amount0_transferred: u256 = ekubo_balance0_before - ekubo_balance0_after;
    let amount1_transferred: u256 = ekubo_balance1_before - ekubo_balance1_after;

    let (reserves0_after, reserves1_after) = lp.pool_reserves(pool_key);

    // TODO: factor in swap and protocol fee charged on remove liquidity
    assert_close(
        reserves0_after.into(), reserves0_before.into() - amount0_transferred, 2 * one() / 10000,
    );
    assert_close(
        reserves1_after.into(), reserves1_before.into() - amount1_transferred, 2 * one() / 10000,
    );
}

#[test]
#[fork("mainnet")]
fn test_remove_liquidity_emits_liquidity_updated_event() {
    let (pool_key, lp, _, _, _, token0, token1) = setup_remove_liquidity();
    let shares = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares / 4;

    let core = ekubo_core();
    let balance0_before = token0.balance_of(core.contract_address);
    let balance1_before = token1.balance_of(core.contract_address);

    let mut spy = spy_events();
    let factor = lp.remove_liquidity(pool_key, shares_removed, 0, 0);

    let balance0_after = token0.balance_of(core.contract_address);
    let balance1_after = token1.balance_of(core.contract_address);

    let liquidity_factor_delta = i129 { mag: factor, sign: true };
    let amount0_delta = i129 {
        mag: (balance0_before - balance0_after).try_into().unwrap(), sign: true,
    };
    let amount1_delta = i129 {
        mag: (balance1_before - balance1_after).try_into().unwrap(), sign: true,
    };

    spy
        .assert_emitted(
            @array![
                (
                    lp.contract_address,
                    LiquidityProvider::Event::LiquidityUpdated(
                        LiquidityProvider::LiquidityUpdated {
                            pool_key: pool_key,
                            sender: get_contract_address(),
                            liquidity_factor: liquidity_factor_delta,
                            shares: shares_removed,
                            amount0: amount0_delta,
                            amount1: amount1_delta,
                            protocol_fees0: 0,
                            protocol_fees1: 0,
                        },
                    ),
                ),
            ],
        );
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Extension not this contract',))]
fn test_remove_liquidity_fails_if_extension_not_liquidity_provider() {
    let (_, lp, _, _, _, token0, token1) = setup_remove_liquidity();
    let pool_key = PoolKey {
        token0: token0.contract_address,
        token1: token1.contract_address,
        fee: 136112946768375391908118547436404736, // 2**128 / 2500 or 4 bps
        tick_spacing: 1, // 0.01 bps
        extension: Zero::<ContractAddress>::zero(),
    };
    lp.remove_liquidity(pool_key, 100000000000000000000, 0, 0);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Pool token not deployed',))]
fn test_remove_liquidity_fails_if_not_initialized() {
    let (pool_key, lp, _, _, _, _, _) = setup();
    lp.remove_liquidity(pool_key, 100000000000000000000, 0, 0);
}

#[test]
#[fork("mainnet")]
fn test_after_swap_updates_pool_reserves() {
    let (pool_key, lp, _, _, _, token0, token1) = setup_add_liquidity();
    let buy_token = IERC20Dispatcher { contract_address: token1.contract_address };
    buy_token.transfer(router().contract_address, 100000000);

    let (reserves0_before, reserves1_before) = lp.pool_reserves(pool_key);
    let swap_delta = router()
        .swap(
            node: RouteNode {
                pool_key,
                sqrt_ratio_limit: mathlib()
                    .tick_to_sqrt_ratio(i129 { mag: pool_key.tick_spacing, sign: false }),
                skip_ahead: 0,
            },
            token_amount: TokenAmount {
                token: buy_token.contract_address, amount: i129 { mag: 100000000, sign: false },
            },
        );
    assert_eq!(
        swap_delta,
        Delta {
            amount0: i129 { mag: 99959998, sign: true },
            amount1: i129 { mag: 100000000, sign: false },
        },
    );

    // TODO: factor out swap fee
    let expected_reserves0: u128 = (i129 { mag: reserves0_before, sign: false }
        + swap_delta.amount0)
        .mag;
    let expected_reserves1: u128 = (i129 { mag: reserves1_before, sign: false }
        + swap_delta.amount1)
        .mag;
    let (reserves0_after, reserves1_after) = lp.pool_reserves(pool_key);
    assert_close(reserves0_after.into(), expected_reserves0.into(), one() / 1000000);
    assert_close(reserves1_after.into(), expected_reserves1.into(), one() / 1000000);

    // valid since swap delta seems to include fees
    assert_close(
        reserves0_after.into(),
        token0.balance_of(ekubo_core().contract_address).into(),
        one() / 1000000,
    );
    assert_close(
        reserves1_after.into(),
        token1.balance_of(ekubo_core().contract_address).into(),
        one() / 1000000,
    );
}

fn calculate_fees_on_pool(
    pool_key: PoolKey, lp: ILiquidityProviderDispatcher, profile: ILiquidityProfileDispatcher,
) -> Delta {
    // calculate the fees delta accumulated on pool
    let updates = profile.get_liquidity_updates(pool_key, Zero::<i129>::zero());
    let mut fees_delta = Zero::<Delta>::zero();
    for update in updates {
        let position_key = PositionKey {
            salt: (*update.salt).try_into().unwrap(),
            owner: lp.contract_address,
            bounds: *update.bounds,
        };
        let result = ekubo_core().get_position_with_fees(pool_key, position_key);
        fees_delta.amount0 += i129 { mag: result.fees0, sign: false };
        fees_delta.amount1 += i129 { mag: result.fees1, sign: false };
    }
    fees_delta
}

fn one() -> u256 {
    1000000000000000000 // one == 1e18
}

fn two_pow_128() -> u256 {
    340282366920938463463374607431768211456 // 2**128
}

fn max_u128() -> u128 {
    340282366920938463463374607431768211455 // 2**128 - 1
}

fn assert_close(a: u256, b: u256, tol: u256) {
    let (mi, ma): (u256, u256) = if a > b {
        (b, a)
    } else {
        (a, b)
    };
    assert_lt!(muldiv(ma - mi, one(), mi), tol);
}

fn execute_swaps_on_pool(
    pool_key: PoolKey,
    lp: ILiquidityProviderDispatcher,
    profile: ILiquidityProfileDispatcher,
    token0: IERC20Dispatcher,
    token1: IERC20Dispatcher,
    initial_zero_for_one: bool,
    amount: u128,
    n: u128,
) -> Delta {
    // swap to generate fees
    // swap to generate fees
    for i in 0..n {
        let zero_for_one: bool = (i % 2 == 0) == initial_zero_for_one;
        let buy_token = if !zero_for_one {
            IERC20Dispatcher { contract_address: token1.contract_address }
        } else {
            IERC20Dispatcher { contract_address: token0.contract_address }
        };
        buy_token.transfer(router().contract_address, (amount).try_into().unwrap());

        let _ = router()
            .swap(
                node: RouteNode {
                    pool_key,
                    sqrt_ratio_limit: mathlib()
                        .tick_to_sqrt_ratio(
                            i129 { mag: pool_key.tick_spacing * 10000, sign: zero_for_one },
                        ),
                    skip_ahead: 0,
                },
                token_amount: TokenAmount {
                    token: buy_token.contract_address, amount: i129 { mag: amount, sign: false },
                },
            );
    }

    // calculate the fees delta accumulated on pool
    return calculate_fees_on_pool(pool_key, lp, profile);
}

fn setup_harvest_fees(
    initial_zero_for_one: bool, amount: u128, n: u128, add_more_liquidity: bool,
) -> (
    PoolKey,
    ILiquidityProviderDispatcher,
    ContractAddress,
    ILiquidityProfileDispatcher,
    Span<i129>,
    IERC20Dispatcher,
    IERC20Dispatcher,
    Delta,
) {
    let (pool_key, lp, owner, profile, default_profile_params, token0, token1) =
        setup_remove_liquidity();

    // add more liquidity to pool
    if add_more_liquidity {
        let _factor = 10000000000000000000000; // 10000 * 1e18
        lp.add_liquidity(pool_key, _factor, max_u128(), max_u128());
    }

    let fees_delta: Delta = execute_swaps_on_pool(
        pool_key, lp, profile, token0, token1, initial_zero_for_one, amount, n,
    );
    (pool_key, lp, owner, profile, default_profile_params, token0, token1, fees_delta)
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_harvest_fees_adds_liquidity_prior_with_tick_less_than_initial() {
    let (pool_key, lp, owner, _, default_profile_params, token0, token1, fees_delta) =
        setup_harvest_fees(
        true, 10000000000000000000, 25, true,
    );
    let (fees0_u256, fees1_u256): (u256, u256) = (
        fees_delta.amount0.mag.try_into().unwrap(), fees_delta.amount1.mag.try_into().unwrap(),
    );
    assert_gt!(fees0_u256, 0);
    assert_gt!(fees1_u256, 0);

    let core = ekubo_core();
    let pool_price: PoolPrice = core.get_pool_price(pool_key);
    assert_gt!(pool_price.tick.mag, 0);
    assert_eq!(pool_price.tick.sign, true);

    let liquidity_prior: u128 = core.get_pool_liquidity(pool_key);
    assert_gt!(liquidity_prior, 0);
    let liquidity_factor_prior: u128 = lp.pool_liquidity_factor(pool_key);

    let fees_per_liquidity_prior: FeesPerLiquidity = core.get_pool_fees_per_liquidity(pool_key);
    let fees_per_liquidity_prior_value0_u256: u256 = fees_per_liquidity_prior
        .value0
        .try_into()
        .unwrap();
    let fees_per_liquidity_prior_value1_u256: u256 = fees_per_liquidity_prior
        .value1
        .try_into()
        .unwrap();
    assert_gt!(fees_per_liquidity_prior_value0_u256, 0);
    assert_gt!(fees_per_liquidity_prior_value1_u256, 0);

    let (reserves0_prior, reserves1_prior): (u128, u128) = lp.pool_reserves(pool_key);

    // liquidity added to pool should be min between 0, 1 fees delta factoring out protocol fee rate
    // @dev protocol fee rate is 50% of total swap fees
    let protocol_fee_rate: u128 = 2;
    let fees_delta_less_protocol: Delta = Delta {
        amount0: i129 {
            mag: fees_delta.amount0.mag - fees_delta.amount0.mag / protocol_fee_rate, sign: false,
        },
        amount1: i129 {
            mag: fees_delta.amount1.mag - fees_delta.amount1.mag / protocol_fee_rate, sign: false,
        },
    };
    let liquidity_factor_added0_u256: u256 = muldiv(
        liquidity_factor_prior.try_into().unwrap(),
        fees_delta_less_protocol.amount0.mag.try_into().unwrap(),
        reserves0_prior.try_into().unwrap(),
    );
    let liquidity_factor_added1_u256: u256 = muldiv(
        liquidity_factor_prior.try_into().unwrap(),
        fees_delta_less_protocol.amount1.mag.try_into().unwrap(),
        reserves1_prior.try_into().unwrap(),
    );
    let liquidity_factor_added: u128 = min(
        liquidity_factor_added0_u256, liquidity_factor_added1_u256,
    )
        .try_into()
        .unwrap();

    let liquidity_factor_prior: u128 = lp.pool_liquidity_factor(pool_key);
    let total_shares_prior: u256 = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();

    // add more liquidity and check shares_added < factor input due to fee harvest
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let factor: u128 = 10000000000000000000; // 10 * 1e18

    // cache balances of owner before to check protocol fees transferred
    let owner = contract_address_const::<'new_owner'>();
    let lp_owned: IOwnedDispatcher = IOwnedDispatcher { contract_address: lp.contract_address };
    lp_owned.transfer_ownership(owner); // transfer ownership to owner

    let owner_balance0_before: u256 = token0.balance_of(owner);
    let owner_balance1_before: u256 = token1.balance_of(owner);

    // add the liquidity
    let shares_added = lp.add_liquidity(pool_key, factor, max_u128(), max_u128());
    assert_lt!(shares_added, factor.try_into().unwrap());

    let total_shares_after: u256 = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();
    assert_eq!(total_shares_after, total_shares_prior + shares_added);
    assert_lt!(shares_added, factor.try_into().unwrap()); // due to fees harvest

    let liquidity_factor_after: u128 = lp.pool_liquidity_factor(pool_key);
    assert_eq!(liquidity_factor_after - liquidity_factor_prior - factor, liquidity_factor_added);

    // check shares minted
    let shares_minted: u256 = muldiv(
        total_shares_prior,
        factor.try_into().unwrap(),
        (liquidity_factor_prior + liquidity_factor_added).try_into().unwrap(),
    );
    assert_eq!(shares_minted, shares_added);

    // check protocol fees transferred to owner
    let owner_balance0_after: u256 = token0.balance_of(owner);
    let owner_balance1_after: u256 = token1.balance_of(owner);
    let liquidity_factor_added_u256: u256 = liquidity_factor_added.try_into().unwrap();

    if liquidity_factor_added0_u256 == liquidity_factor_added_u256 {
        assert_close(
            owner_balance0_after - owner_balance0_before,
            fees0_u256 / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
        let fees1_u256_added = muldiv(
            fees1_u256, liquidity_factor_added_u256, liquidity_factor_added1_u256,
        );
        assert_close(
            owner_balance1_after - owner_balance1_before,
            fees1_u256_added / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
    } else {
        assert_close(
            owner_balance1_after - owner_balance1_before,
            fees1_u256 / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
        let fees0_u256_added = muldiv(
            fees0_u256, liquidity_factor_added_u256, liquidity_factor_added0_u256,
        );
        assert_close(
            owner_balance0_after - owner_balance0_before,
            fees0_u256_added / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
    }

    // check positions on pool have been updated
    let dt = i129 { mag: pool_key.tick_spacing, sign: false };
    let initial_tick = i129 { mag: 0, sign: false };
    let liquidity_factor_after_delta: i129 = i129 { mag: liquidity_factor_after, sign: false };
    let liquidity_updates_after: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 1, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 2, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 3, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 4, sign: false },
        },
    ]
        .span();

    // check liquidity at expected profile ticks according to test profile
    for update in liquidity_updates_after {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_close(
            position.liquidity.try_into().unwrap(),
            (*update.liquidity_delta.mag).try_into().unwrap(),
            one() / 10000,
        );
    }
}

#[test]
#[fork("mainnet")]
fn test_add_liquidity_harvest_fees_adds_liquidity_prior_with_tick_greater_than_initial() {
    let (pool_key, lp, owner, _, default_profile_params, token0, token1, fees_delta) =
        setup_harvest_fees(
        false, 10000000000000000000, 25, true,
    );
    let (fees0_u256, fees1_u256): (u256, u256) = (
        fees_delta.amount0.mag.try_into().unwrap(), fees_delta.amount1.mag.try_into().unwrap(),
    );
    assert_gt!(fees0_u256, 0);
    assert_gt!(fees1_u256, 0);

    let core = ekubo_core();
    let pool_price: PoolPrice = core.get_pool_price(pool_key);
    assert_gt!(pool_price.tick.mag, 0);
    assert_eq!(pool_price.tick.sign, false);

    let liquidity_prior: u128 = core.get_pool_liquidity(pool_key);
    assert_gt!(liquidity_prior, 0);
    let liquidity_factor_prior: u128 = lp.pool_liquidity_factor(pool_key);

    let fees_per_liquidity_prior: FeesPerLiquidity = core.get_pool_fees_per_liquidity(pool_key);
    let fees_per_liquidity_prior_value0_u256: u256 = fees_per_liquidity_prior
        .value0
        .try_into()
        .unwrap();
    let fees_per_liquidity_prior_value1_u256: u256 = fees_per_liquidity_prior
        .value1
        .try_into()
        .unwrap();
    assert_gt!(fees_per_liquidity_prior_value0_u256, 0);
    assert_gt!(fees_per_liquidity_prior_value1_u256, 0);

    let (reserves0_prior, reserves1_prior): (u128, u128) = lp.pool_reserves(pool_key);

    // liquidity added to pool should be min between 0, 1 fees delta factoring out protocol fee rate
    // @dev protocol fee rate is 50% of total swap fees
    let protocol_fee_rate: u128 = 2;
    let fees_delta_less_protocol: Delta = Delta {
        amount0: i129 {
            mag: fees_delta.amount0.mag - fees_delta.amount0.mag / protocol_fee_rate, sign: false,
        },
        amount1: i129 {
            mag: fees_delta.amount1.mag - fees_delta.amount1.mag / protocol_fee_rate, sign: false,
        },
    };
    let liquidity_factor_added0_u256: u256 = muldiv(
        liquidity_factor_prior.try_into().unwrap(),
        fees_delta_less_protocol.amount0.mag.try_into().unwrap(),
        reserves0_prior.try_into().unwrap(),
    );
    let liquidity_factor_added1_u256: u256 = muldiv(
        liquidity_factor_prior.try_into().unwrap(),
        fees_delta_less_protocol.amount1.mag.try_into().unwrap(),
        reserves1_prior.try_into().unwrap(),
    );
    let liquidity_factor_added: u128 = min(
        liquidity_factor_added0_u256, liquidity_factor_added1_u256,
    )
        .try_into()
        .unwrap();

    let liquidity_factor_prior: u128 = lp.pool_liquidity_factor(pool_key);
    let total_shares_prior: u256 = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();

    // add more liquidity and check shares_added < factor input due to fee harvest
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let factor: u128 = 10000000000000000000; // 10 * 1e18

    // cache balances of owner before to check protocol fees transferred
    let owner = contract_address_const::<'new_owner'>();
    let lp_owned: IOwnedDispatcher = IOwnedDispatcher { contract_address: lp.contract_address };
    lp_owned.transfer_ownership(owner); // transfer ownership to owner

    // cache balances of owner before to check protocol fees transferred
    let owner_balance0_before: u256 = token0.balance_of(owner);
    let owner_balance1_before: u256 = token1.balance_of(owner);

    // add the liquidity
    let shares_added = lp.add_liquidity(pool_key, factor, max_u128(), max_u128());
    assert_lt!(shares_added, factor.try_into().unwrap());

    let total_shares_after: u256 = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();
    assert_eq!(total_shares_after, total_shares_prior + shares_added);
    assert_lt!(shares_added, factor.try_into().unwrap()); // due to fees harvest

    let liquidity_factor_after: u128 = lp.pool_liquidity_factor(pool_key);
    assert_eq!(liquidity_factor_after - liquidity_factor_prior - factor, liquidity_factor_added);

    // check shares minted
    let shares_minted: u256 = muldiv(
        total_shares_prior,
        factor.try_into().unwrap(),
        (liquidity_factor_prior + liquidity_factor_added).try_into().unwrap(),
    );
    assert_eq!(shares_minted, shares_added);

    // check protocol fees transferred to owner
    let owner_balance0_after: u256 = token0.balance_of(owner);
    let owner_balance1_after: u256 = token1.balance_of(owner);
    let liquidity_factor_added_u256: u256 = liquidity_factor_added.try_into().unwrap();

    if liquidity_factor_added0_u256 == liquidity_factor_added_u256 {
        assert_close(
            owner_balance0_after - owner_balance0_before,
            fees0_u256 / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
        let fees1_u256_added = muldiv(
            fees1_u256, liquidity_factor_added_u256, liquidity_factor_added1_u256,
        );
        assert_close(
            owner_balance1_after - owner_balance1_before,
            fees1_u256_added / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
    } else {
        assert_close(
            owner_balance1_after - owner_balance1_before,
            fees1_u256 / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
        let fees0_u256_added = muldiv(
            fees0_u256, liquidity_factor_added_u256, liquidity_factor_added0_u256,
        );
        assert_close(
            owner_balance0_after - owner_balance0_before,
            fees0_u256_added / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
    }

    // check positions on pool have been updated
    let dt = i129 { mag: pool_key.tick_spacing, sign: false };
    let initial_tick = i129 { mag: 0, sign: false };
    let liquidity_factor_after_delta: i129 = i129 { mag: liquidity_factor_after, sign: false };
    let liquidity_updates_after: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 1, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 2, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 3, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 4, sign: false },
        },
    ]
        .span();

    // check liquidity at expected profile ticks according to test profile
    for update in liquidity_updates_after {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_close(
            position.liquidity.try_into().unwrap(),
            (*update.liquidity_delta.mag).try_into().unwrap(),
            one() / 10000,
        );
    }
}

// TODO: fix this test
#[test]
#[ignore]
#[fork("mainnet")]
fn test_add_liquidity_harvest_fees_sends_excess_to_protocol_when_pool_liquidity_zero() {
    let (pool_key, lp, _, profile, default_profile_params, token0, token1, mut fees_delta) =
        setup_harvest_fees(
        true, 10000000000000000000, 25, true,
    );
    assert_gt!(fees_delta.amount0.mag, 0);
    assert_gt!(fees_delta.amount1.mag, 0);

    // execute another large swap to push the pool price outside of liquidity profile
    fees_delta +=
        execute_swaps_on_pool(pool_key, lp, profile, token0, token1, true, 50000000000000000000, 1);

    let core = ekubo_core();
    let pool_price: PoolPrice = core.get_pool_price(pool_key);
    assert_ne!(pool_price.tick, Zero::<i129>::zero());

    let liquidity_prior: u128 = core.get_pool_liquidity(pool_key);
    assert_eq!(liquidity_prior, 0);

    let fees_per_liquidity_prior: FeesPerLiquidity = core.get_pool_fees_per_liquidity(pool_key);
    let fees_per_liquidity_prior_value0_u256: u256 = fees_per_liquidity_prior
        .value0
        .try_into()
        .unwrap();
    let fees_per_liquidity_prior_value1_u256: u256 = fees_per_liquidity_prior
        .value1
        .try_into()
        .unwrap();
    assert_gt!(fees_per_liquidity_prior_value0_u256, 0);
    assert_gt!(fees_per_liquidity_prior_value1_u256, 0);

    // add more liquidity and check shares_added < factor input due to fee harvest
    let factor: u128 = 10000000000000000000; // 10 * 1e18
    let shares_added = lp.add_liquidity(pool_key, factor, max_u128(), max_u128());
    assert_lt!(shares_added, factor.try_into().unwrap());

    let fees_per_liquidity_after: FeesPerLiquidity = core.get_pool_fees_per_liquidity(pool_key);
    let fees_per_liquidity_after_value0_u256: u256 = fees_per_liquidity_after
        .value0
        .try_into()
        .unwrap();
    let fees_per_liquidity_after_value1_u256: u256 = fees_per_liquidity_after
        .value1
        .try_into()
        .unwrap();
    assert_gt!(fees_per_liquidity_after_value0_u256, fees_per_liquidity_prior_value0_u256);
    assert_gt!(fees_per_liquidity_after_value1_u256, fees_per_liquidity_prior_value1_u256);
}

#[test]
#[fork("mainnet")]
fn test_remove_liquidity_harvest_fees_adds_liquidity_prior_with_tick_less_than_initial() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1, fees_delta) =
        setup_harvest_fees(
        true, 10000000000000000000, 25, true,
    );
    let (fees0_u256, fees1_u256): (u256, u256) = (
        fees_delta.amount0.mag.try_into().unwrap(), fees_delta.amount1.mag.try_into().unwrap(),
    );
    assert_gt!(fees0_u256, 0);
    assert_gt!(fees1_u256, 0);

    let core = ekubo_core();
    let pool_price: PoolPrice = core.get_pool_price(pool_key);
    assert_gt!(pool_price.tick.mag, 0);
    assert_eq!(pool_price.tick.sign, true);

    let liquidity_prior: u128 = core.get_pool_liquidity(pool_key);
    assert_gt!(liquidity_prior, 0);
    let liquidity_factor_prior: u128 = lp.pool_liquidity_factor(pool_key);

    let fees_per_liquidity_prior: FeesPerLiquidity = core.get_pool_fees_per_liquidity(pool_key);
    let fees_per_liquidity_prior_value0_u256: u256 = fees_per_liquidity_prior
        .value0
        .try_into()
        .unwrap();
    let fees_per_liquidity_prior_value1_u256: u256 = fees_per_liquidity_prior
        .value1
        .try_into()
        .unwrap();
    assert_gt!(fees_per_liquidity_prior_value0_u256, 0);
    assert_gt!(fees_per_liquidity_prior_value1_u256, 0);

    let (reserves0_prior, reserves1_prior): (u128, u128) = lp.pool_reserves(pool_key);

    // liquidity added to pool should be min between 0, 1 fees delta factoring out protocol fee rate
    // @dev protocol fee rate is 50% of total swap fees
    let protocol_fee_rate: u128 = 2;
    let fees_delta_less_protocol: Delta = Delta {
        amount0: i129 {
            mag: fees_delta.amount0.mag - fees_delta.amount0.mag / protocol_fee_rate, sign: false,
        },
        amount1: i129 {
            mag: fees_delta.amount1.mag - fees_delta.amount1.mag / protocol_fee_rate, sign: false,
        },
    };
    let liquidity_factor_added0_u256: u256 = muldiv(
        liquidity_factor_prior.try_into().unwrap(),
        fees_delta_less_protocol.amount0.mag.try_into().unwrap(),
        reserves0_prior.try_into().unwrap(),
    );
    let liquidity_factor_added1_u256: u256 = muldiv(
        liquidity_factor_prior.try_into().unwrap(),
        fees_delta_less_protocol.amount1.mag.try_into().unwrap(),
        reserves1_prior.try_into().unwrap(),
    );
    let liquidity_factor_added: u128 = min(
        liquidity_factor_added0_u256, liquidity_factor_added1_u256,
    )
        .try_into()
        .unwrap();

    let liquidity_factor_prior: u128 = lp.pool_liquidity_factor(pool_key);
    let total_shares_prior: u256 = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();

    // remove liquidity and check shares_added < factor input due to fee harvest
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let shares_prior = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares_prior / 2;

    // cache balances of owner before to check protocol fees transferred
    let owner = contract_address_const::<'new_owner'>();
    let lp_owned: IOwnedDispatcher = IOwnedDispatcher { contract_address: lp.contract_address };
    lp_owned.transfer_ownership(owner);

    let owner_balance0_before: u256 = token0.balance_of(owner);
    let owner_balance1_before: u256 = token1.balance_of(owner);

    // add the liquidity
    let factor = lp.remove_liquidity(pool_key, shares_removed, 0, 0);
    let total_shares_after: u256 = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();
    assert_eq!(total_shares_after, total_shares_prior - shares_removed);
    assert_lt!(shares_removed, factor.try_into().unwrap()); // due to fees harvest

    let liquidity_factor_after: u128 = lp.pool_liquidity_factor(pool_key);
    assert_eq!(liquidity_factor_after + factor - liquidity_factor_prior, liquidity_factor_added);

    // check shares burned
    let shares_burned: u256 = muldiv(
        total_shares_prior,
        factor.try_into().unwrap(),
        (liquidity_factor_prior + liquidity_factor_added).try_into().unwrap(),
    );
    assert_close(shares_burned, shares_removed, one() / 1000000);

    // check protocol fees transferred to owner
    let owner_balance0_after: u256 = token0.balance_of(owner);
    let owner_balance1_after: u256 = token1.balance_of(owner);
    let liquidity_factor_added_u256: u256 = liquidity_factor_added.try_into().unwrap();

    if liquidity_factor_added0_u256 == liquidity_factor_added_u256 {
        assert_close(
            owner_balance0_after - owner_balance0_before,
            fees0_u256 / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
        let fees1_u256_added = muldiv(
            fees1_u256, liquidity_factor_added_u256, liquidity_factor_added1_u256,
        );
        assert_close(
            owner_balance1_after - owner_balance1_before,
            fees1_u256_added / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
    } else {
        assert_close(
            owner_balance1_after - owner_balance1_before,
            fees1_u256 / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
        let fees0_u256_added = muldiv(
            fees0_u256, liquidity_factor_added_u256, liquidity_factor_added0_u256,
        );
        assert_close(
            owner_balance0_after - owner_balance0_before,
            fees0_u256_added / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
    }

    // check positions on pool have been updated
    let dt = i129 { mag: pool_key.tick_spacing, sign: false };
    let initial_tick = i129 { mag: 0, sign: false };
    let liquidity_factor_after_delta: i129 = i129 { mag: liquidity_factor_after, sign: false };
    let liquidity_updates_after: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 1, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 2, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 3, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 4, sign: false },
        },
    ]
        .span();

    // check liquidity at expected profile ticks according to test profile
    for update in liquidity_updates_after {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_close(
            position.liquidity.try_into().unwrap(),
            (*update.liquidity_delta.mag).try_into().unwrap(),
            one() / 10000,
        );
    }
}

#[test]
#[fork("mainnet")]
fn test_remove_liquidity_harvest_fees_adds_liquidity_prior_with_tick_greater_than_initial() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1, fees_delta) =
        setup_harvest_fees(
        false, 10000000000000000000, 25, true,
    );
    let (fees0_u256, fees1_u256): (u256, u256) = (
        fees_delta.amount0.mag.try_into().unwrap(), fees_delta.amount1.mag.try_into().unwrap(),
    );
    assert_gt!(fees0_u256, 0);
    assert_gt!(fees1_u256, 0);

    let core = ekubo_core();
    let pool_price: PoolPrice = core.get_pool_price(pool_key);
    assert_gt!(pool_price.tick.mag, 0);
    assert_eq!(pool_price.tick.sign, false);

    let liquidity_prior: u128 = core.get_pool_liquidity(pool_key);
    assert_gt!(liquidity_prior, 0);
    let liquidity_factor_prior: u128 = lp.pool_liquidity_factor(pool_key);

    let fees_per_liquidity_prior: FeesPerLiquidity = core.get_pool_fees_per_liquidity(pool_key);
    let fees_per_liquidity_prior_value0_u256: u256 = fees_per_liquidity_prior
        .value0
        .try_into()
        .unwrap();
    let fees_per_liquidity_prior_value1_u256: u256 = fees_per_liquidity_prior
        .value1
        .try_into()
        .unwrap();
    assert_gt!(fees_per_liquidity_prior_value0_u256, 0);
    assert_gt!(fees_per_liquidity_prior_value1_u256, 0);

    let (reserves0_prior, reserves1_prior): (u128, u128) = lp.pool_reserves(pool_key);

    // liquidity added to pool should be min between 0, 1 fees delta factoring out protocol fee rate
    // @dev protocol fee rate is 50% of total swap fees
    let protocol_fee_rate: u128 = 2;
    let fees_delta_less_protocol: Delta = Delta {
        amount0: i129 {
            mag: fees_delta.amount0.mag - fees_delta.amount0.mag / protocol_fee_rate, sign: false,
        },
        amount1: i129 {
            mag: fees_delta.amount1.mag - fees_delta.amount1.mag / protocol_fee_rate, sign: false,
        },
    };
    let liquidity_factor_added0_u256: u256 = muldiv(
        liquidity_factor_prior.try_into().unwrap(),
        fees_delta_less_protocol.amount0.mag.try_into().unwrap(),
        reserves0_prior.try_into().unwrap(),
    );
    let liquidity_factor_added1_u256: u256 = muldiv(
        liquidity_factor_prior.try_into().unwrap(),
        fees_delta_less_protocol.amount1.mag.try_into().unwrap(),
        reserves1_prior.try_into().unwrap(),
    );
    let liquidity_factor_added: u128 = min(
        liquidity_factor_added0_u256, liquidity_factor_added1_u256,
    )
        .try_into()
        .unwrap();

    let liquidity_factor_prior: u128 = lp.pool_liquidity_factor(pool_key);
    let total_shares_prior: u256 = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();

    // remove liquidity and check shares_added < factor input due to fee harvest
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let shares_prior = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares_prior / 2;

    // cache balances of owner before to check protocol fees transferred
    let owner = contract_address_const::<'new_owner'>();
    let lp_owned: IOwnedDispatcher = IOwnedDispatcher { contract_address: lp.contract_address };
    lp_owned.transfer_ownership(owner);

    let owner_balance0_before: u256 = token0.balance_of(owner);
    let owner_balance1_before: u256 = token1.balance_of(owner);

    // add the liquidity
    let factor = lp.remove_liquidity(pool_key, shares_removed, 0, 0);
    let total_shares_after: u256 = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .total_supply();
    assert_eq!(total_shares_after, total_shares_prior - shares_removed);
    assert_lt!(shares_removed, factor.try_into().unwrap()); // due to fees harvest

    let liquidity_factor_after: u128 = lp.pool_liquidity_factor(pool_key);
    assert_eq!(liquidity_factor_after + factor - liquidity_factor_prior, liquidity_factor_added);

    // check shares burned
    let shares_burned: u256 = muldiv(
        total_shares_prior,
        factor.try_into().unwrap(),
        (liquidity_factor_prior + liquidity_factor_added).try_into().unwrap(),
    );
    assert_close(shares_burned, shares_removed, one() / 1000000);

    // check protocol fees transferred to owner
    let owner_balance0_after: u256 = token0.balance_of(owner);
    let owner_balance1_after: u256 = token1.balance_of(owner);
    let liquidity_factor_added_u256: u256 = liquidity_factor_added.try_into().unwrap();

    if liquidity_factor_added0_u256 == liquidity_factor_added_u256 {
        assert_close(
            owner_balance0_after - owner_balance0_before,
            fees0_u256 / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
        let fees1_u256_added = muldiv(
            fees1_u256, liquidity_factor_added_u256, liquidity_factor_added1_u256,
        );
        assert_close(
            owner_balance1_after - owner_balance1_before,
            fees1_u256_added / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
    } else {
        assert_close(
            owner_balance1_after - owner_balance1_before,
            fees1_u256 / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
        let fees0_u256_added = muldiv(
            fees0_u256, liquidity_factor_added_u256, liquidity_factor_added0_u256,
        );
        assert_close(
            owner_balance0_after - owner_balance0_before,
            fees0_u256_added / protocol_fee_rate.try_into().unwrap(),
            one() / 10000,
        );
    }

    // check positions on pool have been updated
    let dt = i129 { mag: pool_key.tick_spacing, sign: false };
    let initial_tick = i129 { mag: 0, sign: false };
    let liquidity_factor_after_delta: i129 = i129 { mag: liquidity_factor_after, sign: false };
    let liquidity_updates_after: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 1, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 2, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 3, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step + dt,
            },
            liquidity_delta: liquidity_factor_after_delta / i129 { mag: 4, sign: false },
        },
    ]
        .span();

    // check liquidity at expected profile ticks according to test profile
    for update in liquidity_updates_after {
        let position_key = PositionKey {
            salt: 0, owner: lp.contract_address, bounds: *update.bounds,
        };
        let position = core.get_position(pool_key, position_key);
        assert_close(
            position.liquidity.try_into().unwrap(),
            (*update.liquidity_delta.mag).try_into().unwrap(),
            one() / 10000,
        );
    }
}

#[test]
#[fork("mainnet")]
fn test_sweep_transfers_tokens_to_recipient() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1, fees_delta) =
        setup_harvest_fees(
        false, 10000000000000000000, 25, true,
    );

    // send in tokens to the lp contract
    token0.transfer(lp.contract_address, 1000000000000000);
    assert_eq!(token0.balance_of(lp.contract_address), 1000000000000000);

    // sweep tokens to recipient
    let recipient = contract_address_const::<'recipient'>();
    lp.sweep(token0.contract_address, recipient, 750000000000000);
    assert_eq!(token0.balance_of(recipient), 750000000000000);
    assert_eq!(token0.balance_of(lp.contract_address), 250000000000000);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('OWNER_ONLY',))]
fn test_sweep_fails_if_not_owner() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1, fees_delta) =
        setup_harvest_fees(
        false, 10000000000000000000, 25, true,
    );

    // send in tokens to the lp contract
    token0.transfer(lp.contract_address, 1000000000000000);
    assert_eq!(token0.balance_of(lp.contract_address), 1000000000000000);

    // cache balances of owner before to check protocol fees transferred
    let owner = contract_address_const::<'new_owner'>();
    let lp_owned: IOwnedDispatcher = IOwnedDispatcher { contract_address: lp.contract_address };
    lp_owned.transfer_ownership(owner); // transfer ownership to owner

    // attempt to sweep with different owner
    lp.sweep(token0.contract_address, get_contract_address(), 1000000000000000);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Slippage exceeded on amount0',))]
fn test_add_liquidity_fails_if_amount0_slippage_exceeded() {
    let (pool_key, lp, _, profile, default_profile_params, token0, token1, mut fees_delta) =
        setup_harvest_fees(
        true, 10000000000000000000, 25, true,
    );
    assert_gt!(fees_delta.amount0.mag, 0);
    assert_gt!(fees_delta.amount1.mag, 0);

    // add more liquidity and check shares_added < factor input due to fee harvest
    let factor: u128 = 10000000000000000000; // 10 * 1e18
    lp.add_liquidity(pool_key, factor, 1, max_u128());
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Slippage exceeded on amount1',))]
fn test_add_liquidity_fails_if_amount1_slippage_exceeded() {
    let (pool_key, lp, _, profile, default_profile_params, token0, token1, mut fees_delta) =
        setup_harvest_fees(
        true, 10000000000000000000, 25, true,
    );
    assert_gt!(fees_delta.amount0.mag, 0);
    assert_gt!(fees_delta.amount1.mag, 0);

    // add more liquidity and check shares_added < factor input due to fee harvest
    let factor: u128 = 10000000000000000000; // 10 * 1e18
    lp.add_liquidity(pool_key, factor, max_u128(), 1);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Slippage exceeded on amount0',))]
fn test_remove_liquidity_fails_if_amount0_slippage_exceeded() {
    let (pool_key, lp, _, profile, default_profile_params, token0, token1, mut fees_delta) =
        setup_harvest_fees(
        true, 10000000000000000000, 25, true,
    );
    assert_gt!(fees_delta.amount0.mag, 0);
    assert_gt!(fees_delta.amount1.mag, 0);

    let shares = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares / 4;

    // add more liquidity and check shares_added < factor input due to fee harvest
    lp.remove_liquidity(pool_key, shares_removed, max_u128(), 0);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Slippage exceeded on amount1',))]
fn test_remove_liquidity_fails_if_amount1_slippage_exceeded() {
    let (pool_key, lp, _, profile, default_profile_params, token0, token1, mut fees_delta) =
        setup_harvest_fees(
        true, 10000000000000000000, 25, true,
    );
    assert_gt!(fees_delta.amount0.mag, 0);
    assert_gt!(fees_delta.amount1.mag, 0);

    let shares = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) }
        .balance_of(get_contract_address());
    let shares_removed = shares / 4;

    // add more liquidity and check shares_added < factor input due to fee harvest
    lp.remove_liquidity(pool_key, shares_removed, 0, max_u128());
}
