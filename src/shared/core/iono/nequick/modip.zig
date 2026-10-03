const floats = @import("floats.zig");

const rows = 39;
const cols = 39;
const lon_step_deg: f64 = 10.0;
const lat_step_deg: f64 = 5.0;

pub const Grid = struct {
    values: [rows][cols]f64,

    pub fn parse(self: *Grid, text: []const u8) floats.Error!void {
        return floats.readFloats(text, &.{@as(*[rows * cols]f64, @ptrCast(&self.values))});
    }

    pub fn at(self: *const Grid, lat_deg: f64, lon_deg: f64) f64 {
        if (lat_deg <= -90) return -90;
        if (lat_deg >= 90) return 90;
        const lng1 = (normalizeLongitude(lon_deg) + 180.0) / lon_step_deg;
        const c0: usize = @intFromFloat(@floor(lng1));
        const dj = lng1 - @floor(lng1);
        const lat1 = (lat_deg + 90.0) / lat_step_deg + 1.0;
        const fi = @max(1.0, @floor(lat1 - 1e-6));
        const r0: usize = @intFromFloat(fi - 1);
        const di = lat1 - fi;
        var z: [4]f64 = undefined;
        for (&z, 0..) |*zk, k| {
            const column: [4]f64 = .{ self.values[r0][c0 + k], self.values[r0 + 1][c0 + k], self.values[r0 + 2][c0 + k], self.values[r0 + 3][c0 + k] };
            zk.* = interpolate(column, di);
        }
        return interpolate(z, dj);
    }
};

fn normalizeLongitude(lon_deg: f64) f64 {
    return @mod(lon_deg + 180.0, 360.0) - 180.0;
}

fn interpolate(z: [4]f64, x: f64) f64 {
    if (@abs(2.0 * x) < 1e-10) return z[1];
    const delta = 2.0 * x - 1.0;
    const g1 = z[2] + z[1];
    const g2 = z[2] - z[1];
    const g3 = z[3] + z[0];
    const g4 = (z[3] - z[0]) / 3.0;
    const a0 = 9.0 * g1 - g3;
    const a1 = 9.0 * g2 - g4;
    const a2 = g3 - g1;
    const a3 = g4 - g2;
    return (a0 + (a1 + (a2 + a3 * delta) * delta) * delta) / 16.0;
}
