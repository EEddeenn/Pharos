const std = @import("std");
const rotor = @import("products/run/synthesis/rotor");
const chip = @import("products/run/synthesis/chip");
const noise = @import("products/run/synthesis/noise");
const quantize = @import("products/run/synthesis/quantize");
const tables = @import("products/run/synthesis/code_tables");
const params = @import("products/run/synthesis/parameters");
const sampling = @import("simulation/model/sampling");

const Epoch = @import("domain/time/gps").Epoch;
const Rotor = rotor.Rotor;
const Axis = tables.Axis;

const reseed_len = rotor.reseed_len;

const V4 = @Vector(4, f32);
const V4i64 = @Vector(4, i64);

const sub_tile_samples: u32 = 2560;

comptime {
    std.debug.assert(sub_tile_samples % reseed_len == 0);
}

const expand_limit: f64 = 0.8;

const runs_limit: f64 = 1.0 / 8.0;

const run_store_slack: u32 = 2;

pub const Config = struct {
    samples_per_epoch: u32,
    sub_tile_len: u32,
    format: sampling.IqFormat,
    noise: noise.Mode,
    seed: u64,
};

pub const Scratch = struct {
    storage: []f32,
    acc_re: []f32,
    acc_im: []f32,
    x_re: []f32,
    x_im: []f32,

    pub fn init(gpa: std.mem.Allocator, sub_tile_len: u32, slack: u32) error{OutOfMemory}!Scratch {
        const n = sub_tile_len + slack;
        const buffer = try gpa.alloc(f32, 4 * n);
        return .{
            .storage = buffer,
            .acc_re = buffer[0..n],
            .acc_im = buffer[n..][0..n],
            .x_re = buffer[2 * n ..][0..n],
            .x_im = buffer[3 * n ..][0..n],
        };
    }

    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        gpa.free(self.storage);
    }
};

const Complex32 = struct { re: f32, im: f32 };

const Expanded = struct {
    x_re: []const f32,
    x_im: []const f32,

    inline fn quarter(self: *const Expanded, j: usize) [2]V4 {
        return .{ self.x_re[j..][0..4].*, self.x_im[j..][0..4].* };
    }
};

pub fn subTileFor(samples_per_epoch: u32) u32 {
    return std.mem.alignForward(u32, @min(sub_tile_samples, samples_per_epoch), rotor.stride);
}

pub fn expandSlack(max_samples_per_entry: f64) u32 {
    return 4 * (storesFor(max_samples_per_entry) + run_store_slack) + rotor.stride;
}

pub fn subTiles(configuration: Config) u32 {
    return (configuration.samples_per_epoch + configuration.sub_tile_len - 1) / configuration.sub_tile_len;
}

pub fn synthSubTile(configuration: Config, set: *const tables.TableSet, rows: []const ?params.EpochParams, epoch: Epoch, tile: u32, gain: f32, s: *Scratch, out: []u8) u64 {
    const n0 = tile * configuration.sub_tile_len;
    const len = @min(configuration.sub_tile_len, configuration.samples_per_epoch - n0);
    const strided = std.mem.alignForward(u32, len, rotor.stride);
    @memset(s.acc_re[0..strided], 0);
    @memset(s.acc_im[0..strided], 0);
    for (rows) |*row| {
        if (row.*) |*p| synthChannel(p, &set.tables[p.table], n0, len, s);
    }
    addNoise(configuration, epoch, n0, len, s);
    return quantize.pack(configuration.format, s.acc_re[0..len], s.acc_im[0..len], gain, out[configuration.format.bytesFor(n0)..]);
}

fn storesFor(samples_per_entry: f64) u32 {
    const run_max: u32 = @intFromFloat(@ceil(samples_per_entry) + 1.0);
    return (run_max + 3) / 4;
}

fn scaledValues(comptime count: usize, t: *const tables.Table, amp: f32) [count]Complex32 {
    var values: [count]Complex32 = undefined;
    for (&values, t.values[0..count]) |*out, value| {
        out.* = .{ .re = @floatCast(amp * value.re), .im = @floatCast(amp * value.im) };
    }
    return values;
}

fn CodeRun(comptime count: usize) type {
    return struct {
        masks: []const u8,
        entries_per_period: u32,
        entry: u32,
        period_offset: usize,
        mask: u8,
        walk: chip.Walk,
        values: [count]Complex32,

        fn init(p: *const params.EpochParams, t: *const tables.Table, n0: u32, lead_q: u64) @This() {
            const entries_per_period = t.entries_per_period;
            const edge: chip.Edge = .of(p);
            std.debug.assert(edge.eps_q != 0);
            const absolute = edge.first + (edge.at(n0) >> 32);
            const period_offset: usize = @intCast(absolute / entries_per_period);
            const walk: chip.Walk = .from(edge, n0, lead_q);
            return .{
                .masks = p.masks,
                .entries_per_period = entries_per_period,
                .entry = @intCast(absolute % entries_per_period),
                .period_offset = period_offset,
                .mask = p.masks[period_offset],
                .walk = walk,
                .values = scaledValues(count, t, p.amp),
            };
        }

        inline fn advanceEntry(self: *@This()) void {
            self.entry += 1;
            if (self.entry == self.entries_per_period) {
                self.entry = 0;
                self.period_offset += 1;
                self.mask = self.masks[self.period_offset];
            }
        }
    };
}

fn runStores(p: *const params.EpochParams, walk: chip.Walk, comptime fixed: u32) u32 {
    const stores = storesFor(1.0 / p.entries_per_sample);
    std.debug.assert(stores * 4 >= walk.runMax());
    std.debug.assert(fixed == 0 or fixed == stores);
    return stores;
}

inline fn storeRun(comptime fixed: u32, comptime axis: Axis, stores: u32, x_re: []f32, x_im: []f32, value: Complex32, n: i64) void {
    const start: usize = @intCast(@max(n, 0));
    const re: V4 = @splat(value.re);
    const im: V4 = @splat(value.im);
    if (fixed != 0) {
        inline for (0..fixed) |i| {
            const at = start + 4 * i;
            if (axis != .im) x_re[at..][0..4].* = re;
            if (axis != .re) x_im[at..][0..4].* = im;
        }
    } else {
        for (0..stores) |i| {
            const at = start + 4 * i;
            if (axis != .im) x_re[at..][0..4].* = re;
            if (axis != .re) x_im[at..][0..4].* = im;
        }
    }
}

fn expandPlain(comptime count: usize, comptime fixed_stores: u32, comptime axis: Axis, p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, x_re: []f32, x_im: []f32) void {
    var x = CodeRun(count).init(p, t, n0, 0);
    const stores = runStores(p, x.walk, fixed_stores);
    while (x.walk.n < len) {
        const n_cur = x.walk.n;
        x.walk.next();
        storeRun(fixed_stores, axis, stores, x_re, x_im, x.values[t.states[x.entry] ^ x.mask], n_cur);
        x.advanceEntry();
    }
}

fn expandTdm(comptime count: usize, comptime fixed_stores: u32, comptime axis: Axis, p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, x_re: []f32, x_im: []f32) void {
    var x = CodeRun(count).init(p, t, n0, 0);
    const stores = runStores(p, x.walk, fixed_stores);
    const mux = t.tdm.?;
    const pilot_chips: []const u8 = mux.pilot;
    var pilot_index = mux.index(p.period0 + x.period_offset, x.entry);
    while (x.walk.n < len) {
        const n_cur = x.walk.n;
        x.walk.next();
        if (x.entry & 1 == 1) {
            storeRun(fixed_stores, axis, stores, x_re, x_im, x.values[2 | pilot_chips[pilot_index]], n_cur);
            pilot_index += 1;
            if (pilot_index == pilot_chips.len) pilot_index = 0;
        } else {
            storeRun(fixed_stores, axis, stores, x_re, x_im, x.values[t.states[x.entry] ^ (x.mask & 1)], n_cur);
        }
        x.advanceEntry();
    }
}

fn expandLead(comptime count: usize, comptime fixed_stores: u32, comptime axis: Axis, p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, x_re: []f32, x_im: []f32) void {
    var x = CodeRun(count).init(p, t, n0, chip.leadFrac(p));
    const stores = runStores(p, x.walk, fixed_stores);
    const states = t.states;
    const masks = p.masks;
    const lead_bits = p.lead_bits;
    const main_bits = ~lead_bits;
    const per = x.entries_per_period;
    const lead_whole_entries: u64 = @intFromFloat(@floor(p.lead_entries));
    const absolute = @as(u64, @intCast(x.period_offset)) * per + x.entry;
    var lead_entry: u32 = @intCast((absolute + lead_whole_entries) % per);
    var lead_period: usize = @intCast((absolute + lead_whole_entries) / per);
    var lead_state: u8 = states[lead_entry] ^ masks[lead_period];
    switch (lead_whole_entries == 0) {
        inline true, false => |same| while (x.walk.n < len) {
            const n_cur = x.walk.n;
            const lead_edge_n = n_cur + x.walk.leadRun();
            x.walk.next();
            const state = if (same) lead_state else states[x.entry] ^ x.mask;
            lead_entry += 1;
            if (lead_entry == per) {
                lead_entry = 0;
                lead_period += 1;
            }
            const lead_state_next = states[lead_entry] ^ masks[lead_period];
            if (lead_edge_n > n_cur) storeRun(fixed_stores, axis, stores, x_re, x_im, x.values[(state & main_bits) | (lead_state & lead_bits)], n_cur);
            if (lead_edge_n < x.walk.n and lead_edge_n < len) storeRun(fixed_stores, axis, stores, x_re, x_im, x.values[(state & main_bits) | (lead_state_next & lead_bits)], lead_edge_n);
            lead_state = lead_state_next;
            if (!same) x.advanceEntry();
        },
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
    carrierLoop(axis, &ra, n0, base, strided, acc_re, acc_im, source);
}

fn Runs(comptime count: usize) type {
    return struct {
        code: CodeRun(count),
        t: *const tables.Table,
        cur_re: V4,
        cur_im: V4,

        // Inline: a source made by a call stays in memory through the carrier loop.
        inline fn init(p: *const params.EpochParams, t: *const tables.Table, n0: u32) @This() {
            var x = CodeRun(count).init(p, t, n0, 0);
            const v = x.values[t.states[x.entry] ^ x.mask];
            x.walk.next();
            x.advanceEntry();
            return .{ .code = x, .t = t, .cur_re = @splat(v.re), .cur_im = @splat(v.im) };
        }

        inline fn quarter(self: *@This(), j: usize) [2]V4 {
            const start: i64 = @intCast(j);
            if (self.code.walk.n >= start + 4) return .{ self.cur_re, self.cur_im };
            const lanes: V4i64 = @as(V4i64, .{ 0, 1, 2, 3 }) + @as(V4i64, @splat(start));
            var re = self.cur_re;
            var im = self.cur_im;
            while (self.code.walk.n < start + 4) {
                const from: V4i64 = @splat(self.code.walk.n);
                const v = self.code.values[self.t.states[self.code.entry] ^ self.code.mask];
                self.cur_re = @splat(v.re);
                self.cur_im = @splat(v.im);
                const take = lanes >= from;
                re = @select(f32, take, self.cur_re, re);
                im = @select(f32, take, self.cur_im, im);
                self.code.walk.next();
                self.code.advanceEntry();
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
    switch (@as(chip.Shape, if (t.tdm != null) .tdm else if (p.lead_bits != 0) .lead else .plain)) {
        inline else => |shape| switch (t.axis) {
            inline else => |axis| if (shape == .tdm or t.value_count == .four) synthImpl(shape, 4, axis, p, t, n0, len, s) else synthImpl(shape, 8, axis, p, t, n0, len, s),
        },
    }
}

fn synthImpl(comptime shape: chip.Shape, comptime count: usize, comptime axis: Axis, p: *const params.EpochParams, t: *const tables.Table, n0: u32, len: u32, s: *Scratch) void {
    if (shape == .plain and p.entries_per_sample <= runs_limit) {
        var source = Runs(count).init(p, t, n0);
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

fn addNoise(configuration: Config, epoch: Epoch, n0: u32, len: u32, s: *Scratch) void {
    if (configuration.noise == .off) return;
    const first: u64 = epoch.ms * configuration.samples_per_epoch + n0;
    var j: usize = 0;
    var g: u64 = first / 4;
    if (first % 4 != 0) {
        const pair = noise.group(configuration.seed, g);
        const re: [4]f32 = pair.re;
        const im: [4]f32 = pair.im;
        for (@intCast(first % 4)..4) |lane| {
            s.acc_re[j] += re[lane];
            s.acc_im[j] += im[lane];
            j += 1;
        }
        g += 1;
    }
    while (j < len) : ({
        j += 4;
        g += 1;
    }) {
        const pair = noise.group(configuration.seed, g);
        s.acc_re[j..][0..4].* = @as(V4, s.acc_re[j..][0..4].*) + pair.re;
        s.acc_im[j..][0..4].* = @as(V4, s.acc_im[j..][0..4].*) + pair.im;
    }
}
