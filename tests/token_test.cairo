use core::num::traits::Zero;
use ekubo::components::util::serialize;
use ekubo::types::keys::PoolKey;
use openzeppelin_token::erc20::interface::{
    IERC20Dispatcher, IERC20DispatcherTrait, IERC20MetadataDispatcher,
    IERC20MetadataDispatcherTrait,
};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::token::{ILiquidityProviderTokenDispatcher, ILiquidityProviderTokenDispatcherTrait};
use starknet::{ContractAddress, get_contract_address};

fn deploy_token(
    class: @ContractClass, pool_key: PoolKey, name: ByteArray, symbol: ByteArray,
) -> ILiquidityProviderTokenDispatcher {
    let (contract_address, _) = class
        .deploy(@serialize::<(PoolKey, ByteArray, ByteArray)>(@(pool_key, name, symbol)))
        .expect('Deploy token failed');

    ILiquidityProviderTokenDispatcher { contract_address }
}

fn setup() -> ILiquidityProviderTokenDispatcher {
    let token_class = declare("LiquidityProviderToken").unwrap().contract_class();

    let pool_key = PoolKey {
        token0: Zero::<ContractAddress>::zero(),
        token1: Zero::<ContractAddress>::zero(),
        extension: get_contract_address(),
        fee: 0,
        tick_spacing: 1,
    };
    let token = deploy_token(token_class, pool_key, "Token A", "A");
    token
}

#[test]
fn test_constructor_sets_name_and_symbol() {
    let token = setup();
    let token_erc20 = IERC20MetadataDispatcher { contract_address: token.contract_address };
    assert_eq!(token_erc20.name(), "Token A");
    assert_eq!(token_erc20.symbol(), "A");
}

#[test]
fn test_mint_mints_funds() {
    let token = setup();
    let auth = get_contract_address();

    let token_erc20 = IERC20Dispatcher { contract_address: token.contract_address };
    assert_eq!(token_erc20.balance_of(token.contract_address), 0);

    let amount = 100;
    token.mint(auth, amount);
    assert_eq!(token_erc20.balance_of(auth), amount);
    assert_eq!(token_erc20.total_supply(), amount);

    token.mint(token.contract_address, amount);
    assert_eq!(token_erc20.balance_of(token.contract_address), amount);
    assert_eq!(token_erc20.total_supply(), amount * 2);
}

fn setup_not_authority() -> ILiquidityProviderTokenDispatcher {
    let token_class = declare("LiquidityProviderToken").unwrap().contract_class();

    let pool_key = PoolKey {
        token0: Zero::<ContractAddress>::zero(),
        token1: Zero::<ContractAddress>::zero(),
        extension: Zero::<ContractAddress>::zero(),
        fee: 0,
        tick_spacing: 1,
    };
    let token = deploy_token(token_class, pool_key, "Token A", "A");
    token
}

#[test]
#[should_panic(expected: ('Not authority',))]
fn test_mint_fails_if_not_authority() {
    let token = setup_not_authority();
    let auth = get_contract_address();
    token.mint(auth, 100);
}

#[test]
fn test_burn_burns_funds() {
    let token = setup();
    let auth = get_contract_address();
    token.mint(auth, 100);
    token.mint(token.contract_address, 100);

    let token_erc20 = IERC20Dispatcher { contract_address: token.contract_address };
    assert_eq!(token_erc20.total_supply(), 200);
    assert_eq!(token_erc20.balance_of(auth), 100);
    assert_eq!(token_erc20.balance_of(token.contract_address), 100);

    let amount = 50;
    token.burn(auth, amount);
    assert_eq!(token_erc20.balance_of(auth), 50);
    assert_eq!(token_erc20.balance_of(token.contract_address), 100);
    assert_eq!(token_erc20.total_supply(), 150);

    token.burn(token.contract_address, amount);
    assert_eq!(token_erc20.balance_of(auth), 50);
    assert_eq!(token_erc20.balance_of(token.contract_address), 50);
    assert_eq!(token_erc20.total_supply(), 100);
}

#[test]
#[should_panic(expected: ('Not authority',))]
fn test_burn_fails_if_not_authority() {
    let token = setup_not_authority();
    let auth = get_contract_address();
    token.burn(auth, 100);
}
