const tables = @import("tables.zig");
const params = @import("params.zig");

const V4u = @Vector(4, u32);

pub const Shape = enum { plain, tdm, lead };

const unit: u64 = 1 << 32;
const unit_f: f64 = unit;
const max_frac: f64 = unit_f - 1;

fn fracQ(frac: f64) u32 {
    return @intFromFloat(@min(@round(frac * unit_f), max_frac));
}

pub const Edge = struct {
    first: u64,
    phase_q: u64,
    eps_q: u64,

    pub fn of(p: *const params.EpochParams) Edge {
        const e_floor = @floor(p.entry_phase0);
        return .{
            .first = @intFromFloat(e_floor),
            .phase_q = fracQ(p.entry_phase0 - e_floor),
            .eps_q = @intFromFloat(@round(p.entries_per_sample * unit_f)),
        };
    }

    pub inline fn at(self: Edge, n: u64) u64 {
        return self.phase_q + n * self.eps_q;
    }
};

pub fn leadFrac(p: *const params.EpochParams) u32 {
    const whole = @floor(p.lead_entries);
    return fracQ(p.lead_entries - whole);
}

pub const Lead = struct {
    bits: u32 = 0,
    whole: u32 = 0,
    frac: V4u = @splat(0),

    pub fn of(p: *const params.EpochParams) Lead {
        return .{
            .bits = p.lead_bits,
            .whole = @intFromFloat(@floor(p.lead_entries)),
            .frac = @splat(leadFrac(p)),
        };
    }
};

pub const Walk = struct {
    n: i64,
    remainder_q: u64,
    eps_q: u64,
    samples_per_entry: i64,
    samples_per_entry_rem_q: u64,
    samples_to_lead_edge: i64,
    samples_to_lead_edge_rem_q: u64,

    pub fn from(e: Edge, n0: u32, lead_q: u64) Walk {
        const into = e.at(n0) & (unit - 1);
        const back = into / e.eps_q;
        return .{
            .n = -@as(i64, @intCast(back)),
            .remainder_q = into - back * e.eps_q,
            .eps_q = e.eps_q,
            .samples_per_entry = @intCast(unit / e.eps_q),
            .samples_per_entry_rem_q = unit % e.eps_q,
            .samples_to_lead_edge = @intCast((unit - lead_q) / e.eps_q),
            .samples_to_lead_edge_rem_q = (unit - lead_q) % e.eps_q,
        };
    }

    pub inline fn leadRun(self: Walk) i64 {
        return self.samples_to_lead_edge + @intFromBool(self.remainder_q < self.samples_to_lead_edge_rem_q);
    }

    pub inline fn runMax(self: Walk) i64 {
        return self.samples_per_entry + @intFromBool(self.samples_per_entry_rem_q != 0);
    }

    pub inline fn next(self: *Walk) void {
        const long = self.remainder_q < self.samples_per_entry_rem_q;
        self.n += self.samples_per_entry + @intFromBool(long);
        self.remainder_q = if (long) self.remainder_q + self.eps_q - self.samples_per_entry_rem_q else self.remainder_q - self.samples_per_entry_rem_q;
    }
};

pub const Nco = struct {
    idx: V4u,
    frac: V4u,
    step_rem: V4u,
    step_periods: V4u,
    sfrac: V4u,
    per: V4u,
    period: V4u,
    masks: []const u8,
    period0: u64,

    pub fn init(p: *const params.EpochParams, t: *const tables.Table, n0: u32) Nco {
        const per = t.entries_per_period;
        const edge: Edge = .of(p);
        var idx: [4]u32 = undefined;
        var frac: [4]u32 = undefined;
        var period: [4]u32 = undefined;
        for (0..4) |l| {
            const position = edge.at(n0 + l);
            const absolute = edge.first + (position >> 32);
            idx[l] = @intCast(absolute % per);
            period[l] = @intCast(absolute / per);
            frac[l] = @truncate(position);
        }
        const step4 = 4 * edge.eps_q;
        const whole: u64 = step4 >> 32;
        return .{
            .idx = idx,
            .frac = frac,
            .step_rem = @splat(@intCast(whole % per)),
            .step_periods = @splat(@intCast(whole / per)),
            .sfrac = @splat(@truncate(step4)),
            .per = @splat(per),
            .period = period,
            .masks = p.masks,
            .period0 = p.period0,
        };
    }

    pub inline fn next(self: *Nco, comptime shape: Shape, t: *const tables.Table, lead: Lead) [4]u32 {
        const entries: [4]u32 = self.idx;
        const period_offsets: [4]u32 = self.period;
        // The lanes' periods never decrease, so when the first and the last share one, all four do.
        const shared = period_offsets[0] == period_offsets[3];
        var out: [4]u32 = undefined;
        inline for (&out, entries, period_offsets) |*o, entry, period| {
            const mask = self.masks[if (shared) period_offsets[0] else period];
            o.* = if (shape == .tdm and entry & 1 == 1) 2 | t.tdm.?.pilot[t.tdm.?.index(self.period0 + period, entry)] else t.states[entry] ^ (if (shape == .tdm) mask & 1 else mask);
        }
        if (shape == .lead) out = self.leadState(out, t, entries, period_offsets, lead);
        const old = self.frac;
        self.frac +%= self.sfrac;
        const carry: V4u = @intFromBool(self.frac < old);
        const advanced = self.idx + self.step_rem + carry;
        const over = advanced >= self.per;
        self.idx = @select(u32, over, advanced -% self.per, advanced);
        self.period += self.step_periods + @as(V4u, @intFromBool(over));
        return out;
    }

    inline fn leadState(self: *const Nco, st: [4]u32, t: *const tables.Table, entries: [4]u32, period_offsets: [4]u32, lead: Lead) [4]u32 {
        const carry = self.frac +% lead.frac < self.frac;
        if (lead.whole == 0 and !@reduce(.Or, carry)) return st;
        var out = st;
        inline for (0..4) |i| {
            if (lead.whole != 0 or carry[i]) {
                var lead_entry = entries[i] + lead.whole + @intFromBool(carry[i]);
                var lead_period = period_offsets[i];
                if (lead_entry >= t.entries_per_period) {
                    lead_entry -= t.entries_per_period;
                    lead_period += 1;
                }
                out[i] = (out[i] & ~lead.bits) | ((t.states[lead_entry] ^ self.masks[lead_period]) & lead.bits);
            }
        }
        return out;
    }
};
