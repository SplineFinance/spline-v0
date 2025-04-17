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

    (pool_key, core, lp, token0, token1)
}

#[test]
#[fork("mainnet")]
fn test_debug_harvest_fees() {
    let (pool_key, _, lp, _, _) = setup();
    // TODO: fix so passes
    lp.add_liquidity(pool_key, 0);
}
