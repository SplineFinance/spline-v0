/// SymmetricLiquidityProfile is a profile for deploying concentrated liquidity according to a
/// symmetric discretized liquidity profile.
///
/// Adds/remove liquidity by working down the full tick range. Partitions the
/// full tick range into N segments each of width 2 * s such that the ith
/// segment is between ticks: (s * 2**i, s * 2**(i+1)). Total number
/// of segments to cover full tick range: 1 + floor(log(t_max / s) / log(2)).
///
/// Each segment is binned evenly with resolution R_i = 2**(i-r), such that
/// within a segment there are always 2**r bins. `resolution` = 2**r
///
/// Total ticks to add/remove liquidity would be total number of bins
/// across full tick range: 2**r * (1 + floor(log(t_max / s) / log(2))).
///
/// Number of SSTORE calls then grows by log(1/s).
#[starknet::component]
pub mod SymmetricLiquidityProfileComponent {
    use ekubo::types::bounds::Bounds;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use spline_v0::profiles::bounds::ILiquidityProfileBounds;
    use starknet::get_caller_address;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    pub struct Storage {
        grid: Map<PoolKey, (u128, u128, i129, i129)> // s, res, tick_start, tick_max
    }

    #[embeddable_as(SymmetricLiquidityProfile)]
    pub impl SymmetricLiquidityProfileImpl<
        TContractState, +HasComponent<TContractState>,
    > of ILiquidityProfileBounds<ComponentState<TContractState>> {
        fn get_bounds_for_liquidity_updates(
            self: @ComponentState<TContractState>, pool_key: PoolKey,
        ) -> Span<Bounds> {
            let (s, res, tick_start, tick_max) = self.grid.read(pool_key);
            let mut ticks: Bounds = Bounds { lower: tick_start, upper: tick_start };
            let mut bounds = array![];

            let mut seg: i129 = i129 { mag: 2 * s, sign: false };
            let mut next: Bounds = Bounds { lower: tick_start - seg, upper: tick_start + seg };
            let mut step: i129 = i129 { mag: (2 * s) / res, sign: false };

            let mut i: u256 = 0;
            while ticks.upper != tick_max {
                // (0, 2*s], [2*s, 4*s], [4*s, 8*s], [8*s, 16*s], ...
                // with each range split up into 1/resolution bins
                ticks.lower -= step;
                ticks.upper += step;

                if ticks.upper > tick_max {
                    ticks.upper = tick_max;
                    break;
                } else if ticks.upper == next.upper {
                    if i > 0 {
                        seg *= i129 { mag: 2, sign: false };
                        step *= i129 { mag: 2, sign: false };
                    }
                    i += 1;
                    next = Bounds { lower: next.lower - seg, upper: next.upper + seg };
                }

                bounds.append(ticks);
            }

            bounds.span()
        }
    }

    #[generate_trait]
    pub impl SymmetricLiquidityProfileInternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn _set_grid_for_bounds(
            ref self: ComponentState<TContractState>, pool_key: PoolKey, params: Span<i129>,
        ) {
            assert(params.len() == 4, 'Invalid params length');
            assert(!*params[0].sign, 'Invalid grid s');
            assert(!*params[1].sign, 'Invalid grid resolution');

            let (s, res, tick_start, tick_max) = (
                *params[0].mag, *params[1].mag, *params[2], *params[3],
            );

            assert((res > 0 && (res % 2 == 0)), 'resolution must be power of 2');
            assert(tick_start < tick_max, 'tick_start must be < tick_max');
            assert(s > 0 && (s % pool_key.tick_spacing == 0), 's must divide by tick_spacing');
            assert((2 * s) / res != 0, 'step must be non-zero');

            self.grid.write(pool_key, (s, res, tick_start, tick_max));
        }

        fn _get_grid(
            ref self: ComponentState<TContractState>, pool_key: PoolKey,
        ) -> (u128, u128, i129, i129) {
            self.grid.read(pool_key)
        }
    }
}
