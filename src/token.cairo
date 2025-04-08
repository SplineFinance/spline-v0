#[starknet::interface]
pub trait ILiquidityProviderToken<TStorage> {
    // returns the mint/burn authority of the lp token
    fn authority(self: @TStorage) -> starknet::ContractAddress;

    // initializes lp token with authority
    fn initialize(ref self: TStorage, authority: starknet::ContractAddress);

    // mints an amount of lp tokens to `to`
    fn mint(ref self: TStorage, to: starknet::ContractAddress, amount: u256);

    // burns an amount of lp tokens from `from`
    fn burn(ref self: TStorage, from: starknet::ContractAddress, amount: u256);
}

#[starknet::contract]
pub mod LiquidityProviderToken {
    use core::num::traits::Zero;
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
        authority: ContractAddress,
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
        self.erc20.initializer(name, symbol);
    }

    #[abi(embed_v0)]
    pub impl LiquidityProviderTokenImpl of ILiquidityProviderToken<ContractState> {
        fn authority(self: @ContractState) -> ContractAddress {
            self.authority.read()
        }

        fn initialize(ref self: ContractState, authority: ContractAddress) {
            assert(
                self.authority.read() == Zero::<starknet::ContractAddress>::zero(),
                'Already initialized',
            );
            self.authority.write(authority);
        }

        fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
            assert(self.authority.read() == get_caller_address(), 'Not authority');
            self.erc20.mint(to, amount);
        }

        fn burn(ref self: ContractState, from: ContractAddress, amount: u256) {
            assert(self.authority.read() == get_caller_address(), 'Not authority');
            self.erc20.burn(from, amount);
        }
    }
}
