const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const auxiliary = @import("domain/navigation/system_data");
const civil = @import("domain/time/civil");
const field = @import("base/binary/field");
const diagnostics = @import("base/diagnostics");
const lnav = @import("domain/messages/gps/lnav/set");
const gps_time = @import("domain/messages/gps/fields/time");
const klobuchar = @import("domain/messages/fields/klobuchar");
const nequick = @import("domain/messages/galileo/fields/ionosphere");
const bdgim = @import("domain/messages/bds/fields/ionosphere");
const galileo_time = @import("domain/messages/galileo/fields/time");
const bds_time = @import("domain/messages/bds/fields/time");
const d1d2 = @import("domain/messages/bds/d1d2/pages");
const gnav = @import("domain/messages/glonass/gnav/system");
const model = @import("simulation/model/systems");
const selection = @import("simulation/model/signals");
const flight = @import("simulation/model/flight_plan");
const time_grid = @import("products/pack/planning/time_grid");
const signal_payload = @import("domain/signals/payload");
const GpsTime = @import("domain/time/gps").GpsTime;
const Config = @import("simulation/model/config").Config;
const Broadcast = @import("simulation/model/ionosphere").Broadcast;

pub const Planned = struct { stored: model.Stored, prepared: model.Systems };

const Warnings = struct {
    diags: *diagnostics.Diagnostics,
    zero: std.EnumSet(gnss_types.System) = .empty,
    donors: std.EnumSet(gnss_types.System) = .empty,

    fn assumed(self: *Warnings, system: gnss_types.System) std.mem.Allocator.Error!void {
        if (self.zero.contains(system)) return;
        self.zero.insert(system);
        try self.diags.warn(.system_data_assumed, "ephemeris", "{s} has no Earth-orientation record available; UT1-UTC, polar motion and their rates are set to zero", .{system.name()});
    }

    fn derived(self: *Warnings, donor: gnss_types.System) std.mem.Allocator.Error!void {
        if (self.donors.contains(donor)) return;
        self.donors.insert(donor);
        try self.diags.warn(.system_data_derived, "ephemeris", "BDS-UTC is derived from {s}-UTC and the selected system-to-GPS time offsets", .{donor.name()});
    }
};

pub fn prepare(arena: std.mem.Allocator, config: *const Config, records: auxiliary.SystemRecords, scales: std.EnumArray(gnss_types.System, model.ScaleChoice), spans_ms: std.EnumArray(gnss_types.System, u64), day: ?gnav.Day, leap: civil.Leap, diags: *diagnostics.Diagnostics) diagnostics.InputError!Planned {
    var stored: model.Stored = .{ .records = records, .scales = scales };
    var ready: model.Systems = .{ .start = config.start };
    const broadcast = config.ionosphere.ready.broadcast;
    const payload = signal_payload.at(config.start);
    const families = payload.families(config.signals);
    var warnings: Warnings = .{ .diags = diags };
    inline for (gnss_types.System.all) |system| {
        if (selection.systems(config.signals).contains(system)) {
            const Choice = switch (system) {
                .gps => model.GpsChoice,
                .gal => model.GalileoChoice,
                .bds => model.BdsChoice,
                .glo => model.GlonassChoice,
            };
            var choices: std.ArrayList(model.Entry(Choice)) = .empty;
            var prepared: std.ArrayList(model.Entry(model.Value(system))) = .empty;
            const times = try time_grid.samples(arena, config.start, spans_ms.get(system), system, leap);
            for (times) |at| {
                const selected = switch (system) {
                    .gps => try gps(&records, at, leap, &broadcast, families, &warnings),
                    .gal => galileo(&records, at, leap, &broadcast),
                    .bds => try bds(&records, at, leap, &broadcast, families, &warnings),
                    .glo => try glonass(&records, day.?, at, leap, &warnings),
                };
                try append(Choice, model.Value(system), arena, &choices, &prepared, @intCast(at.ms - config.start.ms), selected.choice, selected.value);
            }
            const name = switch (system) {
                .gps => "gps",
                .gal => "galileo",
                .bds => "bds",
                .glo => "glonass",
            };
            @field(stored, name) = choices.items;
            @field(ready, name) = prepared.items;
        }
    }
    if (families.contains(.fnav) and ready.at(.gal, config.start).?.utc == null) {
        try diags.err(.missing_field, "ephemeris", "an E5a signal is listed but the navigation data transmit no GST-UTC usable at the run start: F/NAV page 4 would be a dummy page for the whole run, carrying neither Cic and Cis nor the GGTO", .{});
        return error.InvalidInput;
    }
    return .{ .stored = stored, .prepared = ready };
}

pub fn startScales(records: *const auxiliary.SystemRecords, signals: std.EnumSet(gnss_types.Signal), at: GpsTime) std.EnumArray(gnss_types.System, model.ScaleChoice) {
    var selected: std.EnumArray(gnss_types.System, model.ScaleChoice) = .initFill(.zero);
    var enabled = selection.systems(signals).iterator();
    while (enabled.next()) |system| selected.set(system, scaleChoice(records, system, at));
    return selected;
}

/// Missing source data is fatal only for listed messages that carry an admitted ephemeris.
pub fn requireData(config: *const Config, plan: *const flight.FlightPlan, systems: *const model.Systems, stored: *const model.Stored, diags: *diagnostics.Diagnostics) diagnostics.InputError!void {
    const payload = signal_payload.at(config.start);
    const families = payload.families(config.signals);
    const end = config.start.addMs(@intCast(config.duration_ms));
    inline for ([_]gnss_types.NavFamily{ .d1d2, .bcnav3, .gnav }) |family| {
        if (families.contains(family)) {
            var at = config.start;
            while (at.lessThan(end)) : (at = flight.nextLegBoundary(family.system(), at, plan.leap)) {
                var sats = family.system().satellites();
                while (sats.next()) |sat| {
                    var listed = false;
                    var signals = config.signals.iterator();
                    while (signals.next()) |signal| if (payload.familyOf(sat, signal) == family) {
                        listed = true;
                        break;
                    };
                    if (!listed) continue;
                    const content = plan.contentAt(sat, family, at) orelse continue;
                    if (content.unfit() != null) continue;
                    const reason: ?[]const u8 = switch (family) {
                        .d1d2 => if (systems.at(.bds, at).?.d1d2 == null) "the UTC parameters are missing or cannot be encoded" else null,
                        .bcnav3 => if (systems.at(.bds, at).?.bcnav.eop == null) "the Earth-orientation parameters are missing or cannot be encoded" else if (systems.at(.bds, at).?.bcnav.utc == null) "the UTC parameters are missing or cannot be encoded" else null,
                        .gnav => blk: {
                            if (systems.at(.glo, at).?.* != null) break :blk null;
                            var selected = stored.glonass[0].value;
                            const elapsed: u64 = @intCast(at.ms - config.start.ms);
                            for (stored.glonass) |entry| {
                                if (entry.from_ms > elapsed) break;
                                selected = entry.value;
                            }
                            break :blk if (selected.utc == null or selected.gps == null) "the UTC/GPS time offsets are missing or cannot be encoded" else "the Earth-orientation parameters are missing or cannot be encoded";
                        },
                        else => unreachable,
                    };
                    if (reason) |why| {
                        try diags.err(.missing_field, "ephemeris", "{s} at {d} s into the run: {s}", .{ family.name(), @as(f64, @floatFromInt(at.ms - config.start.ms)) / 1000, why });
                        return error.InvalidInput;
                    }
                }
            }
        }
    }
}

fn append(comptime Choice: type, comptime Value: type, arena: std.mem.Allocator, choices: *std.ArrayList(model.Entry(Choice)), prepared: *std.ArrayList(model.Entry(Value)), from_ms: u64, choice: Choice, value: Value) std.mem.Allocator.Error!void {
    if (choices.items.len != 0 and std.meta.eql(choices.items[choices.items.len - 1].value, choice) and std.meta.eql(prepared.items[prepared.items.len - 1].value, value)) return;
    try choices.append(arena, .{ .from_ms = from_ms, .value = choice });
    try prepared.append(arena, .{ .from_ms = from_ms, .value = value });
}

fn Chosen(comptime Choice: type, comptime Value: type) type {
    return struct { choice: Choice, value: Value };
}

fn gps(records: *const auxiliary.SystemRecords, at: GpsTime, leap: civil.Leap, broadcast: *const Broadcast, families: std.EnumSet(gnss_types.NavFamily), warnings: *Warnings) std.mem.Allocator.Error!Chosen(model.GpsChoice, model.Gps) {
    var out: Chosen(model.GpsChoice, model.Gps) = .{
        .choice = .{},
        .value = .{ .lnav = .{ .page18 = null }, .cnav = .{ .klobuchar = field.project(klobuchar.Coefficients, &klobuchar.coefficients, &klobuchar.Coefficients.of(broadcast.klobuchar)), .utc = null, .eop = null, .ggto = .{} } },
    };
    if (utcChoice(records, .gps, at)) |selected| {
        const utc = model.utcParameters(records, selected, at, .gps, leap);
        if (lnav.page18(utc, broadcast.klobuchar)) |page| {
            out.choice.lnav_utc = selected;
            out.value.lnav.page18 = page;
        }
        if (gps_time.utcBlock(utc)) |block| {
            out.choice.cnav_utc = selected;
            out.value.cnav.utc = block;
            const choice = eopChoice(records, .gps, at);
            const reference = GpsTime.fromWeekMs(utc.wn_t, @as(i64, utc.tot_s) * 1000, 0);
            if (gps_time.eopBlock(model.eopRecord(records, choice, .gps, reference), utc)) |eop| {
                out.choice.eop = choice;
                out.value.cnav.eop = eop;
                if (choice == .zero and (families.contains(.cnav) or families.contains(.cnav2))) try warnings.assumed(.gps);
            }
        }
    }
    for ([_]auxiliary.OffsetKind{ .gagp, .glgp }, 0..) |kind, i| {
        const index = offsetIndex(records, kind, .gps, at) orelse continue;
        const record = records.time_offsets[index];
        const block = gps_time.ggtoBlock(record, at) orelse continue;
        out.choice.ggto[i] = .{ .record = index, .anchor = block.anchor };
        out.value.cnav.ggto.list[out.value.cnav.ggto.len] = block.block;
        out.value.cnav.ggto.len += 1;
    }
    return out;
}

fn galileo(records: *const auxiliary.SystemRecords, at: GpsTime, leap: civil.Leap, broadcast: *const Broadcast) Chosen(model.GalileoChoice, model.Value(.gal)) {
    var out: Chosen(model.GalileoChoice, model.Value(.gal)) = .{ .choice = .{}, .value = .{ .iono = field.project(nequick.Coefficients, &nequick.rows, &(broadcast.nequick orelse .zero)), .utc = null, .ggto = galileo_time.unavailable_ggto } };
    if (utcChoice(records, .gal, at)) |selected| {
        if (galileo_time.utcBlock(model.utcParameters(records, selected, at, .gal, leap), at)) |block| {
            out.choice.utc = selected;
            out.value.utc = block;
        }
    }
    if (offsetIndex(records, .gagp, .gal, at)) |index| {
        if (galileo_time.ggtoBlock(records.time_offsets[index], at)) |block| {
            out.choice.ggto = index;
            out.value.ggto = block;
        }
    }
    return out;
}

fn bds(records: *const auxiliary.SystemRecords, at: GpsTime, leap: civil.Leap, broadcast: *const Broadcast, families: std.EnumSet(gnss_types.NavFamily), warnings: *Warnings) std.mem.Allocator.Error!Chosen(model.BdsChoice, model.Bds) {
    var out: Chosen(model.BdsChoice, model.Bds) = .{ .choice = .{}, .value = .{ .d1d2 = null, .bcnav = .{ .bdgim = field.project(bdgim.Coefficients, &bdgim.bdgim, &(broadcast.bdgim orelse @splat(0))), .utc = null, .eop = null, .offsets = @splat(null) } } };
    if (utcChoice(records, .bds, at)) |selected| {
        const utc = model.utcParameters(records, selected, at, .bds, leap);
        if (d1d2.utcFromParams(utc, at)) |page| if (field.fits(d1d2.UtcPage, &d1d2.utc, &page)) {
            out.choice.d1d2_utc = selected;
            out.value.d1d2 = .{ .utc = page, .klobuchar = field.project(klobuchar.Coefficients, &klobuchar.coefficients, &klobuchar.Coefficients.of(broadcast.bds_klobuchar)), .epoch = at };
        };
        if (bds_time.utcFromRecord(utc)) |block| {
            out.choice.bcnav_utc = selected;
            out.value.bcnav.utc = block;
        }
        const used = (families.contains(.d1d2) and out.choice.d1d2_utc != null) or
            ((families.contains(.bcnav1) or families.contains(.bcnav2) or families.contains(.bcnav3)) and out.choice.bcnav_utc != null);
        if (selected == .derived and used) try warnings.derived(selected.derived.donor);
    }
    const bdt = at.inScale(.bds);
    const reference = GpsTime.fromScaleWeekMs(.bds, bdt.period, bdt.ms / auxiliary.reference_step_ms * auxiliary.reference_step_ms, 0);
    const eop = eopChoice(records, .bds, at);
    if (bds_time.eopFromRecord(model.eopRecord(records, eop, .bds, reference))) |block| {
        out.choice.eop = eop;
        out.value.bcnav.eop = block;
        if (eop == .zero and (families.contains(.bcnav1) or families.contains(.bcnav2) or families.contains(.bcnav3))) try warnings.assumed(.bds);
    }
    for ([_]auxiliary.OffsetKind{ .bdgp, .bdga, .bdgl }, 0..) |kind, i| {
        const index = offsetIndex(records, kind, .bds, at) orelse continue;
        const block = bds_time.bgtoFromRecord(records.time_offsets[index], @intCast(i + 1)) orelse continue;
        out.choice.offsets[i] = index;
        out.value.bcnav.offsets[i] = block;
    }
    return out;
}

fn glonass(records: *const auxiliary.SystemRecords, day: gnav.Day, at: GpsTime, leap: civil.Leap, warnings: *Warnings) std.mem.Allocator.Error!Chosen(model.GlonassChoice, model.Value(.glo)) {
    var out: Chosen(model.GlonassChoice, model.Value(.glo)) = .{ .choice = .{}, .value = null };
    const utc = offsetIndex(records, .glut, .glo, at) orelse return out;
    const gps_index = offsetIndex(records, .glgp, .glo, at) orelse return out;
    const scale = gnav.scale(records.time_offsets[utc], records.time_offsets[gps_index], day) orelse return out;
    out.choice.utc = utc;
    out.choice.gps = gps_index;
    const eop = eopChoice(records, .glo, at);
    const reference = GpsTime.fromGlonass(leap, .{ .n4 = day.n4, .nt = day.na, .ms_of_day = 0, .sub_ms = 0 });
    const string14 = gnav.string14(model.eopRecord(records, eop, .glo, reference), day, at, leap) orelse return out;
    out.choice.eop = eop;
    out.value = .{ .scale = scale, .string14 = string14, .leap = leap };
    if (eop == .zero) try warnings.assumed(.glo);
    return out;
}

fn rank(source: ?gnss_types.System, owner: gnss_types.System) u2 {
    return if (source) |value| if (value == owner) 0 else 1 else 2;
}

fn offsetIndex(records: *const auxiliary.SystemRecords, kind: auxiliary.OffsetKind, owner: gnss_types.System, at: GpsTime) ?u32 {
    var best: ?u32 = null;
    for (records.time_offsets, 0..) |record, index| {
        if (record.kind != kind) continue;
        if (record.transmitted) |transmitted| if (at.lessThan(transmitted)) continue;
        if (best) |previous_index| {
            const previous = records.time_offsets[previous_index];
            const current_rank = rank(record.source, owner);
            const previous_rank = rank(previous.source, owner);
            if (current_rank > previous_rank) continue;
            if (current_rank == previous_rank) {
                const transmitted = record.transmitted orelse continue;
                if (previous.transmitted) |before| if (!before.lessThan(transmitted)) continue;
            }
        }
        best = @intCast(index);
    }
    return best;
}

fn scaleChoice(records: *const auxiliary.SystemRecords, system: gnss_types.System, at: GpsTime) model.ScaleChoice {
    const kind = auxiliary.gpsOffsetKind(system) orelse return .zero;
    const index = offsetIndex(records, kind, system, at) orelse return .zero;
    if (records.time_offsets[index].scaleOffset(at) == null) return .zero;
    return .{ .record = index };
}

fn utcChoice(records: *const auxiliary.SystemRecords, system: gnss_types.System, at: GpsTime) ?model.UtcChoice {
    const kind: auxiliary.OffsetKind = switch (system) {
        .gps => .gput,
        .gal => .gaut,
        .bds => .bdut,
        .glo => .glut,
    };
    if (offsetIndex(records, kind, system, at)) |index| {
        if (records.time_offsets[index].reference == null) return null;
        return .{ .record = index };
    }
    if (system != .bds) return null;
    for ([_]gnss_types.System{ .gps, .gal, .glo }, [_]auxiliary.OffsetKind{ .gput, .gaut, .glut }) |donor, donor_kind| {
        const index = offsetIndex(records, donor_kind, donor, at) orelse continue;
        const record = records.time_offsets[index];
        if (record.reference == null and (record.a1 != 0 or record.a2 != 0)) continue;
        return .{ .derived = .{ .donor = donor, .utc = index, .donor_scale = scaleChoice(records, donor, at), .bds_scale = scaleChoice(records, .bds, at) } };
    }
    return null;
}

fn eopChoice(records: *const auxiliary.SystemRecords, system: gnss_types.System, at: GpsTime) model.EopChoice {
    var best: ?u32 = null;
    for (records.eops, 0..) |record, index| {
        if (system != .glo and record.source != system) continue;
        if (at.lessThan(record.transmitted)) continue;
        if (best) |previous| if (!records.eops[previous].transmitted.lessThan(record.transmitted)) continue;
        best = @intCast(index);
    }
    return if (best) |index| .{ .record = index } else .zero;
}
