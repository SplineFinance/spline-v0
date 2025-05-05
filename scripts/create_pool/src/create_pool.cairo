use ekubo::components::util::serialize;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use sncast_std::{DeclareResultTrait, FeeSettingsTrait, call, declare, deploy, get_nonce, invoke};

// The example below uses a contract deployed to the Sepolia testnet
const LP_ADDRESS: felt252 = 0x02253efb6547890843ed4e3d315d40307660ecb72e7364667c90700ecffae490;
const TOKEN0_ADDRESS: felt252 =
    0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac; // TODO: replace
const TOKEN1_ADDRESS: felt252 =
    0x0577bddfccc35c714e99638d4f03ee6bc51e38895c7abc4df1b1e1ab4854b2ce; // TODO: replace

fn main() {
    let fee_settings = FeeSettingsTrait::max_fee(99999999999999999999);
    let pool_key = PoolKey {
        token0: TOKEN0_ADDRESS.try_into().unwrap(),
        token1: TOKEN1_ADDRESS.try_into().unwrap(),
        fee: 34028236692093846346337460743176821, // 1 bps
        tick_spacing: 1,
        extension: LP_ADDRESS.try_into().unwrap(),
    };
    let initial_tick = i129 { mag: 0, sign: false };

    // s, res, tick_start, tick_max, l0, mu, gamma, rho
    let params = array![
        i129 { mag: 1000, sign: false },
        i129 { mag: 4, sign: false },
        i129 { mag: 0, sign: false },
        i129 { mag: 16000, sign: false },
        i129 { mag: 100000000, sign: false },
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
