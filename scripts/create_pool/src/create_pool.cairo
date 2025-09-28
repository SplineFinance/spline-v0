use ekubo::components::util::serialize;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use sncast_std::{DeclareResultTrait, FeeSettingsTrait, call, declare, deploy, get_nonce, invoke};

// The example below uses a contract deployed to the Starknet
const LP_ADDRESS: felt252 = 0x058688030dde2847b58b7566db088e423aee632a4ed4b02d7dc2082a5177179c;
const TOKEN0_ADDRESS: felt252 =
    0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac; // WBTC (8 decimals)
const TOKEN1_ADDRESS: felt252 =
    0x04daa17763b286d1e59b97c283C0b8C949994C361e426A28F743c67bDfE9a32f; // tBTC (18 decimals)

fn main() {
    let fee_settings = FeeSettingsTrait::max_fee(99999999999999999999);
    let pool_key = PoolKey {
        token0: TOKEN0_ADDRESS.try_into().unwrap(),
        token1: TOKEN1_ADDRESS.try_into().unwrap(),
        fee: 34028236692093846346337460743176821, // 1 bps
        tick_spacing: 1, // 0.01 bps
        extension: LP_ADDRESS.try_into().unwrap(),
    };
    let initial_tick = i129 { mag: 23027700, sign: false }; // current ekubo tick

    // s, res, tick_start, tick_max, l0, mu, gamma, rho
    // @dev careful with token0_decimals != token1_decimals
    let params = array![
        i129 { mag: 1000, sign: false }, // 10 bps
        i129 { mag: 4, sign: false },
        i129 { mag: 23025860, sign: false }, // ~ p=1.0 accounting for token decimal diff and tick spacing
        i129 { mag: 23125860, sign: false }, // tick_start + 1000 bps
        i129 { mag: 10000000000000, sign: false }, // sqrt(10**token0_decimals * 10**token1_decimals)
        i129 { mag: 23025860, sign: false }, // mu: center of distribution (tick_start)
        i129 { mag: 4000, sign: false }, // gamma: distribution spread of 40 bps
        i129 { mag: 23153860, sign: false }, // rho = mu + 1280 bps: distribution decay tick
    ]
        .span();

    let data: Array<felt252> = serialize::<
        (PoolKey, i129, Span<i129>),
    >(@(pool_key, initial_tick, params));
    let invoke_nonce = get_nonce('pending');
    let invoke_result = invoke(
        LP_ADDRESS.try_into().unwrap(),
        selector!("create_and_initialize_pool"),
        data,
        fee_settings,
        Option::Some(invoke_nonce),
    )
        .expect('map invoke failed');

    assert(invoke_result.transaction_hash != 0, invoke_result.transaction_hash);
}
