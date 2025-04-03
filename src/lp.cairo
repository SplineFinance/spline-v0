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
/// TODO: fix for collect fees and compound into liquidity, likely on after swap (?) which should
/// TODO: also increase liquidity factor
///
/// TODO: for fees, should afterSwap always collect swap fees from the positions swapped through and
/// escrow in this contract TODO: then have harvest function that attempts to auto compund
/// calculating liquidity factor delta from fees using reserve TODO: balances in contract storage.
/// reserve balances should be updated also on afterSwap and afterUpdatePosition

#[starknet::contract]
pub mod LiquidityProvider {
    use core::felt252_div;
    use core::num::traits::Zero;
    use ekubo::components::shared_locker::{
        call_core_with_callback, consume_callback_data, handle_delta,
    };
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker};
    use ekubo::types::call_points::CallPoints;
    use ekubo::types::delta::Delta;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use crate::profile::{ILiquidityProfileDispatcher, ILiquidityProfileDispatcherTrait};
    use crate::token::{ILiquidityProviderTokenDispatcher, ILiquidityProviderTokenDispatcherTrait};
    use super::ILiquidityProvider;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    // Ownable Mixin
    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    pub struct Storage {
        core: ICoreDispatcher,
        profile: ILiquidityProfileDispatcher,
        pool_reserves: Map<PoolKey, (u128, u128)>,
        pool_liquidity_factors: Map<PoolKey, u128>,
        pool_tokens: Map<PoolKey, ContractAddress>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, core: ICoreDispatcher, profile: ILiquidityProfileDispatcher,
    ) {
        self.ownable.initializer(get_caller_address());

        /// TODO: must have initializer internal function to calculate and add initial liquidity
        // TODO: deploy new erc20 for each pool key initialized with ERC20 external that only
        // LiquidityProvider can call
        self.profile.write(profile);

        // TODO: fix to set call points correctly
        self.core.write(core);
        core
            .set_call_points(
                CallPoints {
                    before_initialize_pool: true,
                    after_initialize_pool: false,
                    before_swap: false,
                    after_swap: true,
                    before_update_position: false,
                    after_update_position: true,
                    before_collect_fees: false,
                    after_collect_fees: false,
                },
            );
    }

    #[abi(embed_v0)]
    pub impl LiquidityProviderImpl of ILiquidityProvider<ContractState> {
        fn add_liquidity(ref self: ContractState, pool_key: PoolKey, amount: u128) {
            assert(pool_key.extension == get_contract_address(), 'Extension not this contract');

            // obtain core lock. should also effectively lock this contract for unique pool key
            let core = self.core.read();
            let caller = get_caller_address();
            let liquidity_factor_delta = i129 { mag: amount, sign: true };
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_factor_delta, caller));

            let pool_token = self.pool_tokens.read(pool_key); // TODO: check if no pool token
            let total_shares = IERC20Dispatcher { contract_address: pool_token }.total_supply();
            let liquidity_factor = self.pool_liquidity_factors.read(pool_key);
            let shares = self
                .calculate_shares(total_shares, liquidity_factor_delta, liquidity_factor);

            // add amount to liquidity factor in storage
            let new_liquidity_factor = liquidity_factor + amount;
            self.pool_liquidity_factors.write(pool_key, new_liquidity_factor);

            // mint pool token shares to caller
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }.mint(caller, shares);
        }

        fn remove_liquidity(ref self: ContractState, pool_key: PoolKey, amount: u128) {
            assert(pool_key.extension == get_contract_address(), 'Extension not this contract');

            // obtain core lock. should also effectively lock this contract for unique pool key
            let core = self.core.read();
            let caller = get_caller_address();
            let liquidity_factor_delta = i129 { mag: amount, sign: false };
            call_core_with_callback::<
                (PoolKey, i129, ContractAddress), (),
            >(core, @(pool_key, liquidity_factor_delta, caller));

            let pool_token = self.pool_tokens.read(pool_key); // TODO: check if no pool token
            let total_shares = IERC20Dispatcher { contract_address: pool_token }.total_supply();
            let liquidity_factor = self.pool_liquidity_factors.read(pool_key);
            let shares = self
                .calculate_shares(total_shares, liquidity_factor_delta, liquidity_factor);

            // remove amount from liquidity factor in storage
            assert(liquidity_factor >= amount, 'Not enough liquidity');
            let new_liquidity_factor = liquidity_factor - amount;
            self.pool_liquidity_factors.write(pool_key, new_liquidity_factor);

            // burn pool token shares from caller
            ILiquidityProviderTokenDispatcher { contract_address: pool_token }.burn(caller, shares);
        }
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn update_positions(
            self: @ContractState,
            pool_key: PoolKey,
            payer: ContractAddress,
            liquidity_factor_delta: i129,
        ) -> Delta {
            // TODO: returned array gas cost can be high, so be careful with this
            let core = self.core.read();
            let profile = self.profile.read();
            let liquidity_update_params = profile
                .get_liquidity_updates(pool_key, liquidity_factor_delta);

            let mut delta = Zero::<Delta>::zero();
            for params in liquidity_update_params {
                delta += core.update_position(pool_key, *params);
            }
            return delta;
        }

        /// Calculates amount of shares to mint or burn based on liquidity delta and factor
        /// @dev total_shares, liquidity delta, and factor are values *before* liquidity delta is
        /// applied
        fn calculate_shares(
            self: @ContractState, total_shares: u256, delta: i129, factor: u128,
        ) -> u256 {
            // TODO: fix to accomodate factor == 0 on initialize so uses initial constant for
            // liquidity profile (fetched)
            assert(total_shares > 0, 'Total shares is 0');
            assert(factor > 0, 'Factor is 0');

            let denom: u256 = if delta.sign {
                factor.try_into().unwrap() + delta.mag.try_into().unwrap()
            } else {
                factor.try_into().unwrap()
            };
            let num: u256 = delta.mag.try_into().unwrap();
            assert(num <= denom, 'Numerator > denominator');

            // into felt for muldiv
            let denom_felt252: felt252 = denom.try_into().unwrap();
            let num_felt252: felt252 = num.try_into().unwrap();
            let total_shares_felt252: felt252 = total_shares.try_into().unwrap();

            let shares_felt252 = total_shares_felt252
                * felt252_div(num_felt252, denom_felt252.try_into().unwrap());
            return shares_felt252.try_into().unwrap();
        }
    }

    #[abi(embed_v0)]
    impl LockedImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            let (pool_key, liquidity_factor_delta, caller) = consume_callback_data::<
                (PoolKey, i129, ContractAddress),
            >(core, data);

            // modify liquidity profile positions on ekubo core
            let balance_delta = self.update_positions(pool_key, caller, liquidity_factor_delta);

            // settle up balance deltas with core
            handle_delta(core, pool_key.token0, balance_delta.amount0, caller);
            handle_delta(core, pool_key.token1, balance_delta.amount1, caller);

            array![].span()
        }
    }
}
