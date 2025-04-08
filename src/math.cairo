use core::integer::{u256_wide_mul, u512, u512_safe_div_rem_by_u256};

// simplified version of muldiv from avnu-contracts-lib
// @dev: https://github.com/avnu-labs/avnu-contracts-lib/blob/main/src/math/muldiv.cairo
pub fn muldiv(x: u256, y: u256, z: u256) -> u256 {
    let numerator: u512 = u256_wide_mul(x, y);
    let (quotient, _) = u512_safe_div_rem_by_u256(numerator, z.try_into().unwrap());

    let overflows = (z <= u256 { low: numerator.limb2, high: numerator.limb3 });
    assert(!overflows, 'muldiv overflow');

    return u256 { low: quotient.limb0, high: quotient.limb1 };
}
