const bounds = [15]f64{ 2.4, 3.4, 4.85, 6.85, 9.65, 13.65, 24, 48, 96, 192, 384, 768, 1536, 3072, 6144 };

pub fn index(meters: f64) u4 {
    if (!(meters >= 0)) return 15;
    for (bounds, 0..) |bound, i| if (meters <= bound) return @intCast(i);
    return 15;
}
