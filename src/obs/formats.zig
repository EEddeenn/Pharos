const std = @import("std");
const Io = std.Io;
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const model = @import("shared").bundle.scenario;
const types = core.types;
const time = core.time;
const coord = core.coord;
const observe = @import("observe.zig");

const trajectory = @import("shared").trajectory;
const kml = trajectory.kml;
const positions = trajectory.positions;

const PositionFormat = model.PositionFormat;
const version = @import("shared").version;

const project = "PHAROS";

pub const Layout = struct {
    const Column = struct { signal: types.Signal, codes: usize };
    const System = struct {
        columns: [gnss.spec.max_per_system]Column = undefined,
        count: usize = 0,
        codes: usize = 0,

        fn slice(self: *const System) []const Column {
            return self.columns[0..self.count];
        }
    };

    systems: std.EnumArray(types.System, System),

    pub fn init(signals: std.EnumSet(types.Signal)) Layout {
        var self: Layout = .{ .systems = .initFill(.{}) };
        for (std.meta.tags(types.Signal)) |signal| {
            if (!signals.contains(signal)) continue;
            const system = self.systems.getPtr(signal.system());
            const codes = gnss.spec.get(signal).observables.len;
            system.columns[system.count] = .{ .signal = signal, .codes = codes };
            system.count += 1;
            system.codes += codes;
        }
        return self;
    }

    pub fn epochBytes(self: *const Layout, tracked: usize) usize {
        var codes: usize = 0;
        for (self.systems.values) |system| codes = @max(codes, system.codes);
        return 64 + tracked * (4 + chars_per_observable * codes);
    }

    fn columns(self: *const Layout, system: types.System) []const Column {
        return self.systems.getPtrConst(system).slice();
    }

    fn listed(self: *const Layout, system: types.System) bool {
        return self.systems.getPtrConst(system).count != 0;
    }
};

pub const Header = struct {
    approx_pos: coord.Ecef,
    layout: Layout,
    interval_ms: u32,
    glonass_freq: [24]?types.FreqId,
    created: core.civil.Utc,
    first: time.GpsTime,
    last: time.GpsTime,
    moving: bool,
    leap: core.civil.Leap,
};

const kml_document = "Pharos receiver trajectory";
const kml_placemark = "Receiver";

pub fn positionHeader(w: *Io.Writer, format: PositionFormat) Io.Writer.Error!void {
    switch (format) {
        .ecef => try w.writeAll(positions.header(.ecef)),
        .lla => try w.writeAll(positions.header(.lla)),
        .kml => try kml.head(w, kml_document, kml_placemark),
    }
}

pub fn positionEpoch(w: *Io.Writer, format: PositionFormat, t: time.GpsTime, pos: coord.Ecef, lla: coord.Lla) Io.Writer.Error!void {
    switch (format) {
        .ecef => try positions.ecefLine(w, t, pos),
        .lla => try positions.llaLine(w, t, lla),
        .kml => try kml.coordinate(w, lla),
    }
}

pub fn positionFooter(w: *Io.Writer, format: PositionFormat) Io.Writer.Error!bool {
    if (format != .kml) return false;
    try kml.foot(w);
    return true;
}

const chars_per_observable = 64;

const f14_min = -999_999_999.9995;
const f14_max = 9_999_999_999.9995;

pub fn rinexEpoch(w: *Io.Writer, e: observe.Epoch, layout: *const Layout) Io.Writer.Error!void {
    try epochFields(w, e.t);
    try w.print("  0{d:>3}                     \n", .{e.sats.len});
    for (e.sats) |s| {
        try w.print("{c}{d:0>2}", .{ s.sat.system.rinexLetter(), s.sat.prn() });
        var blank: usize = 0;
        var next: usize = 0;
        for (layout.columns(s.sat.system)) |column| {
            const signal = column.signal;
            const codes = column.codes;
            if (next == s.signals.len or s.signals[next].signal != signal) {
                blank += chars_per_observable * codes;
                continue;
            }
            const o = s.signals[next];
            next += 1;
            try w.splatByteAll(' ', blank);
            blank = 0;
            const cn0_dbhz = centiDb(o.cn0_dbhz);
            for (o.pseudorange_m[0..codes]) |pseudorange_m| {
                try observation(w, pseudorange_m, false);
                try phase(w, o.phase_cycles);
                try observation(w, o.doppler_hz, false);
                try observation(w, cn0_dbhz, false);
            }
        }
        try w.writeAll("\n");
    }
}

fn epochFields(w: *Io.Writer, t: time.GpsTime) Io.Writer.Error!void {
    const c = epochCalendar(t);
    try w.print("> {d:>4} {d:0>2} {d:0>2} {d:0>2} {d:0>2} {d:>10.7}", .{ @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second });
}

fn epochCalendar(t: time.GpsTime) core.civil.Utc {
    const ticks_per_ms = 10_000;
    const ticks: i64 = @intFromFloat(@round(t.sub_ms * ticks_per_ms));
    return core.civil.calendar(t.ms + @divFloor(ticks, ticks_per_ms), @as(f64, @floatFromInt(@mod(ticks, ticks_per_ms))) / ticks_per_ms);
}

fn observation(w: *Io.Writer, value: f64, lli: bool) Io.Writer.Error!void {
    if (value > f14_min and value < f14_max) try w.print("{d:>14.3}", .{value}) else try w.splatByteAll(' ', 14);
    try w.writeAll(if (lli) "1 " else "  ");
}

const phase_wrap_cycles = 1e9;
const centi_db_per_db = 100.0;

fn phase(w: *Io.Writer, cycles: f64) Io.Writer.Error!void {
    if (cycles >= f14_max) return observation(w, cycles - phase_wrap_cycles * (@floor((cycles - f14_max) / phase_wrap_cycles) + 1), true);
    if (cycles <= f14_min) return observation(w, cycles + phase_wrap_cycles * (@floor((f14_min - cycles) / phase_wrap_cycles) + 1), true);
    return observation(w, cycles, false);
}

fn centiDb(v: f64) f64 {
    return @round(v * centi_db_per_db) / centi_db_per_db;
}

pub fn rinexHeader(w: *Io.Writer, h: Header) Io.Writer.Error!void {
    const c = h.created;
    const pgm = std.fmt.comptimePrint("pharos-obs {d}.{d}.{d}", .{ version.major, version.minor, version.patch });
    comptime std.debug.assert(pgm.len <= 20);
    try record(w, "     3.04           OBSERVATION DATA    {s}", .{fileSystem(&h.layout)}, "RINEX VERSION / TYPE");
    try record(w, "{s:<20}{s:<20}{d:0>4}{d:0>2}{d:0>2} {d:0>2}{d:0>2}{d:0>2} UTC", .{ pgm, project, @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, @as(u8, @intFromFloat(c.second)) }, "PGM / RUN BY / DATE");
    try record(w, "{s}", .{project}, "MARKER NAME");
    try record(w, "{s:<20}{s}", .{ project, project }, "OBSERVER / AGENCY");
    try record(w, "{s:<20}{s:<20}{d}.{d}.{d}", .{ "", project, version.major, version.minor, version.patch }, "REC # / TYPE / VERS");
    try record(w, "{s:<20}{s}", .{ "", project }, "ANT # / TYPE");
    try record(w, "{d:>14.4}{d:>14.4}{d:>14.4}", .{ h.approx_pos.x, h.approx_pos.y, h.approx_pos.z }, "APPROX POSITION XYZ");
    try record(w, "{d:>14.4}{d:>14.4}{d:>14.4}", .{ @as(f64, 0), @as(f64, 0), @as(f64, 0) }, "ANTENNA: DELTA H/E/N");
    const systems = [_]types.System{ .gps, .glo, .bds, .gal };
    for (systems) |system| try obsTypes(w, system, &h.layout);
    try record(w, "DBHZ", .{}, "SIGNAL STRENGTH UNIT");
    for (systems) |system| try phaseShifts(w, system, &h.layout);
    try record(w, "{d:>10.3}", .{@as(f64, @floatFromInt(h.interval_ms)) / 1000.0}, "INTERVAL");
    try epochRecord(w, h.first, "TIME OF FIRST OBS");
    try epochRecord(w, h.last, "TIME OF LAST OBS");
    if (h.layout.listed(.glo)) {
        try slotFreq(w, h.glonass_freq);
        try record(w, " C1C    0.000 C1P    0.000 C2C    0.000 C2P    0.000", .{}, "GLONASS COD/PHS/BIS");
    }
    try leapSeconds(w, h.leap, h.first, h.last);
    try record(w, "", .{}, "END OF HEADER");
    if (h.moving) {
        try epochFields(w, h.first);
        try w.writeAll("  2  0\n");
    }
}

fn leapSeconds(w: *Io.Writer, leap: core.civil.Leap, first: time.GpsTime, last: time.GpsTime) Io.Writer.Error!void {
    var buf: [2][8]u8 = undefined;
    const count = counted(&buf[0], first.leap(leap).count);
    if (leap.nextChange(first.ms + 1)) |change| if (change.at_ms - time.ms_per_second <= last.ms) {
        const day_start: time.GpsTime = .{ .ms = change.at_ms - time.ms_per_day };
        const day_ms: u32 = @intCast(time.ms_per_day);
        return record(w, "{s:>6}{s:>6}{d:>6}{d:>6}GPS", .{
            count,
            counted(&buf[1], change.count),
            @as(u32, @intCast(day_start.week())),
            day_start.msOfWeek() / day_ms + 1,
        }, "LEAP SECONDS");
    };
    return record(w, "{s:>6}{s:18}GPS", .{ count, "" }, "LEAP SECONDS");
}

fn counted(buf: []u8, count: i8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{count}) catch unreachable;
}

fn epochRecord(w: *Io.Writer, t: time.GpsTime, label: []const u8) Io.Writer.Error!void {
    const f = epochCalendar(t);
    try record(w, "{d:>6}{d:>6}{d:>6}{d:>6}{d:>6}{d:>13.7}{s:5}GPS", .{ @as(u32, @intCast(f.year)), f.month, f.day, f.hour, f.minute, f.second, "" }, label);
}

fn fileSystem(layout: *const Layout) []const u8 {
    var only: ?types.System = null;
    for (std.meta.tags(types.System)) |system| {
        if (!layout.listed(system)) continue;
        if (only != null) return "M (MIXED)";
        only = system;
    }
    return switch (only orelse return "M (MIXED)") {
        .gps => "G (GPS)",
        .glo => "R (GLONASS)",
        .gal => "E (GALILEO)",
        .bds => "C (BDS)",
    };
}

fn record(w: *Io.Writer, comptime fmt: []const u8, args: anytype, label: []const u8) Io.Writer.Error!void {
    try w.print(fmt, args);
    try w.splatByteAll(' ', 60 -| std.fmt.count(fmt, args));
    try w.print("{s:<20}\n", .{label});
}

fn obsTypes(w: *Io.Writer, system: types.System, layout: *const Layout) Io.Writer.Error!void {
    var codes: [4 * gnss.spec.max_observables * std.meta.tags(types.Signal).len][3]u8 = undefined;
    var n: usize = 0;
    for (layout.columns(system)) |column| {
        for (gnss.spec.get(column.signal).observables) |o| {
            for ("CLDS") |kind| {
                codes[n] = .{ kind, o.code[0], o.code[1] };
                n += 1;
            }
        }
    }
    if (n == 0) return;
    var i: usize = 0;
    while (i < n) : (i += 13) {
        var line: [60]u8 = @splat(' ');
        if (i == 0) {
            line[0] = system.rinexLetter();
            _ = std.fmt.bufPrint(line[1..6], "{d:>5}", .{n}) catch unreachable;
        }
        for (codes[i..@min(n, i + 13)], 0..) |code, k| @memcpy(line[7 + 4 * k ..][0..3], &code);
        try record(w, "{s}", .{&line}, "SYS / # / OBS TYPES");
    }
}

fn phaseShifts(w: *Io.Writer, system: types.System, layout: *const Layout) Io.Writer.Error!void {
    for (layout.columns(system)) |column| {
        for (gnss.spec.get(column.signal).observables) |o| {
            if (o.phase_reference) {
                try record(w, "{c} L{c}{c}", .{ system.rinexLetter(), o.code[0], o.code[1] }, "SYS / PHASE SHIFT");
            } else {
                try record(w, "{c} L{c}{c} {d:>8.5}", .{ system.rinexLetter(), o.code[0], o.code[1], @as(f64, 0) }, "SYS / PHASE SHIFT");
            }
        }
    }
}

fn slotFreq(w: *Io.Writer, freq: [24]?types.FreqId) Io.Writer.Error!void {
    var slots: [24]struct { number: usize, freq: types.FreqId } = undefined;
    var n: usize = 0;
    for (freq, 1..) |f, slot| if (f) |k| {
        slots[n] = .{ .number = slot, .freq = k };
        n += 1;
    };
    var i: usize = 0;
    while (true) : (i += 8) {
        var line: [60]u8 = @splat(' ');
        if (i == 0) _ = std.fmt.bufPrint(line[0..3], "{d:>3}", .{n}) catch unreachable;
        for (slots[i..@min(n, i + 8)], 0..) |slot, k| {
            const f = slot.freq.int();
            if (f < 0) {
                _ = std.fmt.bufPrint(line[3 + 7 * k ..][0..7], " R{d:0>2} -{d}", .{ slot.number, @as(u8, @intCast(-f)) }) catch unreachable;
            } else {
                _ = std.fmt.bufPrint(line[3 + 7 * k ..][0..7], " R{d:0>2} {d:>2}", .{ slot.number, @as(u8, @intCast(f)) }) catch unreachable;
            }
        }
        try record(w, "{s}", .{&line}, "GLONASS SLOT / FRQ #");
        if (i + 8 >= n) break;
    }
}
