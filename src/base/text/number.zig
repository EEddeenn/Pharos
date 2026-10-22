const std = @import("std");

const Range = @import("base/math/range").Range;

/// A diagnostic number, normally rounded to four significant digits.
/// Increase precision when rounding would conceal a failed bound, a distinct value or a fraction.
pub const Number = struct {
    value: f64,
    /// The range the value breaks.
    outside: ?Range = null,
    /// A distinct value, such as the result of snapping onto a grid.
    apart: ?f64 = null,
    /// A crossed bound; rounding must remain closer to the value than this bound.
    past: ?f64 = null,
    /// Whether the value is one with a fraction.
    fraction: bool = false,

    pub fn format(self: Number, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // A value a caller of the C API gives, or a knot's time, may be NaN or infinite.
        if (!std.math.isFinite(self.value)) return w.print("{d}", .{self.value});
        var text: [64]u8 = undefined;
        var scientific: []const u8 = undefined;
        var written: f64 = undefined;
        for (3..17) |precision| {
            scientific = std.fmt.float.render(&text, self.value, .{ .precision = precision }) catch unreachable;
            written = std.fmt.parseFloat(f64, scientific) catch unreachable;
            if (self.outside) |range| if (range.holds(written)) continue;
            if (self.apart) |other| if (@abs(written - self.value) >= @abs(written - other)) continue;
            if (self.past) |bound| if (!(@abs(written - self.value) < @abs(self.value - bound))) continue;
            if (self.fraction and written == @floor(written)) continue;
            break;
        }
        const e = std.mem.findScalar(u8, scientific, 'e').?;
        const exponent = std.fmt.parseInt(i32, scientific[e + 1 ..], 10) catch unreachable;
        if (self.value == 0 or (exponent >= -3 and exponent < 6)) return w.print("{d}", .{written});
        // The digits as written, not parsed again: rounding can carry a double past the largest.
        try w.print("{s}e{d}", .{ std.mem.trimEnd(u8, std.mem.trimEnd(u8, scientific[0..e], "0"), "."), exponent });
    }
};
