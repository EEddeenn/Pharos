const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const types = core.types;
const GpsTime = core.time.GpsTime;
const coord = core.coord;
const bundle = @import("../bundle.zig");
const selection = @import("selection.zig");

const blend_s: f64 = 600;
const knot_span_s: f64 = 1;
const light_time_s: f64 = 1;

pub const Cursor = struct {
    system: types.System,
    leap: core.civil.Leap,
    grid: GpsTime,
    leg: GpsTime,

    pub fn init(system: types.System, start: GpsTime, leap: core.civil.Leap) Cursor {
        return .{ .system = system, .leap = leap, .grid = start, .leg = start };
    }

    pub fn peek(self: *const Cursor) GpsTime {
        return if (self.leg.lessThan(self.grid)) self.leg else self.grid;
    }

    pub fn next(self: *Cursor, t: GpsTime) ?GpsTime {
        const at = self.peek();
        if (t.lessThan(at)) return null;
        if (self.grid.eql(at)) self.grid = bundle.plan.nextLegBoundary(.gps, at, self.leap);
        if (self.leg.eql(at)) self.leg = bundle.plan.nextLegBoundary(self.system, at, self.leap);
        return at;
    }
};

fn servingSpan(at: GpsTime, next: GpsTime) selection.Span {
    return .{ .from = at.addSeconds(-(knot_span_s + light_time_s)), .until = next.addSeconds(knot_span_s) };
}

pub fn productServes(product: *const bundle.precise.Product, sat: types.SatId, at: GpsTime, leap: core.civil.Leap) bool {
    var cursor: Cursor = .init(sat.system, at, leap);
    _ = cursor.next(at);
    const span = servingSpan(at, cursor.peek());
    return product.serves(sat, span.from, span.until);
}

pub const Advance = struct { refreshed: bool = false, switched: bool = false };

pub const State = bundle.precise.State;

const Residual = struct {
    pos: coord.Ecef,
    clock_bias_s: f64,
    rel_s: f64,
};

const DelayTable = struct {
    terms: [gnss.spec.max_per_system]std.EnumArray(types.Component, f64) = @splat(.initFill(0)),
    shift_s: f64 = 0,
};

pub const Delays = struct {
    air: []const gnss.air.Row,
    freq: ?types.FreqId,
    shift_s: f64,
    transition: ?struct { weight: f64, from: DelayTable } = null,

    pub fn term(self: *const Delays, signal: types.Signal, component: types.Component) f64 {
        const now = self.air[gnss.spec.slot(signal)].delay_s.get(component);
        const t = self.transition orelse return now;
        return now + (t.from.terms[gnss.spec.slot(signal)].get(component) - now) * t.weight;
    }

    pub fn shift(self: *const Delays) f64 {
        const t = self.transition orelse return self.shift_s;
        return self.shift_s + (t.from.shift_s - self.shift_s) * t.weight;
    }

    pub fn code(self: *const Delays, signal: types.Signal, component: types.Component) f64 {
        return self.term(signal, component) - self.shift();
    }

    pub fn carrier(self: *const Delays, signal: types.Signal) f64 {
        const c = gnss.delay.carrierCode(signal);
        return self.code(c.signal, c.component);
    }

    pub fn carrierTerm(self: *const Delays, signal: types.Signal) f64 {
        const c = gnss.delay.carrierCode(signal);
        return self.term(c.signal, c.component);
    }
};

pub const DelaySnapshot = struct {
    air: []const gnss.air.Row,
    freq: ?types.FreqId,
    shift_s: f64,
    from: ?DelayTable,
    blend_until: GpsTime,

    pub fn at(self: *const DelaySnapshot, t: GpsTime) Delays {
        var out: Delays = .{ .air = self.air, .freq = self.freq, .shift_s = self.shift_s };
        const remaining = self.blend_until.secondsSince(t);
        if (self.from) |from| if (remaining > 0) {
            out.transition = .{ .weight = remaining / blend_s, .from = from };
        };
        return out;
    }
};

const Resolved = struct { t: GpsTime, span: selection.Span };

pub const Mark = struct {
    current: ?Resolved,
    previous: ?Resolved,
    previous_residual: ?Residual,
    delays_from: ?DelayTable,
    orbit_blend_until: GpsTime,
    delay_blend_until: GpsTime,
    cursor: ?Cursor,
};

pub const Track = struct {
    current: ?selection.Selection = null,
    previous: ?selection.Selection = null,
    current_at: ?Resolved = null,
    previous_at: ?Resolved = null,
    previous_residual: ?Residual = null,
    delays_from: ?DelayTable = null,
    orbit_blend_until: GpsTime = .epoch,
    delay_blend_until: GpsTime = .epoch,
    cursor: ?Cursor = null,

    pub fn mark(self: *const Track) Mark {
        return .{
            .current = self.current_at,
            .previous = self.previous_at,
            .previous_residual = self.previous_residual,
            .delays_from = self.delays_from,
            .orbit_blend_until = self.orbit_blend_until,
            .delay_blend_until = self.delay_blend_until,
            .cursor = self.cursor,
        };
    }

    pub fn restore(b: *const bundle.Bundle, sat: types.SatId, m: Mark) Track {
        return .{
            .current = if (m.current) |at| selection.resolve(b, sat, at.t, at.span) else null,
            .previous = if (m.previous) |at| selection.resolve(b, sat, at.t, at.span) else null,
            .current_at = m.current,
            .previous_at = m.previous,
            .previous_residual = m.previous_residual,
            .delays_from = m.delays_from,
            .orbit_blend_until = m.orbit_blend_until,
            .delay_blend_until = m.delay_blend_until,
            .cursor = m.cursor,
        };
    }

    pub fn advanceTo(self: *Track, b: *const bundle.Bundle, sat: types.SatId, t: GpsTime) Advance {
        var cursor = self.cursor orelse Cursor.init(sat.system, b.plan.start, b.plan.leap);
        var out: Advance = .{};
        while (cursor.next(t)) |at| {
            out.refreshed = true;
            if (self.refresh(b, sat, at, servingSpan(at, cursor.peek()))) out.switched = true;
        }
        self.cursor = cursor;
        return out;
    }

    pub fn nextInstant(self: *const Track, b: *const bundle.Bundle, sat: types.SatId) GpsTime {
        const cursor = self.cursor orelse Cursor.init(sat.system, b.plan.start, b.plan.leap);
        return cursor.peek();
    }

    fn refresh(self: *Track, b: *const bundle.Bundle, sat: types.SatId, t: GpsTime, span: selection.Span) bool {
        const next = selection.resolve(b, sat, t, span) orelse {
            self.* = .{ .cursor = self.cursor };
            return false;
        };
        const at: Resolved = .{ .t = t, .span = span };
        const cur = self.current orelse {
            self.current = next;
            self.current_at = at;
            return false;
        };
        const switched = !std.meta.eql(cur.identity, next.identity);
        if (switched or !sameDelays(cur.air, next.air) or cur.delay_shift_s != next.delay_shift_s) {
            self.delays_from = self.tableAt(t);
            if (switched) {
                self.previous_residual = self.residualAt(t);
                self.previous = cur;
                self.previous_at = self.current_at;
                self.orbit_blend_until = t.addSeconds(blend_s);
            }
            self.delay_blend_until = t.addSeconds(blend_s);
        }
        self.current = next;
        self.current_at = at;
        return switched;
    }

    pub fn stateAt(self: *Track, t: GpsTime) State {
        var out = propagate(&self.current.?.source, t);
        const remaining = self.orbit_blend_until.secondsSince(t);
        if (self.previous) |*prev| if (remaining > 0) {
            const w = remaining / blend_s;
            var old = propagate(&prev.source, t);
            if (self.previous_residual) |d| {
                old.pos = old.pos.add(d.pos);
                old.clock_bias_s += d.clock_bias_s;
                old.rel_s += d.rel_s;
            }
            const gap = old.pos.sub(out.pos);
            out.pos = out.pos.add(gap.scale(w));
            out.vel = out.vel.add(old.vel.sub(out.vel).scale(w).sub(gap.divide(blend_s)));
            const gap_bias = old.clock_bias_s - out.clock_bias_s;
            out.clock_bias_s += gap_bias * w;
            out.clock_drift += (old.clock_drift - out.clock_drift) * w - gap_bias / blend_s;
            out.rel_s += (old.rel_s - out.rel_s) * w;
        };
        return out;
    }

    pub fn phaseCentre(self: *const Track) ?*const bundle.antex.PhaseCentre {
        const cur = &self.current.?;
        return if (cur.phase_centre) |*centre| centre else null;
    }

    pub fn delaySnapshot(self: *const Track) DelaySnapshot {
        const cur = self.current.?;
        return .{ .air = cur.air, .freq = cur.record.freq(), .shift_s = cur.delay_shift_s, .from = self.delays_from, .blend_until = self.delay_blend_until };
    }

    pub fn delaysAt(self: *const Track, t: GpsTime) Delays {
        return self.delaySnapshot().at(t);
    }

    fn tableAt(self: *const Track, t: GpsTime) DelayTable {
        const d = self.delaysAt(t);
        const system = self.current.?.sat.system;
        var table: DelayTable = .{ .shift_s = d.shift() };
        for (std.meta.tags(types.Signal)) |signal| {
            if (signal.system() != system) continue;
            for (std.meta.tags(types.Component)) |component| table.terms[gnss.spec.slot(signal)].set(component, d.term(signal, component));
        }
        return table;
    }

    fn residualAt(self: *Track, t: GpsTime) ?Residual {
        if (self.previous == null or !(self.orbit_blend_until.secondsSince(t) > 0)) return null;
        const blended = self.stateAt(t);
        const now = propagate(&self.current.?.source, t);
        return .{
            .pos = blended.pos.sub(now.pos),
            .clock_bias_s = blended.clock_bias_s - now.clock_bias_s,
            .rel_s = blended.rel_s - now.rel_s,
        };
    }
};

fn sameDelays(a: []const gnss.air.Row, b: []const gnss.air.Row) bool {
    for (a, b) |x, y| if (!std.meta.eql(x.delay_s, y.delay_s)) return false;
    return true;
}

fn propagate(source: *selection.Source, t: GpsTime) State {
    return switch (source.*) {
        .kepler => |*k| blk: {
            const s = k.orbit.state(t);
            break :blk .{ .pos = s.pos, .vel = s.vel, .clock_bias_s = k.clock.bias(t), .clock_drift = k.clock.drift(t), .rel_s = s.rel_s };
        },
        .glonass => |*g| blk: {
            const s = g.orbit.advance(t);
            break :blk .{ .pos = s.pos, .vel = s.vel, .clock_bias_s = g.clock.bias(t), .clock_drift = g.clock.drift(t), .rel_s = 0 };
        },
        .precise => |h| h.state(t),
    };
}
