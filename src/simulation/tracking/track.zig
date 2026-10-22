const std = @import("std");
const civil = @import("domain/time/civil");
const flight = @import("simulation/model/flight_plan");
const precise = @import("domain/navigation/precise/product");
const signal_catalog = @import("domain/signals/catalog");
const air = @import("domain/navigation/air");
const delay = @import("domain/navigation/group_delay");
const phase_centres = @import("domain/navigation/antenna/phase_centre");
const gnss_types = @import("domain/gnss_types");
const coordinates = @import("domain/earth/coordinates");
const binding = @import("simulation/tracking/binding");

const GpsTime = @import("domain/time/gps").GpsTime;

const blend_s: f64 = 600;
const knot_span_s: f64 = 1;
const light_time_s: f64 = 1;

pub const Cursor = struct {
    system: gnss_types.System,
    leap: civil.Leap,
    grid: GpsTime,
    leg: GpsTime,

    pub fn init(system: gnss_types.System, start: GpsTime, leap: civil.Leap) Cursor {
        return .{ .system = system, .leap = leap, .grid = start, .leg = start };
    }

    pub fn peek(self: *const Cursor) GpsTime {
        return if (self.leg.lessThan(self.grid)) self.leg else self.grid;
    }

    pub fn next(self: *Cursor, t: GpsTime) ?GpsTime {
        const at = self.peek();
        if (t.lessThan(at)) return null;
        if (self.grid.eql(at)) self.grid = flight.nextLegBoundary(.gps, at, self.leap);
        if (self.leg.eql(at)) self.leg = flight.nextLegBoundary(self.system, at, self.leap);
        return at;
    }
};

pub const Advance = struct { refreshed: bool = false, switched: bool = false };

pub const State = precise.State;

const Residual = struct {
    pos: coordinates.Ecef,
    clock_bias_s: f64,
    rel_s: f64,
};

const DelayTable = struct {
    terms: [signal_catalog.max_per_system]std.EnumArray(gnss_types.Component, f64) = @splat(.initFill(0)),
    shift_s: f64 = 0,
};

pub const Delays = struct {
    air: []const air.Row,
    freq: ?gnss_types.FreqId,
    shift_s: f64,
    transition: ?struct { weight: f64, from: DelayTable } = null,

    pub fn term(self: *const Delays, signal: gnss_types.Signal, component: gnss_types.Component) f64 {
        const now = self.air[signal_catalog.slot(signal)].delay_s.get(component);
        const t = self.transition orelse return now;
        return now + (t.from.terms[signal_catalog.slot(signal)].get(component) - now) * t.weight;
    }

    pub fn shift(self: *const Delays) f64 {
        const t = self.transition orelse return self.shift_s;
        return self.shift_s + (t.from.shift_s - self.shift_s) * t.weight;
    }

    pub fn code(self: *const Delays, signal: gnss_types.Signal, component: gnss_types.Component) f64 {
        return self.term(signal, component) - self.shift();
    }

    pub fn carrier(self: *const Delays, signal: gnss_types.Signal) f64 {
        const c = delay.carrierCode(signal);
        return self.code(c.signal, c.component);
    }

    pub fn carrierTerm(self: *const Delays, signal: gnss_types.Signal) f64 {
        const c = delay.carrierCode(signal);
        return self.term(c.signal, c.component);
    }
};

const DelayTransition = struct { from: DelayTable, until: GpsTime };

pub const DelaySnapshot = struct {
    air: []const air.Row,
    freq: ?gnss_types.FreqId,
    shift_s: f64,
    transition: ?DelayTransition,

    pub fn at(self: *const DelaySnapshot, t: GpsTime) Delays {
        var out: Delays = .{ .air = self.air, .freq = self.freq, .shift_s = self.shift_s };
        if (self.transition) |transition| {
            const remaining = transition.until.secondsSince(t);
            if (remaining > 0) out.transition = .{ .weight = remaining / blend_s, .from = transition.from };
        }
        return out;
    }
};

const Resolved = struct { t: GpsTime, span: binding.Span };
const Current = struct { selection: binding.ResolvedBinding, at: Resolved };
const OrbitTransition = struct { previous: Current, residual: ?Residual, until: GpsTime };
const OrbitMark = struct { previous: Resolved, residual: ?Residual, until: GpsTime };

pub const Mark = struct {
    current: ?Resolved,
    orbit_transition: ?OrbitMark,
    delay_transition: ?DelayTransition,
    cursor: ?Cursor,
};

pub const Track = struct {
    current: ?Current = null,
    orbit_transition: ?OrbitTransition = null,
    delay_transition: ?DelayTransition = null,
    cursor: ?Cursor = null,

    pub fn mark(self: *const Track) Mark {
        return .{
            .current = if (self.current) |current| current.at else null,
            .orbit_transition = if (self.orbit_transition) |transition| .{ .previous = transition.previous.at, .residual = transition.residual, .until = transition.until } else null,
            .delay_transition = self.delay_transition,
            .cursor = self.cursor,
        };
    }

    pub fn restore(input: binding.Inputs, sat: gnss_types.SatId, m: Mark) Track {
        return .{
            .current = if (m.current) |at| restoreCurrent(input, sat, at) else null,
            .orbit_transition = if (m.orbit_transition) |transition| .{ .previous = restoreCurrent(input, sat, transition.previous), .residual = transition.residual, .until = transition.until } else null,
            .delay_transition = m.delay_transition,
            .cursor = m.cursor,
        };
    }

    pub fn advanceTo(self: *Track, input: binding.Inputs, sat: gnss_types.SatId, t: GpsTime) Advance {
        var cursor = self.cursor orelse Cursor.init(sat.system, input.flight_plan.start, input.flight_plan.leap);
        var out: Advance = .{};
        while (cursor.next(t)) |at| {
            out.refreshed = true;
            if (self.refresh(input, sat, at, servingSpan(at, cursor.peek()))) out.switched = true;
        }
        self.cursor = cursor;
        return out;
    }

    pub fn nextInstant(self: *const Track, flight_plan: *const flight.FlightPlan, sat: gnss_types.SatId) GpsTime {
        const cursor = self.cursor orelse Cursor.init(sat.system, flight_plan.start, flight_plan.leap);
        return cursor.peek();
    }

    pub fn stateAt(self: *Track, t: GpsTime) State {
        var out = propagate(&self.current.?.selection.source, t);
        if (self.orbit_transition) |*transition| {
            const remaining = transition.until.secondsSince(t);
            if (remaining > 0) {
                const w = remaining / blend_s;
                var old = propagate(&transition.previous.selection.source, t);
                if (transition.residual) |d| {
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
            }
        }
        return out;
    }

    pub fn phaseCentre(self: *const Track) ?*const phase_centres.PhaseCentre {
        const selection = &self.current.?.selection;
        return if (selection.phase_centre) |*centre| centre else null;
    }

    pub fn delaySnapshot(self: *const Track) DelaySnapshot {
        const selection = self.current.?.selection;
        return .{ .air = selection.binding.air, .freq = selection.binding.freq, .shift_s = selection.delayShift(), .transition = self.delay_transition };
    }

    pub fn delaysAt(self: *const Track, t: GpsTime) Delays {
        return self.delaySnapshot().at(t);
    }

    fn restoreCurrent(input: binding.Inputs, sat: gnss_types.SatId, at: Resolved) Current {
        return .{ .selection = binding.resolve(input, sat, at.t, at.span).?, .at = at };
    }

    fn refresh(self: *Track, input: binding.Inputs, sat: gnss_types.SatId, t: GpsTime, span: binding.Span) bool {
        const next = binding.resolve(input, sat, t, span) orelse {
            self.* = .{ .cursor = self.cursor };
            return false;
        };
        const at: Resolved = .{ .t = t, .span = span };
        const current = self.current orelse {
            self.current = .{ .selection = next, .at = at };
            return false;
        };
        const before = current.selection;
        const switched = !before.sameSource(next);
        if (switched or !sameDelays(before.binding.air, next.binding.air) or before.delayShift() != next.delayShift()) {
            self.delay_transition = .{ .from = self.tableAt(t), .until = t.addSeconds(blend_s) };
            if (switched) {
                const residual = self.residualAt(t);
                self.orbit_transition = .{ .previous = current, .residual = residual, .until = t.addSeconds(blend_s) };
            }
        }
        self.current = .{ .selection = next, .at = at };
        return switched;
    }

    fn tableAt(self: *const Track, t: GpsTime) DelayTable {
        const d = self.delaysAt(t);
        const system = self.current.?.selection.leg.sat.system;
        var table: DelayTable = .{ .shift_s = d.shift() };
        for (std.enums.values(gnss_types.Signal)) |signal| {
            if (signal.system() != system) continue;
            for (std.enums.values(gnss_types.Component)) |component| table.terms[signal_catalog.slot(signal)].set(component, d.term(signal, component));
        }
        return table;
    }

    fn residualAt(self: *Track, t: GpsTime) ?Residual {
        const transition = self.orbit_transition orelse return null;
        if (!(transition.until.secondsSince(t) > 0)) return null;
        const blended = self.stateAt(t);
        const now = propagate(&self.current.?.selection.source, t);
        return .{
            .pos = blended.pos.sub(now.pos),
            .clock_bias_s = blended.clock_bias_s - now.clock_bias_s,
            .rel_s = blended.rel_s - now.rel_s,
        };
    }
};

pub fn productServes(product: *const precise.Product, sat: gnss_types.SatId, at: GpsTime, leap: civil.Leap) bool {
    var cursor: Cursor = .init(sat.system, at, leap);
    _ = cursor.next(at);
    const span = servingSpan(at, cursor.peek());
    return product.serves(sat, span.from, span.until);
}

fn servingSpan(at: GpsTime, next: GpsTime) binding.Span {
    return .{ .from = at.addSeconds(-(knot_span_s + light_time_s)), .until = next.addSeconds(knot_span_s) };
}

fn sameDelays(a: []const air.Row, b: []const air.Row) bool {
    for (a, b) |x, y| if (!std.meta.eql(x.delay_s, y.delay_s)) return false;
    return true;
}

fn propagate(source: *binding.Source, t: GpsTime) State {
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
