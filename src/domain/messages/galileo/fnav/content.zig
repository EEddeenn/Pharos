const field = @import("base/binary/field");
const galileo_records = @import("domain/navigation/records/galileo");
const reference = @import("domain/navigation/reference");
const projection = @import("domain/messages/galileo/ephemeris_projection");
const fields = @import("domain/messages/galileo/fnav/fields");

const carriage = @import("domain/messages/carriage");
const OrbitParameters = @import("domain/navigation/orbit/parameters").Parameters;
pub const Parameters = struct {
    eph: OrbitParameters,
    iod_nav: u10,
    sisa_index: u8,
    e5a_hs: u2,
    e5a_dvs: bool,
    bgd_e1e5a: f64,
    clock_fits: bool,
};
pub const Content = carriage.Carriage(Parameters);
pub const Choice = union(enum) { carried: struct { clock_fits: bool }, unfit: carriage.Unfit };
pub const Preparation = struct { choice: Choice, content: Content };

/// F/NAV's content for a leg: the reference projected onto F/NAV's clock, and whether page 1 can carry that clock (else
/// it is a dummy page), or the first field of the other pages it does not fit.
pub fn prepare(e: reference.Kepler) Preparation {
    var out = parametersOf(e, false);
    if (misfit(&out)) |name| {
        const why: carriage.Unfit = .{ .field = name };
        return .{ .choice = .{ .unfit = why }, .content = .{ .unfit = why } };
    }
    out.clock_fits = clockFits(&out);
    return .{ .choice = .{ .carried = .{ .clock_fits = out.clock_fits } }, .content = .{ .carried = out } };
}

pub fn project(e: reference.Kepler, choice: Choice) Content {
    return switch (choice) {
        .carried => |chosen| .{ .carried = parametersOf(e, chosen.clock_fits) },
        .unfit => |why| .{ .unfit = why },
    };
}

fn parametersOf(e: reference.Kepler, clock_fits: bool) Parameters {
    const extra: ?galileo_records.FnavExtra = if (e.attribute(.fnav)) |x| x.fnav else null;
    return .{
        .eph = projection.forSource(e, .fnav),
        .iod_nav = reference.galileoIssue(e.record),
        .sisa_index = if (extra) |x| x.sisa_index else galileo_records.sisa_napa,
        .e5a_hs = if (extra) |x| x.e5a_hs else 0,
        .e5a_dvs = if (extra) |x| x.e5a_dvs else false,
        .bgd_e1e5a = e.group_delay.get(.bgd_e1e5a) orelse 0,
        .clock_fits = clock_fits,
    };
}

fn misfit(eph: *const Parameters) ?[:0]const u8 {
    inline for (.{ &fields.page2, &fields.page3, &fields.page4 }) |rows| if (field.misfit(Parameters, rows, eph)) |name| return name;
    return null;
}

fn clockFits(eph: *const Parameters) bool {
    return field.fits(Parameters, &fields.page1, eph) and field.fits(Parameters, &fields.page1_tail, eph);
}
