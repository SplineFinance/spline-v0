use core::num::traits::Zero;
use ekubo::components::util::serialize;
use ekubo::interfaces::core::{
    ICoreDispatcher, ICoreDispatcherTrait, IExtension, ILocker, SwapParameters,
    UpdatePositionParameters,
};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait};
use ekubo::types::bounds::Bounds;
use ekubo::types::call_points::CallPoints;
use ekubo::types::i129::i129;
use ekubo::types::keys::{PoolKey, PositionKey};
use ekubo::types::pool_price::PoolPrice;
use openzeppelin_access::ownable::interface::{IOwnableDispatcher, IOwnableDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClass, ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use spline_v0::lp::{ILiquidityProviderDispatcher, ILiquidityProviderDispatcherTrait};
use spline_v0::profile::{ILiquidityProfileDispatcher, ILiquidityProfileDispatcherTrait};
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

    tokenA.approve(lp.contract_address, 0xffffffffffffffffffffffffffffffff);
    tokenB.approve(lp.contract_address, 0xffffffffffffffffffffffffffffffff);

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
            before_initialize_pool: false,
            after_initialize_pool: false,
            before_swap: false,
            after_swap: true,
            before_update_position: true,
            after_update_position: true,
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
    let lp_ownable: IOwnableDispatcher = IOwnableDispatcher {
        contract_address: lp.contract_address,
    };
    let lp_owner: ContractAddress = lp_ownable.owner();
    assert_eq!(lp_profile, profile.contract_address);
    assert_eq!(lp_core, ekubo_core().contract_address);
    assert_eq!(lp_owner, owner);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_sets_liquidity_profile() {
    let (pool_key, lp, _, profile, default_profile_params, token0, token1) = setup();
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let initial_tick = i129 { mag: 0, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = (step.mag * n.mag * (*default_profile_params[0].mag)) / (1900000);
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());

    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    assert_eq!(profile.get_liquidity_profile(pool_key), default_profile_params);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_deploys_pool_token() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let initial_tick = i129 { mag: 0, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = (step.mag * n.mag * (*default_profile_params[0].mag)) / (1900000);
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());

    assert_eq!(lp.pool_token(pool_key), Zero::<ContractAddress>::zero());
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    let pool_token = lp.pool_token(pool_key);
    assert_ne!(pool_token, Zero::<ContractAddress>::zero());

    let lp_token = ILiquidityProviderTokenDispatcher { contract_address: pool_token };
    assert_eq!(lp_token.authority(), lp.contract_address);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_initializes_pool() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let initial_tick = i129 { mag: 100, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = (step.mag * n.mag * (*default_profile_params[0].mag)) / (1900000);
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());

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

    let liquidity_factor = *default_profile_params[0];
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    assert_eq!(n.mag, 4);
    let liquidity_updates: Span<UpdatePositionParameters> = array![
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 1, sign: false } * step,
                upper: initial_tick + i129 { mag: 1, sign: false } * step,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 1, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 2, sign: false } * step,
                upper: initial_tick + i129 { mag: 2, sign: false } * step,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 2, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 3, sign: false } * step,
                upper: initial_tick + i129 { mag: 3, sign: false } * step,
            },
            liquidity_delta: liquidity_factor / i129 { mag: 3, sign: false },
        },
        UpdatePositionParameters {
            salt: 0,
            bounds: Bounds {
                lower: initial_tick - i129 { mag: 4, sign: false } * step,
                upper: initial_tick + i129 { mag: 4, sign: false } * step,
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

    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = (step.mag * n.mag * (*default_profile_params[0].mag)) / (1900000);
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());

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
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());
    assert_eq!(token0.balance_of(lp.contract_address), amount.into());
    assert_eq!(token1.balance_of(lp.contract_address), amount.into());

    let ekubo_balance0 = token0.balance_of(core.contract_address);
    let ekubo_balance1 = token1.balance_of(core.contract_address);

    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);

    let (balance0, balance1) = (
        token0.balance_of(lp.contract_address), token1.balance_of(lp.contract_address),
    );
    assert_lt!(balance0, amount.into() / 10); // less than 10% left of dust
    assert_lt!(balance1, amount.into() / 10); // less than 10% left of dust

    let (ekubo_balance0_after, ekubo_balance1_after) = (
        token0.balance_of(core.contract_address), token1.balance_of(core.contract_address),
    );
    assert_eq!(ekubo_balance0_after, ekubo_balance0 + amount.into() - balance0);
    assert_eq!(ekubo_balance1_after, ekubo_balance1 + amount.into() - balance1);

    // sweep and check that no dust left
    ISweepableDispatcher { contract_address: lp.contract_address }
        .sweep(token0.contract_address, get_contract_address());
    ISweepableDispatcher { contract_address: lp.contract_address }
        .sweep(token1.contract_address, get_contract_address());
    assert_eq!(token0.balance_of(lp.contract_address), 0);
    assert_eq!(token1.balance_of(lp.contract_address), 0);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_mints_initial_shares_to_liquidity_provider() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();

    let initial_liquidity_factor = *default_profile_params[0];
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let initial_tick = i129 { mag: 0, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = (step.mag * n.mag * (*default_profile_params[0].mag)) / (1900000);
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());
    assert_eq!(token0.balance_of(lp.contract_address), amount.into());
    assert_eq!(token1.balance_of(lp.contract_address), amount.into());

    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);

    let pool_token = IERC20Dispatcher { contract_address: lp.pool_token(pool_key) };
    assert_eq!(pool_token.balance_of(lp.contract_address), initial_liquidity_factor.mag.into());
    assert_eq!(pool_token.total_supply(), initial_liquidity_factor.mag.into());
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_sets_initial_liquidity_factor() {
    let (pool_key, lp, _, _, default_profile_params, token0, token1) = setup();

    let initial_liquidity_factor = *default_profile_params[0];
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let initial_tick = i129 { mag: 0, sign: false };
    // roughly given initial tick = 0. there should be excess in the lp contract after
    // @dev quoter to fix this amount excess issue
    let amount: u128 = (step.mag * n.mag * (*default_profile_params[0].mag)) / (1900000);
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());
    assert_eq!(token0.balance_of(lp.contract_address), amount.into());
    assert_eq!(token1.balance_of(lp.contract_address), amount.into());

    assert_eq!(lp.pool_liquidity_factor(pool_key), 0);
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    assert_eq!(lp.pool_liquidity_factor(pool_key), initial_liquidity_factor.mag);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Caller is not the owner',))]
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
    let step = *default_profile_params[2];
    let n = *default_profile_params[3];
    let amount: u128 = (step.mag * n.mag * (*default_profile_params[0].mag)) / (1900000);
    token0.transfer(lp.contract_address, amount.into());
    token1.transfer(lp.contract_address, amount.into());
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
        fee: 34028236692093846346337460743176821, // 1 bps (= 2**128 / 10000)
        tick_spacing: 1, // 0.01 bps
        extension: Zero::<ContractAddress>::zero(),
    };
    lp.create_and_initialize_pool(new_pool_key, initial_tick, default_profile_params);
}
