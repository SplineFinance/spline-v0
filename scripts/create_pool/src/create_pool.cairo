use ekubo::components::util::serialize;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use sncast_std::{DeclareResultTrait, FeeSettingsTrait, call, declare, deploy, get_nonce, invoke};

// The example below uses a contract deployed to the Sepolia testnet
const LP_ADDRESS: felt252 = 0x078fbf83da3a7d909ecd0c9b827031e5b5e58ecf5dde3033e9c2110de708334c;
const TOKEN0_ADDRESS: felt252 =
    0x03e3e511edccccd3218f12b32f86c2f9f21d6d760e2af1fbd7d415ea477c3113; // TODO: replace
const TOKEN1_ADDRESS: felt252 =
    0x04e06f6ff5e7624edddffaaa6848709ba40ff4d8bc29b5855904d7c69846c228; // TODO: replace

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
        i129 { mag: 1000000000000000000, sign: false },
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
