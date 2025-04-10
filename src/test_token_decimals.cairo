use starknet::ContractAddress;

#[starknet::contract]
pub mod TestTokenDecimals {
    use openzeppelin_token::erc20::interface::{IERC20, IERC20Metadata};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        total_supply: u256,
        balances: Map<ContractAddress, u256>,
        allowances: Map<ContractAddress, Map<ContractAddress, u256>>,
        name: ByteArray,
        symbol: ByteArray,
        decimals: u8,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {}

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        decimals: u8,
        recipient: ContractAddress,
        amount: u256,
    ) {
        self.name.write(name);
        self.symbol.write(symbol);
        self.decimals.write(decimals);
        self.balances.entry(recipient).write(amount);
        self.total_supply.write(amount);
    }

    #[abi(embed_v0)]
    impl IERC20MetadataImpl of IERC20Metadata<ContractState> {
        /// Returns the name of the token.
        fn name(self: @ContractState) -> ByteArray {
            self.name.read()
        }

        /// Returns the ticker symbol of the token, usually a shorter version of the name.
        fn symbol(self: @ContractState) -> ByteArray {
            self.symbol.read()
        }

        /// Returns the number of decimals used to get its user representation.
        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }
    }

    #[abi(embed_v0)]
    impl IERC20Impl of IERC20<ContractState> {
        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.allowances.entry(owner).read(spender)
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let balance = self.balances.read(get_caller_address());
            assert(balance >= amount, 'INSUFFICIENT_TRANSFER_BALANCE');
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            self.balances.write(get_caller_address(), balance - amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let allowance = self.allowances.entry(sender).read(get_caller_address());
            assert(allowance >= amount, 'INSUFFICIENT_ALLOWANCE');
            let balance = self.balances.read(sender);
            assert(balance >= amount, 'INSUFFICIENT_TF_BALANCE');
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            self.balances.write(sender, balance - amount);
            self.allowances.entry(sender).write(get_caller_address(), allowance - amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            self.allowances.entry(get_caller_address()).write(spender, amount.try_into().unwrap());
            true
        }
    }
}
