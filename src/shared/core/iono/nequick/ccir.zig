const constants = @import("../../constants.zig");
const floats = @import("floats.zig");

const f2_rows = 76;
const f2_cols = 13;
const m3_rows = 49;
const m3_cols = 9;
const f2_count = 2 * f2_rows * f2_cols;
const m3_count = 2 * m3_rows * m3_cols;

pub const Month = struct {
    f2: [2][f2_rows][f2_cols]f64,
    m3: [2][m3_rows][m3_cols]f64,

    pub fn parse(self: *Month, text: []const u8) floats.Error!void {
        return floats.readFloats(text, &.{ @as(*[f2_count]f64, @ptrCast(&self.f2)), @as(*[m3_count]f64, @ptrCast(&self.m3)) });
    }
};

pub const Epoch = struct {
    cf2: [f2_rows]f64,
    cm3: [m3_rows]f64,

    pub fn compute(month: *const Month, azr: f64, ut_hours: f64) Epoch {
        const rr2 = azr / 100.0;
        const rr1 = 1.0 - rr2;
        const t = constants.deg2rad(ut_hours * 15.0 - 180.0);
        var sinh: [6]f64 = undefined;
        var cosh: [6]f64 = undefined;
        sinh[0] = @sin(t);
        cosh[0] = @cos(t);
        for (1..6) |k| {
            sinh[k] = sinh[k - 1] * cosh[0] + cosh[k - 1] * sinh[0];
            cosh[k] = cosh[k - 1] * cosh[0] - sinh[k - 1] * sinh[0];
        }
        var e: Epoch = undefined;
        for (&e.cf2, 0..) |*c, j| {
            var sum = month.f2[0][j][0] * rr1 + month.f2[1][j][0] * rr2;
            for (1..7) |k| {
                const s = month.f2[0][j][2 * k - 1] * rr1 + month.f2[1][j][2 * k - 1] * rr2;
                const cc = month.f2[0][j][2 * k] * rr1 + month.f2[1][j][2 * k] * rr2;
                sum += s * sinh[k - 1] + cc * cosh[k - 1];
            }
            c.* = sum;
        }
        for (&e.cm3, 0..) |*c, j| {
            var sum = month.m3[0][j][0] * rr1 + month.m3[1][j][0] * rr2;
            for (1..5) |k| {
                const s = month.m3[0][j][2 * k - 1] * rr1 + month.m3[1][j][2 * k - 1] * rr2;
                const cc = month.m3[0][j][2 * k] * rr1 + month.m3[1][j][2 * k] * rr2;
                sum += s * sinh[k - 1] + cc * cosh[k - 1];
            }
            c.* = sum;
        }
        return e;
    }

    const Frequencies = struct { fof2_mhz: f64, m3000: f64 };

    pub fn evaluate(self: *const Epoch, modip_deg: f64, lat_deg: f64, lon_deg: f64) Frequencies {
        var sin_modip: [12]f64 = undefined;
        const s = @sin(constants.deg2rad(modip_deg));
        sin_modip[0] = 1.0;
        for (1..12) |n| sin_modip[n] = sin_modip[n - 1] * s;
        for (&sin_modip) |*v| if (@abs(v.*) <= 1e-30) {
            v.* = 0;
        };
        const cos_lat = @cos(constants.deg2rad(lat_deg));
        const lon = constants.deg2rad(lon_deg);
        var longitude: [8]Harmonic = undefined;
        for (&longitude, 1..) |*harmonic, k| {
            const kf: f64 = @floatFromInt(k);
            harmonic.* = .{ .cos = @cos(kf * lon), .sin = @sin(kf * lon) };
        }
        return .{
            .fof2_mhz = harmonicSum(&self.cf2, &[_]usize{ 11, 11, 8, 4, 1, 0, 0, 0, 0 }, sin_modip, cos_lat, &longitude),
            .m3000 = harmonicSum(&self.cm3, &[_]usize{ 6, 7, 5, 2, 1, 0, 0 }, sin_modip, cos_lat, &longitude),
        };
    }
};

const Harmonic = struct { cos: f64, sin: f64 };

fn harmonicSum(c: []const f64, nq: []const usize, sin_modip: [12]f64, cos_lat: f64, longitude: *const [8]Harmonic) f64 {
    var result: f64 = 0;
    for (0..nq[0] + 1) |j| result += c[j] * sin_modip[j];
    var r: usize = 0;
    var cos_pow: f64 = 1.0;
    for (1..nq.len) |k| {
        r += 2 * (nq[k - 1] + 1);
        const base = r - (nq[0] + 1);
        cos_pow *= cos_lat;
        const ck = longitude[k - 1].cos;
        const sk = longitude[k - 1].sin;
        for (0..nq[k] + 1) |i| {
            result += sin_modip[i] * cos_pow * (c[base + 2 * i] * ck + c[base + 2 * i + 1] * sk);
        }
    }
    return result;
}
