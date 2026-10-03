const std = @import("std");
const constants = @import("../constants.zig");
const manifest = @import("manifest.zig");
const Lla = @import("../coord.zig").Lla;

const blob = manifest.gpt3_5.bytes;

const rows = 36;
const columns = 72;
const grid_deg = 5;
const half_grid_deg = 2.5;

pub const days_per_year = 365.25;
const virtual_temp_factor = 0.6077;
const vapour_mass_ratio = 0.622;
const one_minus_vapour_mass_ratio = 0.378;
const pa_per_hpa = 100;

const Field = enum { pressure, temperature, humidity, lapse, undulation, orography, ah, aw, lambda, mean_temp };

const Column = struct { terms: usize, scale: f64, divisor: f64 };

const table = std.EnumArray(Field, Column).init(.{
    .pressure = .{ .terms = 5, .scale = 1, .divisor = 1 },
    .temperature = .{ .terms = 5, .scale = 10, .divisor = 1 },
    .humidity = .{ .terms = 5, .scale = 100, .divisor = 1000 },
    .lapse = .{ .terms = 5, .scale = 10, .divisor = 1000 },
    .undulation = .{ .terms = 1, .scale = 100, .divisor = 1 },
    .orography = .{ .terms = 1, .scale = 100, .divisor = 1 },
    .ah = .{ .terms = 5, .scale = 100000, .divisor = 1000 },
    .aw = .{ .terms = 5, .scale = 100000, .divisor = 1000 },
    .lambda = .{ .terms = 5, .scale = 10000, .divisor = 1 },
    .mean_temp = .{ .terms = 5, .scale = 10, .divisor = 1 },
});

const values = blk: {
    var n = 0;
    for (table.values) |c| n += c.terms;
    break :blk n;
};

comptime {
    std.debug.assert(blob.len == rows * columns * values * 4);
}

pub const gravity_mps2 = 9.80665;
pub const dry_air_molar_mass_kg_per_mol = 28.965e-3;
pub const gas_constant_j_per_mol_k = 8.3143;
const barometric_k_per_m = gravity_mps2 * dry_air_molar_mass_kg_per_mol / gas_constant_j_per_mol_k;
const tropopause_k = 216.65;

pub const Coefficients = struct { ah: f64, aw: f64 };

pub const Meteorology = struct {
    pressure: f64,
    vapour: f64,
    lambda: f64,
    mean_temp: f64,
    ah: f64,
    aw: f64,
};

pub fn meteorology(doy: f64, rx: Lla) Meteorology {
    const pi = constants.pi;
    const annual = doy / days_per_year * 2 * pi;
    const semiannual = doy / days_per_year * 4 * pi;
    const terms: Terms = .{ @cos(annual), @sin(annual), @cos(semiannual), @sin(semiannual) };
    const plon = (if (rx.lon_rad < 0) rx.lon_rad + 2 * pi else rx.lon_rad) * 180 / pi;
    const ppod = (-rx.lat_rad + pi / 2) * 180 / pi;
    var ipod: i64 = @intFromFloat(@floor((ppod + grid_deg) / grid_deg));
    var ilon: i64 = @intFromFloat(@floor((plon + grid_deg) / grid_deg));
    const diffpod = (ppod - (@as(f64, @floatFromInt(ipod)) * grid_deg - half_grid_deg)) / grid_deg;
    const difflon = (plon - (@as(f64, @floatFromInt(ilon)) * grid_deg - half_grid_deg)) / grid_deg;
    if (ipod == 37) ipod = 36;
    ilon = wrap(ilon);
    const first = meteorologyAt(ipod, ilon, terms, rx.height_m);
    if (!(ppod > half_grid_deg and ppod < 180 - half_grid_deg)) return first;
    const ipod1 = ipod + (if (diffpod < 0) @as(i64, -1) else 1);
    const ilon1 = wrap(ilon + (if (difflon < 0) @as(i64, -1) else 1));
    const latitude_neighbour = meteorologyAt(ipod1, ilon, terms, rx.height_m);
    const longitude_neighbour = meteorologyAt(ipod, ilon1, terms, rx.height_m);
    const diagonal = meteorologyAt(ipod1, ilon1, terms, rx.height_m);
    const dnpod1 = @abs(diffpod);
    const dnlon1 = @abs(difflon);
    return mix(
        mix(first, latitude_neighbour, 1 - dnpod1, dnpod1),
        mix(longitude_neighbour, diagonal, 1 - dnpod1, dnpod1),
        1 - dnlon1,
        dnlon1,
    );
}

const Terms = [4]f64;

fn wrap(ilon: i64) i64 {
    return if (ilon == 73) 1 else if (ilon == 0) 72 else ilon;
}

fn mix(a: Meteorology, b: Meteorology, wa: f64, wb: f64) Meteorology {
    var out: Meteorology = undefined;
    inline for (std.meta.fields(Meteorology)) |f| {
        @field(out, f.name) = wa * @field(a, f.name) + wb * @field(b, f.name);
    }
    return out;
}

fn meteorologyAt(ipod: i64, ilon: i64, terms: Terms, height_m: f64) Meteorology {
    const index: usize = @intCast((ipod - 1) * columns + ilon - 1);
    const point = blob[index * values * 4 ..][0 .. values * 4];
    const pressure_pa = series(.pressure, point, terms);
    const humidity = series(.humidity, point, terms);
    const redh = height_m - series(.undulation, point, terms) - series(.orography, point, terms);
    const virtual_k = series(.temperature, point, terms) * (1 + virtual_temp_factor * humidity);
    const lambda = series(.lambda, point, terms);
    const reduced = reduce(pressure_pa, virtual_k, series(.lapse, point, terms), redh);
    const vapour_pa = humidity * pressure_pa / (vapour_mass_ratio + one_minus_vapour_mass_ratio * humidity);
    return .{
        .pressure = reduced / pa_per_hpa,
        .vapour = vapour_pa / pa_per_hpa * std.math.pow(f64, reduced / pressure_pa, lambda + 1),
        .lambda = lambda,
        .mean_temp = series(.mean_temp, point, terms),
        .ah = series(.ah, point, terms),
        .aw = series(.aw, point, terms),
    };
}

fn reduce(p0: f64, tv: f64, lapse: f64, redh: f64) f64 {
    if (lapse >= 0) return p0 * @exp(-barometric_k_per_m / tv * redh);
    const layer = @max((tropopause_k - tv) / lapse, 0);
    const within = @min(redh, layer);
    const p = p0 * std.math.pow(f64, 1 + lapse * within / tv, -barometric_k_per_m / lapse);
    if (redh <= layer) return p;
    return p * @exp(-barometric_k_per_m / tropopause_k * (redh - layer));
}

fn series(comptime field: Field, point: *const [values * 4]u8, terms: Terms) f64 {
    const column = comptime table.get(field);
    const first = comptime blk: {
        var n = 0;
        for (table.values[0..@intFromEnum(field)]) |c| n += c.terms;
        break :blk n * 4;
    };
    var sum = decode(point[first..][0..4], column);
    inline for (0..column.terms - 1) |k| {
        sum += decode(point[first + (k + 1) * 4 ..][0..4], column) * terms[k];
    }
    return sum;
}

fn decode(bytes: *const [4]u8, column: Column) f64 {
    const scaled = std.mem.readInt(i32, bytes, .little);
    return @as(f64, @floatFromInt(scaled)) / column.scale / column.divisor;
}
