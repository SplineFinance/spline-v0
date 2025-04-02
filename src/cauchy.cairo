/// Interface representing `Cauchy`.
/// This interface allows mint and burn of Cauchy fungible liquidity tokens.
#[starknet::interface]
pub trait ICauchy<TContractState> {
    fn mint(ref self: TContractState, amount: u256);
    fn burn(ref self: TContractState, amount: u256);
}

#[starknet::contract]
pub mod Cauchy {
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::ContractAddress;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.erc20.initializer("Spline v0 LP Token", "SPLV0-LP");
    }
}
