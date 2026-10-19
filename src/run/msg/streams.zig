const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const bundle = @import("shared").bundle;
const GpsTime = core.time.GpsTime;
const set = @import("shared").stage.messages;
const has = @import("streams/has.zig");
const ppp_b2b = @import("streams/ppp_b2b.zig");
const d2 = @import("streams/d2.zig");
const dc = @import("streams/dc.zig");

pub const Streams = struct {
    has: ?*has.Stream = null,
    ppp_b2b: ?*ppp_b2b.Stream = null,
    d2: ?*d2.Stream = null,
    dc: ?*dc.Stream = null,

    pub fn init(gpa: std.mem.Allocator, b: *const bundle.Bundle, payload: *const gnss.payload.Payload, messages: set.Messages, bds_model: *const core.iono.Model) error{OutOfMemory}!Streams {
        const scenario = &b.scenario;
        var out: Streams = .{};
        errdefer out.deinit(gpa);
        if (scenario.has) |config| if (scenario.signals.contains(.e6)) {
            const s = try gpa.create(has.Stream);
            s.init(b, payload, config);
            out.has = s;
        };
        if (scenario.ppp_b2b) |config| if (scenario.signals.contains(.b2b)) {
            const s = try gpa.create(ppp_b2b.Stream);
            s.init(b, payload, config);
            out.ppp_b2b = s;
        };
        if (messages.d2.len > 0) {
            const s = try gpa.create(d2.Stream);
            s.init(b, payload, messages.d2, bds_model);
            out.d2 = s;
        }
        if (b.navigation.precise != null and declaresDifferential(scenario.messages.gps) and
            (scenario.carries(.cnav) or scenario.carries(.cnav2)))
        {
            const s = try gpa.create(dc.Stream);
            s.init(b);
            out.dc = s;
        }
        return out;
    }

    fn declaresDifferential(publications: []const gnss.gps.messages.Publication) bool {
        for (publications) |p| if (p.content.differential != null) return true;
        return false;
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

    const lookahead_ms = 2000;

    pub fn advanceTo(self: *Streams, end: GpsTime) void {
        const t = end.addMs(lookahead_ms);
        if (self.has) |s| s.advanceTo(t);
        if (self.ppp_b2b) |s| s.advanceTo(t);
        if (self.d2) |s| s.advanceTo(t);
        if (self.dc) |s| s.advanceTo(t);
    }

    pub fn sources(self: *const Streams) set.Sources {
        return .{
            .has = if (self.has) |s| gnss.galileo.cnav.PageSource.of(has.Stream, s) else null,
            .ppp_b2b = if (self.ppp_b2b) |s| gnss.bds.bcnav3.FrameSource.of(ppp_b2b.Stream, s) else null,
            .d2 = if (self.d2) |s| gnss.bds.d1d2.augmentation.Source.of(d2.Stream, s) else null,
            .dc = if (self.dc) |s| gnss.gps.dc.Source.of(dc.Stream, s) else null,
        };
    }
};
