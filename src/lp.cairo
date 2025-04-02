#[starknet::interface]
pub trait ILiquidityProvider<TStorage> {
    fn mint(ref self: TStorage, pool_key: ekubo::types::keys::PoolKey, amount: u128);
    fn burn(ref self: TStorage, pool_key: ekubo::types::keys::PoolKey, amount: u128);
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
    use ekubo::components::shared_locker::{call_core_with_callback, consume_callback_data};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker};
    use ekubo::types::call_points::CallPoints;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use super::ILiquidityProvider;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    // ERC20 Mixin
    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
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
    fn constructor(
        ref self: ContractState, pname: felt252, psymbol: felt252, core: ICoreDispatcher,
    ) {
        self
            .erc20
            .initializer(format!("Spline v0 {} LP Token", pname), format!("SPLV0-{}-LP", psymbol));
        self.core.write(core);
        // TODO: fix to set call points correctly
        core
            .set_call_points(
                CallPoints {
                    before_initialize_pool: false,
                    after_initialize_pool: false,
                    before_swap: false,
                    after_swap: false,
                    before_update_position: false,
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
        fn mint(ref self: ContractState, pool_key: PoolKey, amount: u128) {
            assert(pool_key.extension == get_contract_address(), 'Extension not this contract');

            let core = self.core.read();
            let caller = get_caller_address();
            let delta = i129 { mag: amount, sign: true };
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, delta, caller));

            self.erc20.mint(caller, amount.try_into().unwrap());
        }

        fn burn(ref self: ContractState, pool_key: PoolKey, amount: u128) {
            assert(pool_key.extension == get_contract_address(), 'Extension not this contract');

            let core = self.core.read();
            let caller = get_caller_address();
            let delta = i129 { mag: amount, sign: true };
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, delta, caller));

            self.erc20.burn(caller, amount.try_into().unwrap());
        }
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn add_liquidity(
            self: @ContractState, core: ICoreDispatcher, payer: ContractAddress, liquidity: u128,
        ) {}
        fn remove_liquidity(
            self: @ContractState, core: ICoreDispatcher, payer: ContractAddress, liquidity: u128,
        ) {}
    }
}
