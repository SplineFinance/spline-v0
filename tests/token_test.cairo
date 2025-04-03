use ekubo::components::util::serialize;
use openzeppelin_token::erc20::interface::{
    IERC20Dispatcher, IERC20DispatcherTrait, IERC20MetadataDispatcher,
    IERC20MetadataDispatcherTrait,
};
use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
use spline_v0::token::{ILiquidityProviderTokenDispatcher, ILiquidityProviderTokenDispatcherTrait};
use starknet::get_contract_address;

fn deploy_token(
    class: @ContractClass, name: ByteArray, symbol: ByteArray,
) -> ILiquidityProviderTokenDispatcher {
    let (contract_address, _) = class
        .deploy(@serialize::<(ByteArray, ByteArray)>(@(name, symbol)))
        .expect('Deploy token failed');

    ILiquidityProviderTokenDispatcher { contract_address }
}

fn setup() -> ILiquidityProviderTokenDispatcher {
    let token_class = declare("LiquidityProviderToken").unwrap().contract_class();
    let token = deploy_token(token_class, "Token A", "A");
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
fn test_initialize_sets_owner() {
    let token = setup();
    let owner = get_contract_address();
    token.initialize(owner);
    assert_eq!(token.owner(), owner);
}

#[test]
#[should_panic(expected: ('Already initialized',))]
fn test_initialize_fails_if_already_initialized() {
    let token = setup();
    let owner = get_contract_address();
    token.initialize(owner);
    token.initialize(token.contract_address);
}

#[test]
fn test_mint_mints_funds() {
    let token = setup();
    let owner = get_contract_address();
    token.initialize(owner);

    let token_erc20 = IERC20Dispatcher { contract_address: token.contract_address };
    assert_eq!(token_erc20.balance_of(token.contract_address), 0);

    let amount = 100;
    token.mint(owner, amount);
    assert_eq!(token_erc20.balance_of(owner), amount);
    assert_eq!(token_erc20.total_supply(), amount);

    token.mint(token.contract_address, amount);
    assert_eq!(token_erc20.balance_of(token.contract_address), amount);
    assert_eq!(token_erc20.total_supply(), amount * 2);
}

#[test]
#[should_panic(expected: ('Not owner',))]
fn test_mint_fails_if_not_owner() {
    let token = setup();
    let owner = get_contract_address();
    token.mint(owner, 100);
}

#[test]
fn test_burn_burns_funds() {
    let token = setup();
    let owner = get_contract_address();
    token.initialize(owner);
    token.mint(owner, 100);
    token.mint(token.contract_address, 100);

    let token_erc20 = IERC20Dispatcher { contract_address: token.contract_address };
    assert_eq!(token_erc20.total_supply(), 200);
    assert_eq!(token_erc20.balance_of(owner), 100);
    assert_eq!(token_erc20.balance_of(token.contract_address), 100);

    let amount = 50;
    token.burn(owner, amount);
    assert_eq!(token_erc20.balance_of(owner), 50);
    assert_eq!(token_erc20.balance_of(token.contract_address), 100);
    assert_eq!(token_erc20.total_supply(), 150);

    token.burn(token.contract_address, amount);
    assert_eq!(token_erc20.balance_of(owner), 50);
    assert_eq!(token_erc20.balance_of(token.contract_address), 50);
    assert_eq!(token_erc20.total_supply(), 100);
}

#[test]
#[should_panic(expected: ('Not owner',))]
fn test_burn_fails_if_not_owner() {
    let token = setup();
    let owner = get_contract_address();
    token.burn(owner, 100);
}
