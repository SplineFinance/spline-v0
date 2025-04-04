use core::num::traits::Zero;
use ekubo::components::util::serialize;
use ekubo::interfaces::core::{
    ICoreDispatcher, ICoreDispatcherTrait, IExtension, ILocker, SwapParameters,
    UpdatePositionParameters,
};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait};
use ekubo::types::call_points::CallPoints;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use openzeppelin_access::ownable::interface::{IOwnableDispatcher, IOwnableDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::lp::{ILiquidityProviderDispatcher, ILiquidityProviderDispatcherTrait};
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

fn router() -> IRouterDispatcher {
    IRouterDispatcher {
        contract_address: contract_address_const::<
            0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e,
        >(),
    }
}

fn profile_params(liquidity_factor: u128, step: u128, n: u128) -> Span<i129> {
    array![
        i129 { mag: liquidity_factor, sign: true },
        i129 { mag: step, sign: true },
        i129 { mag: n, sign: true },
    ]
        .span()
}

fn setup() -> (
    PoolKey, ILiquidityProviderDispatcher, ContractAddress, ILiquidityProfileDispatcher, Span<i129>,
) {
    let contract_class = declare("LiquidityProvider").unwrap().contract_class();

    let profile: ILiquidityProfileDispatcher = ILiquidityProfileDispatcher {
        contract_address: deploy_contract(
            declare("TestProfile").unwrap().contract_class(), array![],
        ),
    };
    let default_profile_params = profile_params(1000000000000000000, 2000, 100);

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

    (pool_key, lp, owner, profile, default_profile_params)
}

#[test]
#[fork("mainnet")]
fn test_constructor_sets_callpoints() {
    let (pool_key, _, _, _, _) = setup();
    assert_eq!(
        ekubo_core().get_call_points(pool_key.extension),
        CallPoints {
            before_initialize_pool: true,
            after_initialize_pool: true,
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
    let (_, lp, owner, profile, _) = setup();
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
    let (pool_key, lp, _, profile, default_profile_params) = setup();
    let initial_tick = i129 { mag: 0, sign: true };
    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    assert_eq!(profile.get_liquidity_profile(pool_key), default_profile_params);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_deploys_pool_token() {
    let (pool_key, lp, _, _, default_profile_params) = setup();
    let initial_tick = i129 { mag: 0, sign: true };
    assert_eq!(lp.pool_token(pool_key), Zero::<ContractAddress>::zero());

    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);
    let pool_token = lp.pool_token(pool_key);
    assert_ne!(pool_token, Zero::<ContractAddress>::zero());

    let lp_token = ILiquidityProviderTokenDispatcher { contract_address: pool_token };
    assert_eq!(lp_token.authority(), lp.contract_address);
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_initializes_pool() {}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_adds_initial_liquidity_to_pool() {
    let (pool_key, lp, _, _, default_profile_params) = setup();
    let initial_tick = i129 { mag: 0, sign: true };
    let token0: IERC20Dispatcher = IERC20Dispatcher { contract_address: pool_key.token0 };
    let token1: IERC20Dispatcher = IERC20Dispatcher { contract_address: pool_key.token1 };

    assert!(token0.balance_of(lp.contract_address) == 0, "Token0 lp bal0 != 0");
    assert!(token1.balance_of(lp.contract_address) == 0, "Token1 lp bal1 != 0");

    let balance0_this_before = token0.balance_of(get_contract_address());
    let balance1_this_before = token1.balance_of(get_contract_address());

    lp.create_and_initialize_pool(pool_key, initial_tick, default_profile_params);

    let balance0_this_after = token0.balance_of(get_contract_address());
    let balance1_this_after = token1.balance_of(get_contract_address());

    assert!(
        balance0_this_after <= balance0_this_before, "Token0 balance of this contract increased",
    );
    assert!(
        balance1_this_after <= balance1_this_before, "Token1 balance of this contract increased",
    );
}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_mints_initial_shares_to_liquidity_provider() {}

#[test]
#[fork("mainnet")]
fn test_create_and_initialize_pool_sets_initial_liquidity_factor() {}
