const std = @import("std");
const binding = @import("simulation/tracking/binding");
const trajectory = @import("domain/trajectory/trajectory");
const gnss_types = @import("domain/gnss_types");
const publication_config = @import("simulation/model/publications");
const configuration = @import("simulation/model/config");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const served_signals = @import("products/run/services/served_signals");
const cnav_message = @import("domain/messages/galileo/cnav");
const ppp_messages = @import("domain/messages/bds/ppp_b2b/encode");
const augmentation = @import("domain/messages/bds/d1d2/augmentation");
const differential = @import("domain/messages/gps/differential");
const set = @import("simulation/state/messages");
const has = @import("products/run/services/has");
const ppp_b2b = @import("products/run/services/ppp_b2b");
const d2 = @import("products/run/services/d2");
const dc = @import("products/run/services/gps_dc");

const ServicePlan = @import("simulation/model/services").ServicePlan;
const Payload = @import("domain/signals/payload").Payload;
const GpsTime = @import("domain/time/gps").GpsTime;

pub const Inputs = struct {
    ephemerides: binding.Inputs,
    trajectory: *const trajectory.Trajectory,
    start: GpsTime,
    signals: std.EnumSet(gnss_types.Signal),
    publications: *const publication_config.Prepared,
    plan: ServicePlan,
    has: ?configuration.Has,
    ppp_b2b: ?configuration.PppB2b,
};

pub const Streams = struct {
    has: ?*has.Stream = null,
    ppp_b2b: ?*ppp_b2b.Stream = null,
    d2: ?*d2.Stream = null,
    dc: ?*dc.Stream = null,

    pub fn init(gpa: std.mem.Allocator, input: Inputs, payload: *const Payload, bds_model: *const ionosphere_model.Model) error{OutOfMemory}!Streams {
        const served: served_signals.Served = .{ .signals = input.signals, .payload = payload };
        var out: Streams = .{};
        errdefer out.deinit(gpa);
        if (input.plan.runs(.has)) {
            const config = input.has.?;
            const s = try gpa.create(has.Stream);
            s.init(input.ephemerides, input.start, served, config);
            out.has = s;
        }
        if (input.plan.runs(.ppp_b2b)) {
            const config = input.ppp_b2b.?;
            const s = try gpa.create(ppp_b2b.Stream);
            s.init(input.ephemerides, input.start, served, config);
            out.ppp_b2b = s;
        }
        if (input.plan.runs(.d2)) {
            const s = try gpa.create(d2.Stream);
            s.init(input.ephemerides, input.start, input.trajectory, input.publications.d2, bds_model);
            out.d2 = s;
        }
        if (input.plan.runs(.gps_differential)) {
            const s = try gpa.create(dc.Stream);
            s.init(input.ephemerides, input.start);
            out.dc = s;
        }
        return out;
    }

    pub fn deinit(self: *Streams, gpa: std.mem.Allocator) void {
        if (self.has) |s| gpa.destroy(s);
        if (self.ppp_b2b) |s| gpa.destroy(s);
        if (self.d2) |s| gpa.destroy(s);
        if (self.dc) |s| gpa.destroy(s);
        self.* = .{};
    }

    pub fn reset(self: *Streams) void {
        if (self.has) |s| s.reset();
        if (self.ppp_b2b) |s| s.reset();
        if (self.d2) |s| s.reset();
        if (self.dc) |s| s.reset();
    }

    pub fn advanceTo(self: *Streams, end: GpsTime) void {
        const t = end.addMs(publication_config.lookahead_ms);
        if (self.has) |s| s.advanceTo(t);
        if (self.ppp_b2b) |s| s.advanceTo(t);
        if (self.d2) |s| s.advanceTo(t);
        if (self.dc) |s| s.advanceTo(t);
    }

    pub fn suppliers(self: *const Streams) set.Suppliers {
        return .{
            .has = if (self.has) |s| cnav_message.PageSource.of(has.Stream, s) else null,
            .ppp_b2b = if (self.ppp_b2b) |s| ppp_messages.MessageSource.of(ppp_b2b.Stream, s) else null,
            .d2 = if (self.d2) |s| augmentation.Source.of(d2.Stream, s) else null,
            .dc = if (self.dc) |s| differential.Source.of(dc.Stream, s) else null,
        };
    }
};
