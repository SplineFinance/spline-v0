use ekubo::components::util::serialize;
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount};
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use sncast_std::{DeclareResultTrait, FeeSettingsTrait, call, declare, deploy, get_nonce, invoke};
use starknet::ContractAddress;

// The example below uses a contract deployed to the Sepolia testnet
const ROUTER_ADDRESS: felt252 = 0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e;
const LP_ADDRESS: felt252 = 0x0745f3180bba2826c33fc66f9571bcb9731d7a55d71e8d935fac5f3e6a8aa1e4;
const TOKEN0_ADDRESS: felt252 =
    0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac; // TODO: replace
const TOKEN1_ADDRESS: felt252 =
    0x0577bddfccc35c714e99638d4f03ee6bc51e38895c7abc4df1b1e1ab4854b2ce; // TODO: replace

fn main() {
    let fee_settings = FeeSettingsTrait::max_fee(99999999999999999999);
    let router = IRouterDispatcher { contract_address: ROUTER_ADDRESS.try_into().unwrap() };
    let pool_key = PoolKey {
        token0: TOKEN0_ADDRESS.try_into().unwrap(),
        token1: TOKEN1_ADDRESS.try_into().unwrap(),
        fee: 34028236692093846346337460743176821, // 1 bps
        tick_spacing: 1,
        extension: LP_ADDRESS.try_into().unwrap(),
    };

    let zero_for_one: bool = true;
    let buy_token: IERC20Dispatcher = if !zero_for_one {
        IERC20Dispatcher { contract_address: TOKEN1_ADDRESS.try_into().unwrap() }
    } else {
        IERC20Dispatcher { contract_address: TOKEN0_ADDRESS.try_into().unwrap() }
    };
    let sell_token: IERC20Dispatcher = if !zero_for_one {
        IERC20Dispatcher { contract_address: TOKEN0_ADDRESS.try_into().unwrap() }
    } else {
        IERC20Dispatcher { contract_address: TOKEN1_ADDRESS.try_into().unwrap() }
    };

    let amount_in: u128 = 6000;
    let invoke_nonce_pre = get_nonce('pending');
    let data_pre: Array<felt252> = serialize::<
        (ContractAddress, u256),
    >(@(router.contract_address, amount_in.into()));
    let invoke_result_pre = invoke(
        buy_token.contract_address,
        selector!("transfer"),
        data_pre,
        fee_settings,
        Option::Some(invoke_nonce_pre),
    )
        .expect('map invoke failed');
    assert(invoke_result_pre.transaction_hash != 0, invoke_result_pre.transaction_hash);

    let route_node: RouteNode = RouteNode { pool_key, sqrt_ratio_limit: 0, skip_ahead: 0 };
    let token_amount: TokenAmount = TokenAmount {
        token: buy_token.contract_address, amount: i129 { mag: amount_in, sign: false },
    };
    let data: Array<felt252> = serialize::<(RouteNode, TokenAmount)>(@(route_node, token_amount));

    let invoke_nonce = get_nonce('pending');
    let invoke_result = invoke(
        ROUTER_ADDRESS.try_into().unwrap(),
        selector!("swap"),
        data,
        fee_settings,
        Option::Some(invoke_nonce),
    )
        .expect('map invoke failed');

    assert(invoke_result.transaction_hash != 0, invoke_result.transaction_hash);

    let invoke_nonce_post = get_nonce('pending');
    let data_post: Array<felt252> = serialize::<
        (ContractAddress,),
    >(@(sell_token.contract_address,));
    let invoke_result_post = invoke(
        ROUTER_ADDRESS.try_into().unwrap(),
        selector!("clear"),
        data_post,
        fee_settings,
        Option::Some(invoke_nonce_post),
    )
        .expect('map invoke failed');

    assert(invoke_result_post.transaction_hash != 0, invoke_result_post.transaction_hash);
}
