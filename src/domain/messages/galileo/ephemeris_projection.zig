const records = @import("domain/navigation/records");
const reference = @import("domain/navigation/reference");
const Parameters = @import("domain/navigation/orbit/parameters").Parameters;

pub fn forSource(e: reference.Kepler, comptime source: records.NavSource) Parameters {
    var out = e.record.parameters();
    if (e.record.source() != source) {
        const origin: records.GroupDelayTerm = if (e.record.source() == .fnav) .bgd_e1e5a else .bgd_e1e5b;
        const target: records.GroupDelayTerm = if (source == .fnav) .bgd_e1e5a else .bgd_e1e5b;
        out.af0 += (e.group_delay.get(target) orelse 0) - (e.group_delay.get(origin) orelse 0);
    }

    return out;
}
