#[starknet::interface]
pub trait ILiquidityProviderToken<TContractState> {
    fn mint(ref self: TContractState, amount: u256);
    fn burn(ref self: TContractState, amount: u256);
}

/// TODO: inherit from ekubo extension
/// TODO: mint should take in x, y desired amounts and use dL / L = dy / y = dx / x to calculate
/// amount of lp tokens to mint TODO: burn should take in amount of lp tokens and use L = L0 + x * y
/// / (x + dx) to calculate amount of x, y to burn TODO: afterSwap hook should store updates
/// physical amounts of x, y in contract state

#[starknet::component]
pub mod LiquidityProviderToken {
    use ekubo::components::shared_locker::{call_core_with_callback, consume_callback_data};
    use ekubo::interfaces::core::{
        ICoreDispatcher, ICoreDispatcherTrait, IExtension, IForwardee, ILocker, SwapParameters,
        UpdatePositionParameters,
    };
    use openzeppelin_token::erc20::ERC20Component;
    use starknet::ContractAddress;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
    }

    #[embeddable_as(LiquidityProviderTokenImpl)]
    impl LiquidityProviderTokenImpl<
        TContractState,
        +HasComponent<TContractState, ERC20Component>,
        impl LockedImpl: ILocker<TContractState>,
    > of super::ILiquidityProviderToken<TContractState> {
        fn mint(ref self: ContractState, amount: u128) {
            let core = self.core.read();
            call_core_with_callback::<(PoolKey, u128, bool), ()>(core, @(pool_key, amount, true));
            self.erc20.mint(starknet::get_caller_address(), amount);
        }

        fn burn(ref self: ContractState, amount: u128) {
            let core = self.core.read();
            call_core_with_callback::<(PoolKey, u128, bool), ()>(core, @(pool_key, amount, false));
            self.erc20.burn(starknet::get_caller_address(), amount);
        }
    }

    #[abi(embed_v0)]
    impl LockedImpl of ILocker<TContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            let (pool_key, liquidity_delta, is_minting) = consume_callback_data::<
                (PoolKey, u128, bool),
            >(core, data);
            if is_minting {
                self.add_liquidity(liquidity_delta);
            } else {
                self.remove_liquidity(liquidity_delta);
            }
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState, ERC20Component>,
    > of InternalTrait<TContractState> {
        fn add_liquidity(ref self: ContractState, liquidity_delta: u128) {// TODO: Implement so iterates over liquidity profile adding to ekubo liquidity positions
        }

        fn remove_liquidity(ref self: ContractState, liquidity_delta: u128) {// TODO: Implement so iterates over liquidity profile removing from ekubo liquidity
        // positions
        }
    }
}
