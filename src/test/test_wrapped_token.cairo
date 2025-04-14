#[starknet::interface]
pub trait ITestWrappedToken<TStorage> {
    // mints an amount of wrapped tokens to caller
    fn mint(ref self: TStorage, amount: u256);

    // burns an amount of wrapped tokens sending underlying to caller
    fn burn(ref self: TStorage, amount: u256);
}

#[starknet::contract]
pub mod TestWrappedToken {
    use openzeppelin_token::erc20::interface::{
        IERC20, IERC20CamelOnly, IERC20Dispatcher, IERC20DispatcherTrait, IERC20Metadata,
        IERC20MetadataDispatcher, IERC20MetadataDispatcherTrait,
    };
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::storage::{
        StorageMapReadAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use super::ITestWrappedToken;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        underlying: IERC20Dispatcher,
        decimals: u8,
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
    fn constructor(ref self: ContractState, underlying: IERC20Dispatcher) {
        self.erc20.initializer("Wrapped Wrapped BTC", "WWBTC");
        self.decimals.write(8);
        self.underlying.write(underlying);
    }

    #[abi(embed_v0)]
    impl TestWrappedToken of ITestWrappedToken<ContractState> {
        fn mint(ref self: ContractState, amount: u256) {
            let underlying = self.underlying.read();
            let balance = underlying.balance_of(get_contract_address());

            let total_supply = self.erc20.total_supply();
            assert(total_supply + amount <= balance, 'Insufficient balance to mint');
            self.erc20.mint(get_caller_address(), amount);
        }

        fn burn(ref self: ContractState, amount: u256) {
            let underlying = self.underlying.read();
            self.erc20.burn(get_contract_address(), amount);
            underlying.transfer(get_caller_address(), amount);
        }
    }

    #[abi(embed_v0)]
    impl ERC20 of IERC20<ContractState> {
        /// Returns the value of tokens in existence.
        fn total_supply(self: @ContractState) -> u256 {
            self.erc20.ERC20_total_supply.read()
        }

        /// Returns the amount of tokens owned by `account`.
        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.erc20.ERC20_balances.read(account)
        }

        /// Returns the remaining number of tokens that `spender` is
        /// allowed to spend on behalf of `owner` through `transfer_from`.
        /// This is zero by default.
        /// This value changes when `approve` or `transfer_from` are called.
        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.erc20.ERC20_allowances.read((owner, spender))
        }

        /// Moves `amount` tokens from the caller's token balance to `to`.
        ///
        /// Requirements:
        ///
        /// - `recipient` is not the zero address.
        /// - The caller has a balance of at least `amount`.
        ///
        /// Emits a `Transfer` event.
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let sender = starknet::get_caller_address();
            self.erc20._transfer(sender, recipient, amount);
            true
        }

        /// Moves `amount` tokens from `from` to `to` using the allowance mechanism.
        /// `amount` is then deducted from the caller's allowance.
        ///
        /// Requirements:
        ///
        /// - `sender` is not the zero address.
        /// - `sender` must have a balance of at least `amount`.
        /// - `recipient` is not the zero address.
        /// - The caller has an allowance of `sender`'s tokens of at least `amount`.
        ///
        /// Emits a `Transfer` event.
        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let caller = starknet::get_caller_address();
            self.erc20._spend_allowance(sender, caller, amount);
            self.erc20._transfer(sender, recipient, amount);
            true
        }

        /// Sets `amount` as the allowance of `spender` over the caller’s tokens.
        ///
        /// Requirements:
        ///
        /// - `spender` is not the zero address.
        ///
        /// Emits an `Approval` event.
        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let caller = starknet::get_caller_address();
            self.erc20._approve(caller, spender, amount);
            true
        }
    }

    #[abi(embed_v0)]
    impl ERC20Metadata of IERC20Metadata<ContractState> {
        /// Returns the name of the token.
        fn name(self: @ContractState) -> ByteArray {
            self.erc20.ERC20_name.read()
        }

        /// Returns the ticker symbol of the token, usually a shorter version of the name.
        fn symbol(self: @ContractState) -> ByteArray {
            self.erc20.ERC20_symbol.read()
        }

        /// Returns the number of decimals used to get its user representation.
        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }
    }

    #[abi(embed_v0)]
    impl ERC20CamelOnly of IERC20CamelOnly<ContractState> {
        fn totalSupply(self: @ContractState) -> u256 {
            ERC20::total_supply(self)
        }

        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            ERC20::balance_of(self, account)
        }

        fn transferFrom(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            ERC20::transfer_from(ref self, sender, recipient, amount)
        }
    }
}
