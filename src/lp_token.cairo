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
    use ekubo::types::{CallPoints, Delta, PoolKey, PositionKey, i129, i129_new};
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
            let caller = starknet::get_caller_address();
            let delta = i129_new(amount, true);
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress, bool), (),
            >(core, @(pool_key, delta, caller));
            self.erc20.mint(caller, amount);
        }

        fn burn(ref self: ContractState, amount: u128) {
            let core = self.core.read();
            let caller = starknet::get_caller_address();
            let delta = i129_new(amount, false);
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress, bool), (),
            >(core, @(pool_key, delta, caller));
            self.erc20.burn(caller, amount);
        }
    }

    #[abi(embed_v0)]
    impl LockedImpl of ILocker<TContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            let (pool_key, delta, payer) = consume_callback_data::<
                (PoolKey, i129, ContractAddress),
            >(core, data);
            if (delta.sign) {
                self.add_liquidity(caller, delta.mag);
            } else {
                self.remove_liquidity(caller, delta.mag);
            }
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState, ERC20Component>,
    > of InternalTrait<TContractState> {
        fn add_liquidity(ref self: ContractState, payer: ContractAddress, liquidity: u128) {}
        fn remove_liquidity(ref self: ContractState, payer: ContractAddress, liquidity: u128) {}
    }
}
