use ekubo::components::owned::{IOwnedDispatcher, IOwnedDispatcherTrait};
use ekubo::components::upgradeable::{IUpgradeableDispatcher, IUpgradeableDispatcherTrait};
use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, UpdatePositionParameters};
use ekubo::types::keys::{PoolKey, PositionKey};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClass, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, declare,
    spy_events, start_cheat_caller_address, stop_cheat_caller_address,
};
use spline_v0::lp::{ILiquidityProviderDispatcher, ILiquidityProviderDispatcherTrait};
use spline_v0::math::muldiv;
use spline_v0::test::test_wrapped_token::{
    ITestWrappedTokenDispatcher, ITestWrappedTokenDispatcherTrait,
};
use starknet::{ClassHash, ContractAddress, contract_address_const, get_contract_address};

fn ekubo_core() -> ICoreDispatcher {
    ICoreDispatcher {
        contract_address: contract_address_const::<
            0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b,
        >(),
    }
}

fn spline_v0_lp() -> ILiquidityProviderDispatcher {
    ILiquidityProviderDispatcher {
        contract_address: contract_address_const::<
            0x02174812a3a8236077a9f13c5a420ec93ca5e8177e3952605155f5cb0f4ffe85,
        >(),
    }
}

fn token0() -> IERC20Dispatcher {
    IERC20Dispatcher {
        contract_address: contract_address_const::<
            0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac,
        >(),
    }
}

fn token1() -> IERC20Dispatcher {
    IERC20Dispatcher {
        contract_address: contract_address_const::<
            0x0577bddfccc35c714e99638d4f03ee6bc51e38895c7abc4df1b1e1ab4854b2ce,
        >(),
    }
}

fn owner() -> ContractAddress {
    IOwnedDispatcher { contract_address: spline_v0_lp().contract_address }.get_owner()
}

fn whale() -> ContractAddress {
    contract_address_const::<0x0324a36c6d2a8ac2e90a1112499beb0d4ee900768ed9eda22b6906a3a0cb205c>()
}

fn pool_key() -> PoolKey {
    PoolKey {
        token0: token0().contract_address,
        token1: token1().contract_address,
        fee: 34028236692093846346337460743176821, // 1 bps
        tick_spacing: 1, // 0.01 bps
        extension: spline_v0_lp().contract_address,
    }
}

fn setup() -> (
    PoolKey, ICoreDispatcher, ILiquidityProviderDispatcher, IERC20Dispatcher, IERC20Dispatcher,
) {
    let pool_key = pool_key();
    let core = ekubo_core();
    let lp = spline_v0_lp();
    let token0 = token0();
    let token1 = token1();

    // update class hash to new local instance of lp
    start_cheat_caller_address(lp.contract_address, owner());
    IUpgradeableDispatcher { contract_address: lp.contract_address }
        .replace_class_hash(*declare("LiquidityProvider").unwrap().contract_class().class_hash);
    stop_cheat_caller_address(lp.contract_address);

    // send some funds from whale to this address
    start_cheat_caller_address(token0.contract_address, whale());
    token0.transfer(get_contract_address(), 500000000);
    token0.transfer(token1.contract_address, 500000000);
    stop_cheat_caller_address(token0.contract_address);

    // approve tokens for lp to spend from this address
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

    // mint some wrapped tokens
    ITestWrappedTokenDispatcher { contract_address: token1.contract_address }.mint(500000000);

    (pool_key, core, lp, token0, token1)
}

fn one() -> u256 {
    1000000000000000000 // one == 1e18
}

fn assert_close(a: u256, b: u256, tol: u256) {
    let (mi, ma): (u256, u256) = if a > b {
        (b, a)
    } else {
        (a, b)
    };
    assert_lt!(muldiv(ma - mi, one(), mi), tol);
}

#[test]
#[fork("mainnet")]
fn test_debug_add_then_remove_liquidity() {
    let (pool_key, _, lp, token0, token1) = setup();
    let liquidity_factor_minted = 1000000000000;

    assert_eq!(token0.balance_of(get_contract_address()), 500000000);
    assert_eq!(token1.balance_of(get_contract_address()), 500000000);

    // get pool reserves prior
    let (reserve0, reserve1) = lp.pool_reserves(pool_key);

    // cache balances to compare with after add -> remove
    let token0_balance = token0.balance_of(get_contract_address());
    let token1_balance = token1.balance_of(get_contract_address());

    let shares = lp.add_liquidity(pool_key, liquidity_factor_minted);
    let amount0_add = token0_balance - token0.balance_of(get_contract_address());
    let amount1_add = token1_balance - token1.balance_of(get_contract_address());

    let token0_balance_after_add = token0.balance_of(get_contract_address());
    let token1_balance_after_add = token1.balance_of(get_contract_address());

    let (reserve0_after_add, reserve1_after_add) = lp.pool_reserves(pool_key);
    assert_close(reserve0_after_add.into(), reserve0.into() + amount0_add.into(), one() / 10000);
    assert_close(reserve1_after_add.into(), reserve1.into() + amount1_add.into(), one() / 10000);

    let liquidity_factor_burned = lp.remove_liquidity(pool_key, shares);
    assert_eq!(liquidity_factor_minted, liquidity_factor_burned + 1);

    // check balances are back to original less fees
    let amount0_remove = token0.balance_of(get_contract_address()) - token0_balance_after_add;
    let amount1_remove = token1.balance_of(get_contract_address()) - token1_balance_after_add;

    // Q: how much is the protocol fee charged by ekubo?
    // protocol fee looks like same as swap fee of 1 bps so total of 2 bps lost
    assert_close(amount0_remove, (amount0_add * 9998) / 10000, one() / 10000);
    assert_close(amount1_remove, (amount1_add * 9998) / 10000, one() / 10000);

    // check pool reserves after is same as before less amount removed
    let (reserve0_after, reserve1_after) = lp.pool_reserves(pool_key);
    assert_close(reserve0_after.into(), reserve0.into(), one() / 10000);
    assert_close(reserve1_after.into(), reserve1.into(), one() / 10000);
}
