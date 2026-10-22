const std = @import("std");

pub const Range = struct {
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),
    open_min: bool = false,
    open_max: bool = false,

    pub fn holds(self: Range, v: f64) bool {
        if (!std.math.isFinite(v)) return false;
        const above = if (self.open_min) v > self.min else v >= self.min;
        const below = if (self.open_max) v < self.max else v <= self.max;
        return above and below;
    }

    /// The range in words, after "must be": "from 1 to 3", "1", "at least 0", "above 0 and below 360".
    pub fn format(self: Range, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const low = std.math.isFinite(self.min);
        const high = std.math.isFinite(self.max);
        if (low and high and !self.open_min and !self.open_max) {
            if (self.min == self.max) return w.print("{d}", .{self.min});
            return w.print("from {d} to {d}", .{ self.min, self.max });
        }
        if (low) try w.print("{s} {d}", .{ if (self.open_min) "above" else "at least", self.min });
        if (low and high) try w.writeAll(" and ");
        if (high) try w.print("{s} {d}", .{ if (self.open_max) "below" else "at most", self.max });
    }
};
