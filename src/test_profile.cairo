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
        params: Map<PoolKey, (u128, u128, u128)>,
    }

    #[abi(embed_v0)]
    pub impl ILiquidityProfileImpl of ILiquidityProfile<ContractState> {
        fn initial_liquidity_factor(
            ref self: ContractState, pool_key: PoolKey, initial_tick: i129,
        ) -> u128 {
            let (lf, _, _) = self.params.read(pool_key);
            lf
        }

        fn description(ref self: ContractState) -> (ByteArray, ByteArray) {
            ("Test Profile", "TP")
        }

        fn set_liquidity_profile(ref self: ContractState, pool_key: PoolKey, params: Span<i129>) {
            assert(params.len() == 3, 'Invalid params length');
            assert(*params[0].sign, 'Invalid liquidity factor sign');
            assert(*params[1].sign, 'Invalid step sign');
            assert(*params[2].sign, 'Invalid n sign');
            self.params.write(pool_key, (*params[0].mag, *params[1].mag, *params[2].mag));
        }

        fn get_liquidity_profile(ref self: ContractState, pool_key: PoolKey) -> Span<i129> {
            let (lf, step, n) = self.params.read(pool_key);
            array![
                i129 { mag: lf, sign: true },
                i129 { mag: step, sign: true },
                i129 { mag: n, sign: true },
            ]
                .span()
        }

        fn get_liquidity_updates(
            ref self: ContractState, pool_key: PoolKey, liquidity_factor: i129,
        ) -> Span<UpdatePositionParameters> {
            let (_, step, n) = self.params.read(pool_key);
            let mut updates = array![];
            for i in 0..n {
                let update_params = UpdatePositionParameters {
                    salt: 0,
                    bounds: Bounds {
                        lower: i129 { mag: i * step, sign: false },
                        upper: i129 { mag: i * step, sign: true },
                    },
                    liquidity_delta: liquidity_factor / i129 { mag: (1 + i * step), sign: true },
                };
                updates.append(update_params);
            }

            updates.span()
        }
    }
}
