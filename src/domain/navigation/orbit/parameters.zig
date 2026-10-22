const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const constants = @import("domain/navigation/orbit/constants");
const angles = @import("base/math/angles");
const time_clock = @import("domain/time/clock");

const GpsTime = time.GpsTime;

pub const epoch_step_ms = 300_000;
pub const epoch_step_s = epoch_step_ms / 1000;

pub const Alignment = struct { parameters: Parameters, rebased: bool };

pub const Parameters = struct {
    sat: gnss_types.SatId,
    toe: GpsTime,
    toc: GpsTime,
    m0: f64,
    delta_n: f64,
    delta_n_dot: f64,
    ecc: f64,
    sqrt_a: f64,
    a_dot: f64,
    omega0: f64,
    i0: f64,
    w: f64,
    omega_dot: f64,
    idot: f64,
    cuc: f64,
    cus: f64,
    crc: f64,
    crs: f64,
    cic: f64,
    cis: f64,
    af0: f64,
    af1: f64,
    af2: f64,

    pub fn system(self: Parameters) gnss_types.System {
        return self.sat.system;
    }

    pub fn weekScale(self: Parameters) time.WeekScale {
        return switch (self.sat.system) {
            .gps => .gps,
            .bds => .bds,
            .gal => .gal,
            .glo => unreachable,
        };
    }

    pub fn clock(self: *const Parameters) time_clock.Poly {
        return .{ .toc = self.toc, .af0 = self.af0, .af1 = self.af1, .af2 = self.af2 };
    }

    pub fn withClockEpoch(self: Parameters, toc: GpsTime) Parameters {
        const polynomial = self.clock();
        var out = self;
        out.toc = toc;
        out.af0 = polynomial.bias(toc);
        out.af1 = polynomial.drift(toc);
        return out;
    }

    pub fn rawMisfit(self: *const Parameters) ?[:0]const u8 {
        if (self.calculationMisfit()) |name| return name;
        // The angles' fields wrap any value, but beyond a turn none was broadcast, and near the largest doubles the
        // orbit's sines of twice them overflow.
        if (!(@abs(self.m0) <= angles.two_pi)) return "m0";
        if (!(@abs(self.w) <= angles.two_pi)) return "w";
        if (!(@abs(self.omega0) <= angles.two_pi)) return "omega0";
        return null;
    }

    /// Finite, propagatable parameters; derived angles may differ by whole turns.
    pub fn calculationMisfit(self: *const Parameters) ?[:0]const u8 {
        inline for (@typeInfo(Parameters).@"struct".field_names) |name| {
            if (@FieldType(Parameters, name) == f64) {
                if (!std.math.isFinite(@field(self, name))) return name;
            }
        }
        if (!(self.ecc >= 0 and self.ecc <= 0.5)) return "ecc";
        const a = self.sqrt_a * self.sqrt_a;
        if (!(self.sqrt_a > 0 and a >= 1e7 and a <= 5e7)) return "sqrt_a";
        return null;
    }

    pub fn alignedToEpochStep(self: Parameters) Alignment {
        const scale = self.weekScale();
        const toe_ms: i64 = self.toe.inScale(scale).ms;
        const new_ms = @divFloor(toe_ms, epoch_step_ms) * epoch_step_ms;
        if (new_ms == toe_ms and @mod(self.toc.inScale(scale).ms, epoch_step_ms) == 0) return .{ .parameters = self, .rebased = false };
        const dt: f64 = @as(f64, @floatFromInt(new_ms - toe_ms)) / 1000.0;
        const new_toe = self.toe.addSeconds(dt);
        const mu = constants.get(self.system()).mu;
        const axis = self.sqrt_a * self.sqrt_a;
        const n0 = @sqrt(mu) / (axis * self.sqrt_a);
        const delta_n = self.delta_n + self.delta_n_dot * dt;
        const n = n0 + delta_n;
        var out = self.withClockEpoch(new_toe);
        out.toe = new_toe;
        out.sqrt_a = @sqrt(axis + self.a_dot * dt);
        out.delta_n = delta_n;
        out.m0 = self.m0 + n * dt;
        out.i0 = self.i0 + self.idot * dt;
        out.omega0 = self.omega0 + self.omega_dot * dt;
        return .{ .parameters = out, .rebased = true };
    }
};
