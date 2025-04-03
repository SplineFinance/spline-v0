#[starknet::interface]
pub trait ILiquidityProviderToken<TStorage> {
    fn mint(ref self: TStorage, to: starknet::ContractAddress, amount: u256);
    fn burn(ref self: TStorage, from: starknet::ContractAddress, amount: u256);
}

#[starknet::contract]
pub mod LiquidityProviderToken {
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};
    use super::ILiquidityProviderToken;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, name: ByteArray, symbol: ByteArray) {
        self.owner.write(get_caller_address());
        self.erc20.initializer(name, symbol);
    }

    #[abi(embed_v0)]
    pub impl LiquidityProviderTokenImpl of ILiquidityProviderToken<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
            assert(self.owner.read() == get_caller_address(), 'Not owner');
            self.erc20.mint(to, amount);
        }

        fn burn(ref self: ContractState, from: ContractAddress, amount: u256) {
            assert(self.owner.read() == get_caller_address(), 'Not owner');
            self.erc20.burn(from, amount);
        }
    }
}
