use ekubo::components::util::serialize;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use sncast_std::{DeclareResultTrait, FeeSettingsTrait, call, declare, deploy, get_nonce, invoke};

// The example below uses a contract deployed to the Sepolia testnet
const LP_ADDRESS: felt252 = 0x05b1486e7f3512d65651010858ffab45f22ce7678379b4cb6740e328decebf3e;
const TOKEN0_ADDRESS: felt252 = 0x00B99C8CA89543364E7d5A58D9eBec3F5F521510583AE7Be4A7Cbdf4F4FB1226; // TODO: replace
const TOKEN1_ADDRESS: felt252 = 0x04718f5a0Fc34cC1AF16A1cdee98fFB20C31f5cD61D6Ab07201858f4287c938D; // TODO: replace

fn main() {
    let fee_settings = FeeSettingsTrait::max_fee(99999999999999999999);
    let pool_key = PoolKey {
        token0: TOKEN0_ADDRESS.try_into().unwrap(),
        token1: TOKEN1_ADDRESS.try_into().unwrap(),
        fee: 68056473384187695954059273718202368, // 2 bps
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
