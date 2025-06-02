use core::num::traits::Zero;
use core::option::OptionTrait;
use core::serde::Serde;
use ekubo::components::util::serialize;
use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
use ekubo::types::i129::i129;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use starknet::syscalls::call_contract_syscall;
use starknet::{ContractAddress, get_contract_address};

pub fn try_call_core_with_callback<TInput, TOutput, +Serde<TInput>, +Serde<TOutput>>(
    core: ICoreDispatcher, input: @TInput,
) -> Option<TOutput> {
    let data = serialize(input).span();
    let mut calldata = serialize(@data).span();
    // TODO: is this valid for ekubo core with callback into lp? to bypass full tx reverts
    let call_result = call_contract_syscall(core.contract_address, selector!("lock"), calldata);
    match call_result {
        Result::Ok(mut output_span) => {
            Option::Some(Serde::deserialize(ref output_span).expect('DESERIALIZE_RESULT_FAILED'))
        },
        Result::Err(_) => { Option::None(()) },
    }
}

/// overrides ekubo handle delta to safe transfer tokens in prior to paying core
pub fn handle_delta(
    core: ICoreDispatcher, token: ContractAddress, delta: i129, account: ContractAddress,
) {
    if (delta.is_non_zero()) {
        if (delta.sign) {
            // account receives the tokens out
            core.withdraw(token, account, delta.mag);
        } else {
            // account pays the tokens in
            let token = IERC20Dispatcher { contract_address: token };
            if (account != get_contract_address()) {
                // attempt to transfer the tokens in to this contract prior to paying core
                safe_transfer_from(token, account, get_contract_address(), delta.mag.into());
            }
            token.approve(core.contract_address, delta.mag.into());
            core.pay(token.contract_address);
        }
    }
}

/// handles both transfer_from and transferFrom interfaces for ERC20 token calls
pub fn safe_transfer_from(
    token: IERC20Dispatcher, sender: ContractAddress, recipient: ContractAddress, amount: u256,
) {
    let mut calldata = serialize(@(sender, recipient, amount)).span();
    let mut success = false;

    // Try the new interface first (transfer_from)
    let call_result = call_contract_syscall(
        token.contract_address, selector!("transfer_from"), calldata,
    );
    match call_result {
        Result::Ok(_) => { success = true; },
        Result::Err(_) => {
            // Fall back to legacy interface (transferFrom)
            let call_result = call_contract_syscall(
                token.contract_address, selector!("transferFrom"), calldata,
            );
            match call_result {
                Result::Ok(_) => { success = true; },
                Result::Err(_) => { success = false; },
            }
        },
    }
    assert(success, 'Transfer from failed');
}
