/// SymmetricLiquidityProfile is a profile for deploying concentrated liquidity according to a
/// symmetric discretized liquidity profile.
///
/// Adds/remove liquidity by working down the full tick range. Partitions the
/// full tick range into N segments each of width 2 * s such that the ith
/// segment is between ticks: (s * 2**i, s * 2**(i+1)). Total number
/// of segments to cover full tick range: 1 + floor(log(t_max / s) / log(2)).
///
/// Each segment is binned evenly with resolution R_i = 2**(i-r), such that
/// within a segment there are always 2**r bins.
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

    #[storage]
    struct Storage {
        s: u256,
        r: u256,
        tick_start: i129, // center of distribution
        tick_max: i129,
    }

    #[embeddable_as(SymmetricLiquidityProfile)]
    pub impl SymmetricLiquidityProfileImpl<
        TContractState, +HasComponent<TContractState>,
    > of ILiquidityProfileBounds<ComponentState<TContractState>> {
        fn get_bounds_for_liquidity_updates(
            self: @ComponentState<TContractState>, pool_key: PoolKey,
        ) -> Span<Bounds> {
            let s = self.s;
            let r = self.r;
            let tick_start = self.tick_start;
            let tick_max = self.tick_max;

            array![].span()
        }
    }
}
