use core::num::traits::Zero;
use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
use ekubo::types::i129::i129;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use starknet::{ContractAddress, get_contract_address};

// override of ekubo::components::shared_locker::handle_delta to transfer from given address
pub fn close_delta(
    core: ICoreDispatcher, token: ContractAddress, delta: i129, caller: ContractAddress,
) {
    if (delta.is_non_zero()) {
        if (delta.sign) {
            core.withdraw(token, caller, delta.mag);
        } else {
            let token = IERC20Dispatcher { contract_address: token };
            assert(
                token.transfer_from(caller, get_contract_address(), delta.mag.into()),
                'Transfer from failed',
            );
            token.approve(core.contract_address, delta.mag.into());
            core.pay(token.contract_address);
        }
    }
}
