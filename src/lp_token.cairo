#[starknet::interface]
pub trait ILiquidityProviderToken<TContractState> {
    fn mint(ref self: TContractState, amount: u256);
    fn burn(ref self: TContractState, amount: u256);
}

#[starknet::component]
pub mod LiquidityProviderToken {
    use openzeppelin_token::erc20::{ERC20Component};
    use starknet::ContractAddress;

    #[embeddable_as(LiquidityProviderTokenImpl)]
    impl LiquidityProviderTokenImpl<TContractState, +HasComponent<TContractState, ERC20Component>> of super::ILiquidityProviderToken<TContractState> {
        fn mint(ref self: ContractState, amount: u256) {
            self.erc20.mint(amount);
        }

        fn burn(ref self: ContractState, amount: u256) {
            self.erc20.burn(amount);
        }
    }
}
