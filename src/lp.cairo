#[starknet::interface]
pub trait ILiquidityProvider<TStorage> {
    fn add_liquidity(ref self: TStorage, pool_key: ekubo::types::keys::PoolKey, amount: u128);
    fn remove_liquidity(ref self: TStorage, pool_key: ekubo::types::keys::PoolKey, amount: u128);
}

/// TODO: inherit from ekubo extension
/// TODO: mint should take in x, y desired amounts and use dL / L = dy / y = dx / x to calculate
/// amount of lp tokens to mint TODO: burn should take in amount of lp tokens and use L = L0 + x * y
/// / (x + dx) to calculate amount of x, y to burn TODO: afterSwap hook should store updates
/// physical amounts of x, y in contract state
///
/// TODO: liquidity profiles are the components used in this contract

#[starknet::contract]
pub mod LiquidityProvider {
    use core::num::traits::Zero;
    use ekubo::components::shared_locker::{
        call_core_with_callback, consume_callback_data, handle_delta,
    };
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker};
    use ekubo::types::call_points::CallPoints;
    use ekubo::types::delta::Delta;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::storage::{
        Map, StorageMapReadAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use crate::token::{ILiquidityProviderTokenDispatcher, ILiquidityProviderTokenDispatcherTrait};
    use super::ILiquidityProvider;

    #[storage]
    pub struct Storage {
        core: ICoreDispatcher,
        pool_reserves: Map<ContractAddress, (u128, u128)>,
        pool_liquidity_factors: Map<ContractAddress, u128>,
        pool_tokens: Map<PoolKey, ILiquidityProviderTokenDispatcher>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, core: ICoreDispatcher) {
        // TODO: deploy new erc20 for each pool key initialized with ERC20 external that only
        // LiquidityProvider can call
        self.core.write(core);
        // TODO: fix to set call points correctly
        core
            .set_call_points(
                CallPoints {
                    before_initialize_pool: false,
                    after_initialize_pool: false,
                    before_swap: false,
                    after_swap: true,
                    before_update_position: true,
                    after_update_position: false,
                    before_collect_fees: false,
                    after_collect_fees: false,
                },
            );
        /// TODO: must have initializer internal function to calculate and add initial liquidity
    /// TODO: must have liquidity profile component or interface fed in to keep in storage
    /// TODO: if make interface, can just call to calculate
    }

    #[abi(embed_v0)]
    pub impl LiquidityProviderImpl of ILiquidityProvider<ContractState> {
        fn add_liquidity(ref self: ContractState, pool_key: PoolKey, amount: u128) {
            assert(pool_key.extension == get_contract_address(), 'Extension not this contract');

            // obtain core lock. should also effectively lock this contract for unique pool key
            let core = self.core.read();
            let caller = get_caller_address();
            let liquidity_delta = i129 { mag: amount, sign: true };
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_delta, caller));

            let shares = self.get_shares(pool_key, amount);
            let pool_token = self.pool_tokens.read(pool_key); // TODO: check if no pool token
            pool_token.mint(caller, shares);
        }

        fn remove_liquidity(ref self: ContractState, pool_key: PoolKey, amount: u128) {
            assert(pool_key.extension == get_contract_address(), 'Extension not this contract');

            // obtain core lock. should also effectively lock this contract for unique pool key
            let core = self.core.read();
            let caller = get_caller_address();
            let liquidity_delta = i129 { mag: amount, sign: true };
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_delta, caller));

            let shares = self.get_shares(pool_key, amount);
            let pool_token = self.pool_tokens.read(pool_key); // TODO: check if no pool token
            pool_token.burn(caller, shares);
        }
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn update_positions(
            self: @ContractState, pool_key: PoolKey, payer: ContractAddress, liquidity_delta: i129,
        ) -> Delta {
            // TODO: modify position add liquidity on core
            Zero::<Delta>::zero()
        }

        fn get_shares(self: @ContractState, pool_key: PoolKey, amount: u128) -> u256 {
            Zero::<u256>::zero()
        }
    }

    #[abi(embed_v0)]
    impl LockedImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            let (pool_key, liquidity_delta, caller) = consume_callback_data::<
                (PoolKey, i129, ContractAddress),
            >(core, data);

            // modify liquidity profile positions on ekubo core
            let balance_delta = self.update_positions(pool_key, caller, liquidity_delta);

            // settle up balance deltas with core
            handle_delta(core, pool_key.token0, balance_delta.amount0, caller);
            handle_delta(core, pool_key.token1, balance_delta.amount1, caller);

            array![].span()
        }
    }
}
