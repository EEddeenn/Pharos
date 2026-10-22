const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const records = @import("domain/navigation/records");
const signal_payload = @import("domain/signals/payload");
const signal_catalog = @import("domain/signals/catalog");
const flight_plan = @import("simulation/model/flight_plan");
const configuration = @import("simulation/model/config");
const selection = @import("simulation/model/signals");
const provider = @import("simulation/tracking/track");
const GpsTime = @import("domain/time/gps").GpsTime;
const ClockReferences = @import("domain/navigation/clock_reference").ClockReferences;
const Product = @import("domain/navigation/precise/product").Product;
const Unfit = @import("domain/messages/carriage").Unfit;
const Diagnostics = @import("base/diagnostics").Diagnostics;
const Plan = flight_plan.FlightPlan;
const Timeline = flight_plan.Timeline;

/// What a family does on a leg whose reference it cannot carry: sends its unavailable form, or leaves its signals off
/// the air.
const Consequence = struct {
    off_air: std.EnumSet(gnss_types.Signal) = .empty,

    pub fn format(self: Consequence, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.off_air.count() == 0) return w.writeAll("sent there as unavailable");
        try w.writeAll("off the air on ");
        var it = self.off_air.iterator();
        var first = true;
        while (it.next()) |signal| : (first = false) try w.print("{s}{s}", .{ if (first) "" else ", ", signal.name() });
    }
};

const Assumed = struct {
    timelines: []const Timeline,
    signals: []const std.EnumSet(gnss_types.Signal),

    pub fn format(self: Assumed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        for (self.timelines, self.signals) |timeline, signals| {
            var it = signals.iterator();
            while (it.next()) |signal| {
                try w.print("{s}{f}", .{ if (first) "" else ", ", gnss_types.ChannelKey{ .sat = timeline.sat, .signal = signal } });
                first = false;
            }
        }
    }
};

const Satellites = struct {
    list: []const gnss_types.SatId,

    pub fn format(self: Satellites, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.list, 0..) |sat, i| try w.print("{s}{f}", .{ if (i == 0) "" else " ", sat });
    }
};

/// Warns of each leg whose reference a listed signal's family cannot carry: CNAV and CNAV-2 send their unavailable
/// form; the other navigation families leave their signals off the air.
pub fn warnUnfit(s: *const configuration.Config, ephemerides: records.Ephemerides, p: *const Plan, diags: *Diagnostics) std.mem.Allocator.Error!void {
    const payload = signal_payload.at(s.start);
    for (p.timelines) |timeline| {
        for (std.enums.values(gnss_types.NavFamily)) |family| {
            var signals: std.EnumSet(gnss_types.Signal) = .empty;
            var listed = s.signals.iterator();
            while (listed.next()) |signal| if (payload.familyOf(timeline.sat, signal) == family) signals.insert(signal);
            const consequence: Consequence = switch (family) {
                .cnav, .cnav2 => if (s.samples != null) .{} else continue,
                .lnav, .inav, .fnav, .d1d2, .bcnav1, .bcnav2, .bcnav3, .gnav => .{ .off_air = signals },
                else => continue,
            };
            if (signals.count() == 0) continue;
            for (timeline.legs) |*leg| {
                const binding = if (leg.binding) |*binding| binding else continue;
                const unfit = (binding.content(family) orelse continue).unfit() orelse continue;
                switch (binding.reference) {
                    .kepler => |k| {
                        const record = &ephemerides.kepler[k];
                        try warnRecord(record.sat, record.source().rinexName(record.sat), record.toc, family, unfit, consequence, diags);
                    },
                    .glonass => |k| {
                        const record = &ephemerides.glonass[k];
                        try warnRecord(record.sat, "FDMA", record.tb, family, unfit, consequence, diags);
                    },
                }
            }
        }
    }
}

pub fn warnAssumed(s: *const configuration.Config, p: *const Plan, product: ?*const Product, clock_refs: ClockReferences, diags: *Diagnostics) std.mem.Allocator.Error!void {
    var assumed: [flight_plan.satellite_count]std.EnumSet(gnss_types.Signal) = @splat(.empty);
    var any = false;
    for (p.timelines, &assumed) |timeline, *signals| {
        if (s.mask_out.get(timeline.sat.system).contains(timeline.sat)) continue;
        for (timeline.legs) |*leg| {
            if (leg.from_ms >= s.duration_ms) break;
            const binding = if (leg.binding) |*binding| binding else continue;
            if (product) |precise| if (!provider.productServes(precise, timeline.sat, p.start.addMs(@intCast(leg.from_ms)), p.leap)) continue;
            var flies = false;
            var listed = s.signals.iterator();
            while (listed.next()) |signal| {
                if (signal.system() != timeline.sat.system) continue;
                const row = binding.air[signal_catalog.slot(signal)];
                if (row.status != .on_air) continue;
                flies = true;
                if (row.origin == .assumed) signals.insert(signal);
            }
            const clock_ref = clock_refs.get(timeline.sat.system);
            if (product == null or !flies or clock_ref == .p1p2) continue;
            // The precise clock shift moves every signal of the satellite: its pair's terms count, listed or not. P1P2's
            // shift is 0 and reads none.
            for (clock_ref.pair()) |signal| {
                if (binding.air[signal_catalog.slot(signal)].origin == .assumed) signals.insert(signal);
            }
        }
        any = any or signals.count() != 0;
    }
    if (any) try diags.warn(.group_delay_assumed, "ephemeris", "some group-delay terms for {f} are unavailable; assumed values are used in the signals and in a precise product's clock shift", .{Assumed{ .timelines = p.timelines, .signals = &assumed }});
}

pub fn warnUnserved(precise: ?*const Product, p: *const Plan, diags: *Diagnostics) std.mem.Allocator.Error!void {
    const product = precise orelse return;
    var unserved: [flight_plan.satellite_count]gnss_types.SatId = undefined;
    var count: usize = 0;
    for (p.timelines) |timeline| {
        if (p.recordAt(timeline.sat, p.start) == null or provider.productServes(product, timeline.sat, p.start, p.leap)) continue;
        unserved[count] = timeline.sat;
        count += 1;
    }
    if (count > 0) try diags.warn(.no_record, "ephemeris", "the precise product does not serve {f} at the run start, {f}: they transmit nothing until it does", .{ Satellites{ .list = unserved[0..count] }, p.start.printed(null) });
}

pub fn reportCoverage(plan: *const Plan, s: *const configuration.Config, diags: *Diagnostics) std.mem.Allocator.Error!void {
    for (gnss_types.System.all) |system| {
        var sats = system.satellites();
        const listed = while (sats.next()) |sat| {
            if (selection.transmits(s.signals, s.mask_out, s.start, sat)) break true;
        } else false;
        if (!listed) continue;
        const covered = plan.coveredMs(s, system);
        if (covered >= s.duration_ms) continue;
        const t = s.start.addMs(@intCast(covered));
        const at = t.printed(null);
        const name = system.displayName();
        if (covered == 0) {
            try diags.warn(.no_record, "ephemeris", "no {s} satellite flies a listed signal at the run start, {f}: its signals carry nothing until one does", .{ name, at });
        } else {
            // Whole milliseconds, so every digit, as an integer is written.
            try diags.warn(.no_record, "ephemeris", "no {s} satellite flies a listed signal from {f}, {d} s into the run", .{ name, at, @as(f64, @floatFromInt(covered)) / 1000 });
        }
    }
}

fn warnRecord(sat: gnss_types.SatId, source: []const u8, epoch: GpsTime, family: gnss_types.NavFamily, unfit: Unfit, consequence: Consequence, diags: *Diagnostics) std.mem.Allocator.Error!void {
    const head = .{ sat, source, epoch.printed(null) };
    const tail = if (family == .gnav) family.name() else sourceOf(family).rinexName(sat);
    switch (unfit) {
        .field => |name| try diags.warn(.unfit_record, "ephemeris", "{f} {s} record of {f}: {s} outside its {s} field, {f} while it is selected", head ++ .{ name, tail, consequence }),
        .health => |signals| try diags.warn(.unfit_record, "ephemeris", "{f} {s} record of {f}: it declares no {s} signal health for {s}, {f} while it is selected", head ++ .{ signals, tail, consequence }),
        .fit => try diags.warn(.unfit_record, "ephemeris", "{f} {s} record of {f}: no {s} orbit fits it over its leg, {f} while it is selected", head ++ .{ tail, consequence }),
        .record => try diags.warn(.unfit_record, "ephemeris", "{f} {s} record of {f}: {s} carries only its own records, {f} while it is selected", head ++ .{ tail, consequence }),
    }
}

fn sourceOf(family: gnss_types.NavFamily) records.NavSource {
    return switch (family) {
        inline .lnav, .cnav, .cnav2, .inav, .fnav, .d1d2, .bcnav1, .bcnav2, .bcnav3 => |f| @field(records.NavSource, @tagName(f)),
        .cnav_has, .ppp_b2b, .gnav => unreachable,
    };
}
