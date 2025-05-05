use core::option::OptionTrait;
use core::serde::Serde;
use ekubo::components::util::serialize;
use ekubo::interfaces::core::ICoreDispatcher;
use starknet::syscalls::call_contract_syscall;

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
