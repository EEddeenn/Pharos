pub fn evaluate(comptime Number: type, comptime Arithmetic: type, comptime order: usize, coefficients: anytype, x: Number) Number {
    const count = coefficients.len;
    if (order >= count) return Arithmetic.constant(0);
    var result = Arithmetic.scale(coefficients[count - 1], fallingFactor(count - 1, order));
    inline for (0..count - order - 1) |i| {
        const index = count - i - 2;
        result = Arithmetic.add(Arithmetic.mul(result, x), Arithmetic.scale(coefficients[index], fallingFactor(index, order)));
    }
    return result;
}

fn fallingFactor(comptime degree: usize, comptime order: usize) f64 {
    comptime var product: usize = 1;
    inline for (0..order) |i| product *= degree - i;
    return @floatFromInt(product);
}
