use ekubo::components::util::serialize;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use sncast_std::{DeclareResultTrait, FeeSettingsTrait, call, declare, deploy, get_nonce, invoke};

// The example below uses a contract deployed to the Sepolia testnet
const LP_ADDRESS: felt252 = 0x071526eff10921bfb796bceb24d3c8587c5a22b4cf081180640c293db8b12da6;
const TOKEN0_ADDRESS: felt252 = 0x01eef5765e3a5d6dd690ada3f8162f4fc6d62112028da27e9f518233afb9b66d; // TODO: replace
const TOKEN1_ADDRESS: felt252 = 0x03Fe2b97C1Fd336E750087D68B9b867997Fd64a2661fF3ca5A7C771641e8e7AC; // TODO: replace

fn main() {
    let fee_settings = FeeSettingsTrait::max_fee(999999999999999999);
    let pool_key = PoolKey {
        token0: TOKEN0_ADDRESS.try_into().unwrap(),
        token1: TOKEN1_ADDRESS.try_into().unwrap(),
        fee: 0,
        tick_spacing: 1,
        extension: LP_ADDRESS.try_into().unwrap(),
    };
    let initial_tick = i129 { mag: 0, sign: false };

    // s, res, tick_start, tick_max, l0, mu, gamma, rho
    let params = array![
        i129 { mag: 1000, sign: false },
        i129 { mag: 4, sign: false },
        i129 { mag: 0, sign: false },
        i129 { mag: 8000, sign: false },
        i129 { mag: 1000, sign: false },
        i129 { mag: 0, sign: false },
        i129 { mag: 2000, sign: false },
        i129 { mag: 64000, sign: false },
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
