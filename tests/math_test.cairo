use spline_v0::math::muldiv;

#[test]
fn test_muldiv() {
    let a = 1000000000000000000;
    let b = 2000000000000000000;
    let c = 3000000000000000000;
    let result = muldiv(a, b, c);
    assert_eq!(result, 666666666666666666);
}
