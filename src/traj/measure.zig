//! The length of a path from its speed, by its parameter u from 0 to 1 (anything whose `speed(u)` gives its speed by
//! the parameter, and that speed's rate): eight-point Gauss-Legendre over parts of it, a part halved while its length
//! disagrees with its halves'.
const std = @import("std");

const nodes = [8]f64{ -0.9602898564975363, -0.7966664774136267, -0.5255324099163290, -0.1834346424956498, 0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363 };
const weights = [8]f64{ 0.1012285362903763, 0.2223810344533745, 0.3137066458778873, 0.3626837833783620, 0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763 };
const rounding = 4 * std.math.floatEps(f64);

/// A length that is told, not built on, is settled to a billionth of each part's, in at most 16 parts a part.
const relative = 1e-9;
const most_parts = 16;
/// The speed is read at so many even steps for where it is least.
const samples = 16;

/// The length from low to high, by eight-point Gauss-Legendre.
pub fn length(p: anytype, low: f64, high: f64) f64 {
    var sum: f64 = 0;
    for (nodes, weights) |x, w| sum += w * p.speed(low + (x + 1) / 2 * (high - low))[0];
    return sum * (high - low) / 2;
}

/// Whether a part's length agrees with its halves' to `settled`, or to its own rounding.
pub fn settles(whole: f64, left: f64, right: f64, settled: f64) bool {
    return @abs(whole - left - right) <= @max(settled, rounding * whole);
}

/// A length that is told, not built on: cut first where the speed is least inside the path (where the motion
/// reverses, the speed has a kink that halving settles only slowly), found between a step where it falls and the
/// next where it rises, then each part settled. A speed whose rate moves it by less than it is settled to over a step
/// neither falls nor rises.
pub fn told(p: anytype) f64 {
    var sum: f64 = 0;
    var from: f64 = 0;
    var falling: ?f64 = null;
    for (0..samples + 1) |i| {
        const u = @as(f64, @floatFromInt(i)) / samples;
        const s = p.speed(u);
        if (s[1] < -s[0] * relative * samples) {
            falling = u;
        } else if (s[1] > s[0] * relative * samples) if (falling) |f| {
            const least = turn(p, f, u);
            sum += settle(p, from, least);
            from = least;
            falling = null;
        };
    }
    return sum + settle(p, from, 1);
}

/// Where the speed is least between a point where it falls and one where it rises: by halving, to the rounding of
/// the parameter.
fn turn(p: anytype, falling: f64, rising: f64) f64 {
    var low = falling;
    var high = rising;
    while (true) {
        const mid = (low + high) / 2;
        if (mid <= low or mid >= high) return mid;
        if (p.speed(mid)[1] < 0) low = mid else high = mid;
    }
}

/// A part from low to high, halved while its length disagrees with its halves' by more than `relative` of it, in at
/// most `most_parts` parts; a part that ends gives its halves' sum.
fn settle(p: anytype, low: f64, high: f64) f64 {
    const whole = length(p, low, high);
    var halvings: usize = most_parts - 1;
    return halved(p, low, high, whole, relative * whole, &halvings);
}

fn halved(p: anytype, low: f64, high: f64, whole: f64, tolerance: f64, halvings: *usize) f64 {
    const mid = (low + high) / 2;
    const left = length(p, low, mid);
    const right = length(p, mid, high);
    if (settles(whole, left, right, tolerance) or halvings.* == 0) return left + right;
    halvings.* -= 1;
    return halved(p, low, mid, left, tolerance, halvings) + halved(p, mid, high, right, tolerance, halvings);
}
