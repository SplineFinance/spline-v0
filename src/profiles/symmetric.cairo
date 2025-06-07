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
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    pub const MIN_TICK: i129 = i129 { mag: 88722883, sign: true };
    pub const MAX_TICK: i129 = i129 { mag: 88722883, sign: false };

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
            // @dev upper bound is inclusive of liquidity delta at bound tick so up by one tick
            // spacing to make liquidity profile symmetric about tick start
            let dt = i129 { mag: pool_key.tick_spacing, sign: false };
            let mut ticks: Bounds = Bounds { lower: tick_start, upper: tick_start + dt };
            let mut bounds = array![];

            let mut seg: i129 = i129 { mag: s, sign: false };
            let mut next: Bounds = Bounds { lower: ticks.lower - seg, upper: ticks.upper + seg };
            let mut step: i129 = i129 { mag: s / res, sign: false };

            let mut i: u256 = 0;
            while ticks.upper != (tick_max + dt) {
                // [0, s), [s, 2*s), [2*s, 4*s), [4*s, 8*s), [8*s, 16*s), ...
                // with each range split up into 1/resolution bins
                ticks.lower -= step;
                ticks.upper += step;

                if ticks.upper > (tick_max + dt) {
                    ticks.upper = tick_max + dt;
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

            assert((res > 0 && (res & (res - 1)) == 0), 'resolution must be power of 2');

            assert(s > 0 && (s % pool_key.tick_spacing == 0), 's must divide by tick_spacing');
            assert((s / res) != 0, 'step must be non-zero');
            assert((s % res) == 0, 'step must be div by resolution');
            assert((s / res) % pool_key.tick_spacing == 0, 'step must div by tick_spacing');

            assert(tick_start < tick_max, 'tick_start must be < tick_max');
            assert(tick_start.mag % pool_key.tick_spacing == 0, 'tick_start must div by spacing');
            assert(tick_max.mag % pool_key.tick_spacing == 0, 'tick_max must div by spacing');

            let dt = i129 { mag: pool_key.tick_spacing, sign: false };
            assert(tick_start >= MIN_TICK, 'tick_start must be >= min');
            assert(tick_max <= MAX_TICK - dt, 'tick_max must be <= max');

            self.grid.write(pool_key, (s, res, tick_start, tick_max));
        }

        fn _get_grid(
            self: @ComponentState<TContractState>, pool_key: PoolKey,
        ) -> (u128, u128, i129, i129) {
            self.grid.read(pool_key)
        }
    }
}
