#[starknet::contract]
pub mod TestProfile {
    use ekubo::interfaces::core::UpdatePositionParameters;
    use ekubo::types::bounds::Bounds;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use spline_v0::profile::ILiquidityProfile;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    struct Storage {
        params: Map<PoolKey, (i129, i129, i129, i129)>,
    }

    #[abi(embed_v0)]
    pub impl ILiquidityProfileImpl of ILiquidityProfile<ContractState> {
        fn initial_liquidity_factor(
            self: @ContractState, pool_key: PoolKey, initial_tick: i129,
        ) -> u128 {
            let (lf, _, _, _) = self.params.read(pool_key);
            lf.mag
        }

        fn description(self: @ContractState) -> (ByteArray, ByteArray) {
            ("Test Profile", "TP")
        }

        fn set_liquidity_profile(ref self: ContractState, pool_key: PoolKey, params: Span<i129>) {
            assert(params.len() == 4, 'Invalid params length');
            assert(!*params[0].sign, 'Invalid liquidity factor sign');
            assert(!*params[2].sign, 'Invalid step sign');
            assert(!*params[3].sign, 'Invalid n sign');
            self.params.write(pool_key, (*params[0], *params[1], *params[2], *params[3]));
        }

        fn get_liquidity_profile(self: @ContractState, pool_key: PoolKey) -> Span<i129> {
            let (lf, initial_tick, step, n) = self.params.read(pool_key);
            array![lf, initial_tick, step, n].span()
        }

        fn get_liquidity_updates(
            self: @ContractState, pool_key: PoolKey, liquidity_factor: i129,
        ) -> Span<UpdatePositionParameters> {
            let (_, initial_tick, step, n) = self.params.read(pool_key);
            let mut updates = array![];
            for i in 0..n.mag {
                let update_params = UpdatePositionParameters {
                    salt: 0,
                    bounds: Bounds {
                        lower: initial_tick - i129 { mag: (1 + i), sign: false } * step,
                        upper: initial_tick + i129 { mag: (1 + i), sign: false } * step,
                    },
                    liquidity_delta: liquidity_factor / i129 { mag: (i + 1), sign: false },
                };
                updates.append(update_params);
            }

            updates.span()
        }
    }
}
