const bcnav1_fields = @import("domain/messages/bds/bcnav1/fields");
const bcnav2_fields = @import("domain/messages/bds/bcnav2/fields");
const bcnav3_fields = @import("domain/messages/bds/bcnav3/fields");
const records = @import("domain/navigation/records");
const bds_records = @import("domain/navigation/records/bds");
const ephemeris = @import("domain/messages/bds/fields/ephemeris");
const field = @import("base/binary/field");
const carriage = @import("domain/messages/carriage");
const Kepler = @import("domain/navigation/reference").Kepler;
const Flags = bds_records.BcnavSignalFlags;
const unflagged: Flags = .{ .dif = false, .sif = false, .aif = true };
pub const Content = carriage.Carriage(Sv);
pub const Choice = carriage.Choice;
pub const Preparation = struct { choice: Choice, content: Content };
pub const Sv = struct {
    ephemeris: ephemeris.Prepared,
    codes: union(enum) {
        bcnav1: bcnav1_fields.Codes,
        bcnav2: bcnav2_fields.Codes,
        bcnav3: bcnav3_fields.Codes,
    },
};
pub const Candidate = struct {
    ephemeris: ephemeris.Source,
    // A reference that states no B-CNAV accuracy, as one converted from D1/D2, sends the last index of each, with AIF
    // set: an unknown accuracy is never sent as the best one.
    sismai: u4 = 15,
    sisai_oe: u5 = 31,
    sisai_ocb: u5 = 31,
    sisai_oc1: u3 = 7,
    sisai_oc2: u3 = 7,
    b1c: Flags = unflagged,
    b2a: Flags = unflagged,
    b2b: Flags = unflagged,
    hs_b1c: bool = false,
    hs_b2a: bool = false,
    hs_b2b: bool = false,
    tgd_b1cp: f64,
    isc_b1cd: f64,
    tgd_b2ap: f64,
    isc_b2ad: f64,
    tgd_b2bi: f64,

    pub fn fromReference(e: Kepler, comptime source: records.NavSource) Candidate {
        const tgd_b1cp = e.delay(.b1c, .pilot) orelse 0;
        const tgd_b2ap = e.delay(.b2a, .pilot) orelse 0;
        var sv: Candidate = .{
            .ephemeris = ephemeris.Source.fromReference(e, source),
            .tgd_b1cp = tgd_b1cp,
            .isc_b1cd = (e.delay(.b1c, .data) orelse 0) - tgd_b1cp,
            .tgd_b2ap = tgd_b2ap,
            .isc_b2ad = (e.delay(.b2a, .data) orelse 0) - tgd_b2ap,
            .tgd_b2bi = e.delay(.b2b, .data) orelse 0,
        };
        switch (e.attribute(source) orelse e.record.extra) {
            .bcnav1, .bcnav2, .bcnav3 => |x| {
                sv.sismai = x.sismai;
                sv.sisai_oe = x.sisai_oe;
                sv.sisai_ocb = x.sisai_ocb;
                sv.sisai_oc1 = x.sisai_oc1;
                sv.sisai_oc2 = x.sisai_oc2;
                sv.b1c = x.b1c orelse unflagged;
                sv.b2a = x.b2a orelse unflagged;
                sv.b2b = x.b2b orelse unflagged;
                sv.hs_b1c = x.hs_b1c;
                sv.hs_b2a = x.hs_b2a;
                sv.hs_b2b = x.hs_b2b;
            },
            .d1d2 => |x| {
                sv.hs_b1c = x.sat_h1;
                sv.hs_b2a = x.sat_h1;
                sv.hs_b2b = x.sat_h1;
            },
            else => {},
        }
        return sv;
    }
};

pub fn requireSource(comptime source: records.NavSource) void {
    if (source != .bcnav1 and source != .bcnav2 and source != .bcnav3) @compileError("B-CNAV contents require a B-CNAV message source");
}

/// A B-CNAV family's content for a leg: the reference as its messages carry it, or the first of their fields it does
/// not fit.
pub fn prepare(e: Kepler, comptime source: records.NavSource) Preparation {
    comptime requireSource(source);
    const candidate = Candidate.fromReference(e, source);
    const codes = switch (field.prepare(ephemeris.Source, &ephemeris.broadcast_rows, &candidate.ephemeris)) {
        .codes => |c| c,
        .badfield => |name| return failed(name),
    };
    const fields = familyFields(source);
    const extra = switch (field.prepare(Candidate, &fields.prepared_rows, &candidate)) {
        .codes => |c| c,
        .badfield => |name| return failed(name),
    };
    return .{ .choice = .carried, .content = .{ .carried = .{ .ephemeris = .of(candidate.ephemeris, codes), .codes = @unionInit(@FieldType(Sv, "codes"), @tagName(source), extra) } } };
}

pub fn project(e: Kepler, comptime source: records.NavSource, choice: Choice) Content {
    comptime requireSource(source);
    switch (choice) {
        .unfit => |why| return .{ .unfit = why },
        .carried => {},
    }
    const candidate = Candidate.fromReference(e, source);
    const fields = familyFields(source);
    return .{ .carried = .{
        .ephemeris = .of(candidate.ephemeris, field.project(ephemeris.Source, &ephemeris.broadcast_rows, &candidate.ephemeris)),
        .codes = @unionInit(@FieldType(Sv, "codes"), @tagName(source), field.project(Candidate, &fields.prepared_rows, &candidate)),
    } };
}

fn failed(name: [:0]const u8) Preparation {
    const why: carriage.Unfit = .{ .field = name };
    return .{ .choice = .{ .unfit = why }, .content = .{ .unfit = why } };
}

fn familyFields(comptime source: records.NavSource) type {
    return switch (source) {
        .bcnav1 => bcnav1_fields,
        .bcnav2 => bcnav2_fields,
        .bcnav3 => bcnav3_fields,
        else => @compileError("B-CNAV contents require a B-CNAV message source"),
    };
}
