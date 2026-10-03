const std = @import("std");
const constants = @import("../../constants.zig");
const modip = @import("modip.zig");
const ccir = @import("ccir.zig");

const chi0: f64 = 86.23292796211615;

fn clipExp(power: f64) f64 {
    if (power > 80) return 5.5406e34;
    if (power < -80) return 1.8049e-35;
    return @exp(power);
}

fn join(f1: f64, f2: f64, alpha: f64, x: f64) f64 {
    const ee = clipExp(alpha * x);
    return (f1 * ee + f2) / (ee + 1.0);
}

fn epstein(nmax: f64, hmax: f64, b: f64, h: f64) f64 {
    const e = clipExp((h - hmax) / b);
    return nmax * e / ((1.0 + e) * (1.0 + e));
}

pub const Sun = struct {
    sin_delta: f64,
    cos_delta: f64,

    pub fn at(month: u8, ut_hours: f64) Sun {
        const dy = 30.5 * @as(f64, @floatFromInt(month)) - 15.0;
        const t = dy + (18.0 - ut_hours) / 24.0;
        const am = constants.deg2rad(0.9856 * t - 3.289);
        const al = am + constants.deg2rad(1.916 * @sin(am) + 0.020 * @sin(2.0 * am) + 282.634);
        const s = 0.39782 * @sin(al);
        return .{ .sin_delta = s, .cos_delta = @sqrt(1.0 - s * s) };
    }
};

pub const Context = struct {
    az: f64,
    azr: f64,
    month: u8,
    ut_hours: f64,
    sun: Sun,
    epoch: *const ccir.Epoch,
    grid: *const modip.Grid,
};

const layer_f2 = 0;
const layer_f1 = 1;
const layer_e = 2;

pub const Layers = struct {
    foe_mhz: f64,
    fof2_mhz: f64,
    m3000: f64,
    nm: [3]f64,
    hm: [3]f64,
    bot: [3]f64,
    top: [3]f64,
    amp: [3]f64,
    peak_density: f64,

    pub fn at(ctx: *const Context, lat_deg: f64, lon_deg: f64) Layers {
        var l: Layers = undefined;
        const mu = ctx.grid.at(lat_deg, lon_deg);
        const freq = ctx.epoch.evaluate(mu, lat_deg, lon_deg);
        l.fof2_mhz = freq.fof2_mhz;
        l.m3000 = freq.m3000;

        const xlt = @mod(ctx.ut_hours + lon_deg / 15.0, 24.0);
        const lat = constants.deg2rad(lat_deg);
        const cos_chi = std.math.clamp(@sin(lat) * ctx.sun.sin_delta + @cos(lat) * ctx.sun.cos_delta * @cos(std.math.pi * (12.0 - xlt) / 12.0), -1.0, 1.0);
        const chi = constants.rad2deg(std.math.atan2(@sqrt(1.0 - cos_chi * cos_chi), cos_chi));
        const seas: f64 = switch (ctx.month) {
            1, 2, 11, 12 => -1.0,
            3, 4, 9, 10 => 0.0,
            else => 1.0,
        };
        const ee = clipExp(0.3 * lat_deg);
        const seasp = seas * (ee - 1.0) / (ee + 1.0);
        const chin = join(90.0 - 0.24 * clipExp(20.0 - 0.2 * chi), chi, 12.0, chi - chi0);
        const sfac = (1.112 - 0.019 * seasp) * @sqrt(@sqrt(ctx.az));
        const fa = sfac * clipExp(@log(@cos(constants.deg2rad(chin))) * 0.3);
        l.foe_mhz = @sqrt(fa * fa + 0.49);

        var fof1 = join(1.4 * l.foe_mhz, 0.0, 1000.0, l.foe_mhz - 2.0);
        fof1 = join(0.0, fof1, 1000.0, l.foe_mhz - fof1);
        fof1 = join(fof1, 0.85 * fof1, 60.0, 0.85 * l.fof2_mhz - fof1);
        if (fof1 < 1e-6) fof1 = 0;

        l.nm = .{ 0.124 * l.fof2_mhz * l.fof2_mhz, 0.124 * fof1 * fof1, 0.124 * l.foe_mhz * l.foe_mhz };
        l.hm[layer_f2] = f2PeakHeight(l.m3000, l.foe_mhz, l.fof2_mhz);
        l.hm[layer_e] = 120.0;
        l.hm[layer_f1] = (l.hm[layer_f2] + l.hm[layer_e]) / 2.0;
        const ndhmx = 0.01 * @exp(-3.467 + 0.857 * @log(l.fof2_mhz * l.fof2_mhz) + 2.02 * @log(l.m3000));
        l.bot[layer_f2] = 0.385 * l.nm[layer_f2] / ndhmx;
        l.top[layer_f1] = 0.3 * (l.hm[layer_f2] - l.hm[layer_f1]);
        l.bot[layer_f1] = 0.5 * (l.hm[layer_f1] - l.hm[layer_e]);
        l.top[layer_e] = @max(l.bot[layer_f1], 7.0);
        l.bot[layer_e] = 5.0;

        l.amp = .{ 4.0 * l.nm[layer_f2], 4.0 * l.nm[layer_f1], 4.0 * l.nm[layer_e] };
        const f2_at_e = epstein(l.amp[layer_f2], l.hm[layer_f2], l.bot[layer_f2], l.hm[layer_e]);
        if (fof1 < 0.5) {
            l.amp[layer_f1] = 0;
            l.amp[layer_e] = 4.0 * (l.nm[layer_e] - f2_at_e);
        } else {
            const f2_at_f1 = epstein(l.amp[layer_f2], l.hm[layer_f2], l.bot[layer_f2], l.hm[layer_f1]);
            for (0..5) |_| {
                l.amp[layer_f1] = 4.0 * (l.nm[layer_f1] -
                    f2_at_f1 -
                    epstein(l.amp[layer_e], l.hm[layer_e], l.top[layer_e], l.hm[layer_f1]));
                l.amp[layer_f1] = join(l.amp[layer_f1], 0.8 * l.nm[layer_f1], 1.0, l.amp[layer_f1] - 0.8 * l.nm[layer_f1]);
                l.amp[layer_e] = 4.0 * (l.nm[layer_e] -
                    epstein(l.amp[layer_f1], l.hm[layer_f1], l.bot[layer_f1], l.hm[layer_e]) -
                    f2_at_e);
            }
        }
        l.amp[layer_e] = join(l.amp[layer_e], 0.05, 60.0, l.amp[layer_e] - 0.005);

        var b2k: f64 = if (ctx.month > 3 and ctx.month < 10)
            6.705 - 0.014 * ctx.azr - 0.008 * l.hm[layer_f2]
        else
            -7.77 + 0.097 * (l.hm[layer_f2] / l.bot[layer_f2]) * (l.hm[layer_f2] / l.bot[layer_f2]) + 0.153 * l.nm[layer_f2];
        b2k = join(b2k, 2.0, 1.0, b2k - 2.0);
        b2k = join(8.0, b2k, 1.0, b2k - 8.0);
        const ha = b2k * l.bot[layer_f2];
        const x = (ha - 150.0) / 100.0;
        const v = (0.041163 * x - 0.183981) * x + 1.424472;
        l.top[layer_f2] = ha / v;
        l.peak_density = l.bottomside(l.hm[layer_f2]);
        return l;
    }

    fn f2PeakHeight(m3000: f64, foe: f64, fof2: f64) f64 {
        const dm: f64 = if (foe >= 1e-30) blk: {
            const r = fof2 / foe;
            const ee = clipExp(20.0 * (r - 1.75));
            const r2 = (r * ee + 1.75) / (ee + 1.0);
            break :blk 0.253 / (r2 - 1.215) - 0.012;
        } else -0.012;
        const mf = m3000 * @sqrt((0.0196 * m3000 * m3000 + 1.0) / (1.2967 * m3000 * m3000 - 1.0));
        return 1490.0 * mf / (m3000 + dm) - 176.0;
    }

    pub fn density(self: *const Layers, h_km: f64) f64 {
        return if (h_km > self.hm[layer_f2]) self.topside(h_km) else self.bottomside(h_km);
    }

    fn bottomside(self: *const Layers, h_km: f64) f64 {
        const b: [3]f64 = .{
            self.bot[layer_f2],
            if (h_km > self.hm[layer_f1]) self.top[layer_f1] else self.bot[layer_f1],
            if (h_km > self.hm[layer_e]) self.top[layer_e] else self.bot[layer_e],
        };
        const h = @max(h_km, 100.0);
        const stretch = @exp(10.0 / (1.0 + @abs(h - self.hm[layer_f2])));
        var s: [3]f64 = undefined;
        var ds: [3]f64 = undefined;
        for (0..3) |j| {
            var arg = (h - self.hm[j]) / b[j];
            if (j != layer_f2) arg *= stretch;
            if (@abs(arg) > 25.0) {
                s[j] = 0;
                ds[j] = 0;
            } else {
                const ee = @exp(arg);
                s[j] = self.amp[j] * ee / ((1.0 + ee) * (1.0 + ee));
                ds[j] = (1.0 - ee) / (b[j] * (1.0 + ee));
            }
        }
        const sum = s[0] + s[1] + s[2];
        if (h_km >= 100.0) return 1e11 * sum;
        const bf = 1.0 - 10.0 * (s[0] * ds[0] + s[1] * ds[1] + s[2] * ds[2]) / sum;
        const z = (h_km - 100.0) / 10.0;
        return 1e11 * sum * @exp(1.0 - bf * z - @exp(-z));
    }

    fn topside(self: *const Layers, h_km: f64) f64 {
        const g = 0.125;
        const rfac = 100.0;
        const dh = h_km - self.hm[layer_f2];
        const z = dh / (self.top[layer_f2] * (1.0 + rfac * g * dh / (rfac * self.top[layer_f2] + g * dh)));
        const ee = clipExp(z);
        const ep = if (ee > 1e11) 4.0 / ee else 4.0 * ee / ((1.0 + ee) * (1.0 + ee));
        return self.peak_density * ep;
    }
};
