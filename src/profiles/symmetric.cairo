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
    use spline_v0::profile::ILiquidityProfile;
    use spline_v0::profiles::bounds::ILiquidityProfileBounds;
    use starknet::storage::StoragePointerReadAccess;

    #[storage]
    struct Storage {
        s: u128,
        resolution: u128, // 2**r
        tick_start: u128, // center of distribution
        tick_max: u128,
    }

    #[embeddable_as(SymmetricLiquidityProfile)]
    pub impl SymmetricLiquidityProfileImpl<
        TContractState,
        +HasComponent<TContractState>,
        +ILiquidityProfile<ComponentState<TContractState>>,
    > of ILiquidityProfileBounds<ComponentState<TContractState>> {
        fn get_bounds_for_liquidity_updates(
            self: @ComponentState<TContractState>, pool_key: PoolKey,
        ) -> Span<Bounds> {
            let res = self.resolution.read();
            assert((res > 0 && (res % 2 == 0)), 'resolution must be power of 2');

            let tick_start = self.tick_start.read();
            let tick_max = self.tick_max.read();
            assert(tick_start < tick_max, 'tick_start must be < tick_max');

            let s = self.s.read();
            assert(s > 0 && (s % pool_key.tick_spacing == 0), 's must divide by tick_spacing');

            let mut tick = tick_start;
            let mut bounds = array![];
            let mut next = tick_start + 2 * s;
            let mut step = (2 * s) / res;
            while tick != tick_max {
                // (0, 2*s], [2*s, 4*s], [4*s, 8*s], ...
                // with each range split up into 1/resolution bins
                tick += step;
                if tick > tick_max {
                    tick = tick_max;
                    break;
                } else if tick == next {
                    step *= 2;
                    next += step;
                }

                bounds
                    .append(
                        Bounds {
                            lower: i129 { mag: tick, sign: true },
                            upper: i129 { mag: tick, sign: false },
                        },
                    );
            }

            bounds.span()
        }
    }
}
