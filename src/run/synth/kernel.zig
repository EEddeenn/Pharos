const std = @import("std");
const trig = @import("trig.zig");
const rotor = @import("rotor.zig");
const chip = @import("chip.zig");
const noise = @import("noise.zig");
const quantize = @import("quantize.zig");
const tables = @import("tables.zig");
const params = @import("params.zig");
const types = @import("shared").core.types;
const Epoch = @import("shared").core.time.Epoch;

const V4 = trig.V4;
const V4i64 = @Vector(4, i64);

const sub_tile_samples: u32 = 2560;

const reseed_len = rotor.reseed_len;

const expand_limit: f64 = 0.8;

const runs_limit: f64 = 1.0 / 8.0;

const run_store_slack: u32 = 2;

pub fn subTileFor(samples_per_epoch: u32) u32 {
    const len = @min(sub_tile_samples, samples_per_epoch);
    return @max(rotor.stride, std.mem.alignForward(u32, len, rotor.stride));
}

pub const Config = struct {
    samples_per_epoch: u32,
    sub_tile_len: u32,
    format: types.IqFormat,
    noise: noise.Mode,
    seed: u64,
};

pub const Scratch = struct {
    gpa: std.mem.Allocator,
    buffer: []f32,
    acc_re: []f32,
    acc_im: []f32,
    x_re: []f32,
    x_im: []f32,
    n_re: []f32,
    n_im: []f32,

    pub fn init(gpa: std.mem.Allocator, sub_tile_len: u32, slack: u32) error{OutOfMemory}!Scratch {
        const n = sub_tile_len + slack;
        const buffer = try gpa.alloc(f32, 6 * n);
        @memset(buffer[2 * n .. 4 * n], 0);
        return .{
            .gpa = gpa,
            .buffer = buffer,
            .acc_re = buffer[0..n],
            .acc_im = buffer[n..][0..n],
            .x_re = buffer[2 * n ..][0..n],
            .x_im = buffer[3 * n ..][0..n],
            .n_re = buffer[4 * n ..][0..n],
            .n_im = buffer[5 * n ..][0..n],
        };
    }

    pub fn deinit(self: *Scratch) void {
        self.gpa.free(self.buffer);
    }
};

pub fn expandSlack(max_samples_per_entry: f64) u32 {
    return 4 * (storesFor(max_samples_per_entry) + run_store_slack) + rotor.stride;
}

fn storesFor(samples_per_entry: f64) u32 {
    const run_max: u32 = @intFromFloat(@ceil(samples_per_entry) + 1.0);
    return (run_max + 3) / 4;
}

const Complex32 = struct { re: f32, im: f32 };

fn scaledValues(comptime count: usize, t: *const tables.Table, amp: f32) [count]Complex32 {
    var values: [count]Complex32 = undefined;
    for (&values, t.values[0..count]) |*out, value| {
        out.* = .{ .re = @floatCast(amp * value.re), .im = @floatCast(amp * value.im) };
    }
    return values;
}

const Rotor = rotor.Rotor;
const Axis = tables.Axis;

fn Expansion(comptime count: usize, comptime fixed_stores: u32, comptime axis: Axis) type {
    return struct {
        p: *const params.EpochParams,
        x_re: []f32,
        x_im: []f32,
        entries_per_period: u32,
        absolute: u64,
        entry: u32,
        period_offset: usize,
        mask: u8,
        walk: chip.Walk,
        values: [count]Complex32,
        stores: u32,
        end: i64,

        fn init(p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, lead_q: u64, x_re: []f32, x_im: []f32) @This() {
            const entries_per_period = t.entries_per_period;
            const edge: chip.Edge = .of(p);
            std.debug.assert(edge.eps_q != 0);
            const absolute = edge.first + (edge.at(n0) >> 32);
            const period_offset: usize = @intCast(absolute / entries_per_period);
            const walk: chip.Walk = .from(edge, n0, lead_q);
            const stores = storesFor(1.0 / p.entries_per_sample);
            std.debug.assert(stores * 4 >= walk.runMax());
            std.debug.assert(fixed_stores == 0 or fixed_stores == stores);
            return .{
                .p = p,
                .x_re = x_re,
                .x_im = x_im,
                .entries_per_period = entries_per_period,
                .absolute = absolute,
                .entry = @intCast(absolute % entries_per_period),
                .period_offset = period_offset,
                .mask = p.masks[period_offset],
                .walk = walk,
                .values = scaledValues(count, t, p.amp),
                .stores = stores,
                .end = len,
            };
        }

        inline fn storeRun(self: *const @This(), v: Complex32, n: i64) void {
            const start: usize = @intCast(@max(n, 0));
            const vr: V4 = @splat(v.re);
            const vi: V4 = @splat(v.im);
            if (fixed_stores != 0) {
                inline for (0..fixed_stores) |s| self.store(start + 4 * s, vr, vi);
            } else for (0..self.stores) |s| self.store(start + 4 * s, vr, vi);
        }

        inline fn store(self: *const @This(), at: usize, vr: V4, vi: V4) void {
            if (axis != .im) self.x_re[at..][0..4].* = vr;
            if (axis != .re) self.x_im[at..][0..4].* = vi;
        }

        inline fn advanceEntry(self: *@This()) void {
            self.entry += 1;
            if (self.entry == self.entries_per_period) {
                self.entry = 0;
                self.period_offset += 1;
                self.mask = self.p.masks[self.period_offset];
            }
        }
    };
}

fn expandPlain(comptime count: usize, comptime fixed_stores: u32, comptime axis: Axis, p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, x_re: []f32, x_im: []f32) void {
    var x = Expansion(count, fixed_stores, axis).init(p, t, n0, len, 0, x_re, x_im);
    while (x.walk.n < x.end) {
        const n_cur = x.walk.n;
        x.walk.next();
        x.storeRun(x.values[t.states[x.entry] ^ x.mask], n_cur);
        x.advanceEntry();
    }
}

fn expandTdm(comptime count: usize, comptime fixed_stores: u32, comptime axis: Axis, p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, x_re: []f32, x_im: []f32) void {
    var x = Expansion(count, fixed_stores, axis).init(p, t, n0, len, 0, x_re, x_im);
    const mux = t.tdm.?;
    const pilot_chips: []const u8 = mux.pilot;
    var pilot_index = mux.index(p.period0 + x.period_offset, x.entry);
    while (x.walk.n < x.end) {
        const n_cur = x.walk.n;
        x.walk.next();
        if (x.entry & 1 == 1) {
            x.storeRun(x.values[2 | pilot_chips[pilot_index]], n_cur);
            pilot_index += 1;
            if (pilot_index == pilot_chips.len) pilot_index = 0;
        } else {
            x.storeRun(x.values[t.states[x.entry] ^ (x.mask & 1)], n_cur);
        }
        x.advanceEntry();
    }
}

fn expandLead(comptime count: usize, comptime fixed_stores: u32, comptime axis: Axis, p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, x_re: []f32, x_im: []f32) void {
    var x = Expansion(count, fixed_stores, axis).init(p, t, n0, len, chip.leadFrac(p), x_re, x_im);
    const states = t.states;
    const masks = p.masks;
    const lead_bits = p.lead_bits;
    const main_bits = ~lead_bits;
    const per = x.entries_per_period;
    const lead_whole_entries: u64 = @intFromFloat(@floor(p.lead_entries));
    var lead_entry: u32 = @intCast((x.absolute + lead_whole_entries) % per);
    var lead_period: usize = @intCast((x.absolute + lead_whole_entries) / per);
    var lead_state: u8 = states[lead_entry] ^ masks[lead_period];
    if (lead_whole_entries == 0) {
        while (x.walk.n < x.end) {
            const n_cur = x.walk.n;
            const lead_edge_n = n_cur + x.walk.leadRun();
            x.walk.next();
            lead_entry += 1;
            if (lead_entry == per) {
                lead_entry = 0;
                lead_period += 1;
            }
            const next_state = states[lead_entry] ^ masks[lead_period];
            if (lead_edge_n > n_cur) x.storeRun(x.values[lead_state], n_cur);
            if (lead_edge_n < x.walk.n and lead_edge_n < x.end) x.storeRun(x.values[(lead_state & main_bits) | (next_state & lead_bits)], lead_edge_n);
            lead_state = next_state;
        }
        return;
    }
    while (x.walk.n < x.end) {
        const n_cur = x.walk.n;
        const lead_edge_n = n_cur + x.walk.leadRun();
        x.walk.next();
        const state = states[x.entry] ^ x.mask;
        lead_entry += 1;
        if (lead_entry == per) {
            lead_entry = 0;
            lead_period += 1;
        }
        const lead_state_next = states[lead_entry] ^ masks[lead_period];
        if (lead_edge_n > n_cur) x.storeRun(x.values[(state & main_bits) | (lead_state & lead_bits)], n_cur);
        if (lead_edge_n < x.walk.n and lead_edge_n < x.end) x.storeRun(x.values[(state & main_bits) | (lead_state_next & lead_bits)], lead_edge_n);
        lead_state = lead_state_next;
        x.advanceEntry();
    }
}

inline fn accumulate(comptime axis: Axis, rot: *const Rotor, comptime q: usize, j: usize, v: [2]V4, acc_re: []f32, acc_im: []f32) void {
    const ar: V4 = acc_re[j..][0..4].*;
    const ai: V4 = acc_im[j..][0..4].*;
    switch (axis) {
        .both => {
            acc_re[j..][0..4].* = @mulAdd(V4, v[0], rot.c_re[q], @mulAdd(V4, -v[1], rot.c_im[q], ar));
            acc_im[j..][0..4].* = @mulAdd(V4, v[0], rot.c_im[q], @mulAdd(V4, v[1], rot.c_re[q], ai));
        },
        .re => {
            acc_re[j..][0..4].* = @mulAdd(V4, v[0], rot.c_re[q], ar);
            acc_im[j..][0..4].* = @mulAdd(V4, v[0], rot.c_im[q], ai);
        },
        .im => {
            acc_re[j..][0..4].* = @mulAdd(V4, -v[1], rot.c_im[q], ar);
            acc_im[j..][0..4].* = @mulAdd(V4, v[1], rot.c_re[q], ai);
        },
    }
}

fn carrierLoop(comptime axis: Axis, rot: *Rotor, n0: u32, from: u32, strided: u32, acc_re: []f32, acc_im: []f32, source: anytype) void {
    var i = from;
    while (i < strided) {
        const n = n0 + i;
        if (i != 0 and n % reseed_len == 0) rot.seed(n);
        const block_end = @min(i + (reseed_len - n % reseed_len), strided);
        while (i < block_end) : (i += rotor.stride) {
            inline for (0..rotor.chains) |q| {
                const j = i + rotor.lanes * q;
                accumulate(axis, rot, q, j, source.quarter(j), acc_re, acc_im);
            }
            rot.advance();
        }
    }
}

fn rotateAccumulate(comptime axis: Axis, p: *const params.EpochParams, n0: u32, len: u32, acc_re: []f32, acc_im: []f32, source: anytype) void {
    var rot: Rotor = undefined;
    rot.init(p.carrier_phase0, p.carrier_step, n0);
    carrierLoop(axis, &rot, n0, 0, std.mem.alignForward(u32, len, rotor.stride), acc_re, acc_im, source);
}

fn rotateAccumulateInPairs(comptime axis: Axis, p: *const params.EpochParams, n0: u32, len: u32, acc_re: []f32, acc_im: []f32, source: *const Expanded) void {
    const strided = std.mem.alignForward(u32, len, rotor.stride);
    var ra: Rotor = undefined;
    ra.init(p.carrier_phase0, p.carrier_step, n0);
    var base: u32 = 0;
    if (n0 % reseed_len == 0 and strided >= 2 * reseed_len) {
        var rb = ra;
        while (base + 2 * reseed_len <= strided) : (base += 2 * reseed_len) {
            if (base != 0) ra.seed(n0 + base);
            rb.seed(n0 + base + reseed_len);
            var i: u32 = 0;
            while (i < reseed_len) : (i += rotor.stride) {
                inline for (0..rotor.chains) |q| {
                    const ja = base + i + rotor.lanes * q;
                    const jb = ja + reseed_len;
                    accumulate(axis, &ra, q, ja, source.quarter(ja), acc_re, acc_im);
                    accumulate(axis, &rb, q, jb, source.quarter(jb), acc_re, acc_im);
                }
                ra.advance();
                rb.advance();
            }
        }
    }
    carrierLoop(axis, &ra, n0, base, strided, acc_re, acc_im, source);
}

const Expanded = struct {
    x_re: []const f32,
    x_im: []const f32,

    inline fn quarter(self: *const Expanded, j: usize) [2]V4 {
        return .{ self.x_re[j..][0..4].*, self.x_im[j..][0..4].* };
    }
};

fn Runs(comptime count: usize) type {
    return struct {
        x: Expansion(count, 0, .both),
        t: *const tables.Table,
        cur_re: V4,
        cur_im: V4,
        next_n: i64,

        // Inline: a source made by a call stays in memory through the carrier loop.
        inline fn init(p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32) @This() {
            var x = Expansion(count, 0, .both).init(p, t, n0, len, 0, &.{}, &.{});
            const v = x.values[t.states[x.entry] ^ x.mask];
            x.walk.next();
            x.advanceEntry();
            return .{ .x = x, .t = t, .cur_re = @splat(v.re), .cur_im = @splat(v.im), .next_n = x.walk.n };
        }

        inline fn quarter(self: *@This(), j: usize) [2]V4 {
            const start: i64 = @intCast(j);
            if (self.next_n >= start + 4) return .{ self.cur_re, self.cur_im };
            const lanes: V4i64 = @as(V4i64, .{ 0, 1, 2, 3 }) + @as(V4i64, @splat(start));
            var re = self.cur_re;
            var im = self.cur_im;
            while (self.next_n < start + 4) {
                const from: V4i64 = @splat(self.next_n);
                const v = self.x.values[self.t.states[self.x.entry] ^ self.x.mask];
                self.cur_re = @splat(v.re);
                self.cur_im = @splat(v.im);
                const take = lanes >= from;
                re = @select(f32, take, self.cur_re, re);
                im = @select(f32, take, self.cur_im, im);
                self.x.walk.next();
                self.next_n = self.x.walk.n;
                self.x.advanceEntry();
            }
            return .{ re, im };
        }
    };
}

fn Gathered(comptime shape: chip.Shape, comptime count: usize) type {
    return struct {
        nco: chip.Nco,
        lead: chip.Lead,
        t: *const tables.Table,
        v_re: [count]f32,
        v_im: [count]f32,

        // Inline: a source made by a call stays in memory through the carrier loop.
        inline fn init(p: *const params.EpochParams, t: *const tables.Table, n0: u32) @This() {
            var self: @This() = .{
                .nco = chip.Nco.init(p, t, n0),
                .lead = if (shape == .lead) .of(p) else .{},
                .t = t,
                .v_re = undefined,
                .v_im = undefined,
            };
            for (scaledValues(count, t, p.amp), 0..) |v, k| {
                self.v_re[k] = v.re;
                self.v_im[k] = v.im;
            }
            return self;
        }

        inline fn quarter(self: *@This(), _: usize) [2]V4 {
            const st: [4]u32 = self.nco.next(shape, self.t, self.lead);
            return .{
                .{ self.v_re[st[0]], self.v_re[st[1]], self.v_re[st[2]], self.v_re[st[3]] },
                .{ self.v_im[st[0]], self.v_im[st[1]], self.v_im[st[2]], self.v_im[st[3]] },
            };
        }
    };
}

fn synthChannel(p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, s: *Scratch) void {
    const lead = p.lead_bits != 0;
    switch (t.axis) {
        inline else => |axis| {
            if (t.tdm != null) {
                synthImpl(.tdm, 4, axis, p, t, n0, len, s);
            } else if (t.value_count == 4) {
                if (lead) {
                    synthImpl(.lead, 4, axis, p, t, n0, len, s);
                } else {
                    synthImpl(.plain, 4, axis, p, t, n0, len, s);
                }
            } else if (lead) {
                synthImpl(.lead, 8, axis, p, t, n0, len, s);
            } else {
                synthImpl(.plain, 8, axis, p, t, n0, len, s);
            }
        },
    }
}

fn synthImpl(comptime shape: chip.Shape, comptime count: usize, comptime axis: Axis, p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, s: *Scratch) void {
    if (shape == .plain and p.entries_per_sample <= runs_limit) {
        var source = Runs(count).init(p, t, n0, len);
        rotateAccumulate(axis, p, n0, len, s.acc_re, s.acc_im, &source);
    } else if (p.entries_per_sample <= expand_limit) {
        switch (storesFor(1.0 / p.entries_per_sample)) {
            inline 1, 2 => |stores| expand(shape, count, stores, axis, p, t, n0, len, s),
            else => expand(shape, count, 0, axis, p, t, n0, len, s),
        }
        const source: Expanded = .{ .x_re = s.x_re, .x_im = s.x_im };
        rotateAccumulateInPairs(axis, p, n0, len, s.acc_re, s.acc_im, &source);
    } else {
        var source = Gathered(shape, count).init(p, t, n0);
        rotateAccumulate(axis, p, n0, len, s.acc_re, s.acc_im, &source);
    }
}

inline fn expand(comptime shape: chip.Shape, comptime count: usize, comptime fixed_stores: u32, comptime axis: Axis, p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, s: *Scratch) void {
    switch (shape) {
        .plain => expandPlain(count, fixed_stores, axis, p, t, n0, len, s.x_re, s.x_im),
        .tdm => expandTdm(count, fixed_stores, axis, p, t, n0, len, s.x_re, s.x_im),
        .lead => expandLead(count, fixed_stores, axis, p, t, n0, len, s.x_re, s.x_im),
    }
}

pub fn subTiles(cfg: Config) u32 {
    return (cfg.samples_per_epoch + cfg.sub_tile_len - 1) / cfg.sub_tile_len;
}

pub fn synthSubTile(cfg: Config, set: *const tables.TableSet, rows: []const ?params.EpochParams, epoch: Epoch, tile: u32, gain: f32, s: *Scratch, out: []u8) u64 {
    const n0 = tile * cfg.sub_tile_len;
    const len = @min(cfg.sub_tile_len, cfg.samples_per_epoch - n0);
    const strided = std.mem.alignForward(u32, len, rotor.stride);
    @memset(s.acc_re[0..strided], 0);
    @memset(s.acc_im[0..strided], 0);
    for (rows) |*row| {
        if (row.*) |*p| synthChannel(p, &set.tables[p.table], n0, len, s);
    }
    addNoise(cfg, epoch, n0, len, strided, s);
    return quantize.pack(cfg.format, s.acc_re[0..len], s.acc_im[0..len], gain, out[cfg.format.bytesFor(n0)..]);
}

fn addNoise(cfg: Config, epoch: Epoch, n0: u32, len: u32, strided: u32, s: *Scratch) void {
    const first: u64 = epoch.ms * cfg.samples_per_epoch + n0;
    if (cfg.noise == .counter and first % 4 == 0) {
        var j: usize = 0;
        var g: u64 = first / 4;
        while (j < len) : ({
            j += 4;
            g += 1;
        }) {
            const pair = noise.group(cfg.seed, g);
            s.acc_re[j..][0..4].* = @as(V4, s.acc_re[j..][0..4].*) + pair.re;
            s.acc_im[j..][0..4].* = @as(V4, s.acc_im[j..][0..4].*) + pair.im;
        }
        return;
    }
    noise.fill(cfg.noise, cfg.seed, epoch, cfg.samples_per_epoch, n0, s.n_re[0..strided], s.n_im[0..strided]);
    var j: usize = 0;
    while (j < len) : (j += 4) {
        s.acc_re[j..][0..4].* = @as(V4, s.acc_re[j..][0..4].*) + @as(V4, s.n_re[j..][0..4].*);
        s.acc_im[j..][0..4].* = @as(V4, s.acc_im[j..][0..4].*) + @as(V4, s.n_im[j..][0..4].*);
    }
}
