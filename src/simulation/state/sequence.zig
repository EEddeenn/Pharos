const std = @import("std");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const flight = @import("simulation/model/flight_plan");
const messages = @import("simulation/state/messages");
const channels = @import("simulation/state/channels");
const gnss_types = @import("domain/gnss_types");
const MessageInputs = @import("simulation/state/messages/inputs").Inputs;

const GpsTime = time.GpsTime;
const NavFamily = gnss_types.NavFamily;

pub const Due = struct { at: GpsTime, families: std.EnumSet(NavFamily) };

pub const Window = struct { from: GpsTime, until: GpsTime };

pub const Inputs = struct {
    navigation: MessageInputs,
    start: GpsTime,
    families: std.EnumSet(NavFamily),
};

pub const MessageSequence = struct {
    navigation: MessageInputs,
    start: GpsTime,
    kinds: std.EnumSet(NavFamily),
    suppliers: messages.Suppliers,
    sets: messages.Sets(Generations),
    current: std.EnumArray(NavFamily, u1) = .initFill(0),
    next: std.EnumArray(gnss_types.System, GpsTime) = undefined,

    pub fn init(gpa: std.mem.Allocator, input: Inputs, suppliers: messages.Suppliers) error{OutOfMemory}!MessageSequence {
        var sets: messages.Sets(Generations) = .{};
        errdefer freeSets(gpa, sets);
        inline for (comptime std.enums.values(NavFamily)) |family| {
            if (input.families.contains(family)) @field(sets, @tagName(family)) = try gpa.create([2]messages.Set(family));
        }
        var out: MessageSequence = .{ .navigation = input.navigation, .start = input.start, .kinds = input.families, .suppliers = suppliers, .sets = sets };
        out.reset();
        return out;
    }

    pub fn deinit(self: *MessageSequence, gpa: std.mem.Allocator) void {
        freeSets(gpa, self.sets);
    }

    pub fn reset(self: *MessageSequence) void {
        self.current = .initFill(0);
        for (gnss_types.System.all) |system| self.next.set(system, flight.nextLegBoundary(system, self.start, self.navigation.flight_plan.leap));
        self.build(self.kinds, self.start);
    }

    pub fn due(self: *MessageSequence, to: GpsTime) ?Due {
        var at: ?GpsTime = null;
        var it = self.kinds.iterator();
        while (it.next()) |family| {
            const t = self.next.get(family.system());
            if (to.lessThan(t)) continue;
            if (at == null or t.lessThan(at.?)) at = t;
        }
        const when = at orelse return null;
        var families = std.EnumSet(NavFamily).empty;
        it = self.kinds.iterator();
        while (it.next()) |family| if (self.next.get(family.system()).eql(when)) families.insert(family);
        for (gnss_types.System.all) |system| {
            if (self.next.get(system).eql(when)) self.next.set(system, flight.nextLegBoundary(system, when, self.navigation.flight_plan.leap));
        }
        return .{ .at = when, .families = families };
    }

    // Whether a leg boundary of a listed family's system falls in [from, until), past the boundaries already due.
    pub fn dueWithin(self: *const MessageSequence, from: GpsTime, until: GpsTime) bool {
        var it = self.kinds.iterator();
        while (it.next()) |family| {
            const system = family.system();
            var at = self.next.get(system);
            while (at.lessThan(from)) at = flight.nextLegBoundary(system, at, self.navigation.flight_plan.leap);
            if (at.lessThan(until)) return true;
        }
        return false;
    }

    pub fn refresh(self: *MessageSequence, d: Due) void {
        self.build(d.families, d.at);
    }

    pub fn currentSets(self: *const MessageSequence) messages.SetView {
        var snap: messages.SetView = .{};
        inline for (comptime std.enums.values(NavFamily)) |family| {
            if (@field(self.sets, @tagName(family))) |pair| @field(snap, @tagName(family)) = &pair[self.current.get(family)];
        }
        return snap;
    }

    fn build(self: *MessageSequence, families: std.EnumSet(NavFamily), t: GpsTime) void {
        inline for (comptime std.enums.values(NavFamily)) |family| {
            if (families.contains(family)) {
                const next = self.current.get(family) ^ 1;
                @field(self.sets, @tagName(family)).?[next] = messages.initSet(family, self.navigation, self.suppliers, t);
                self.current.set(family, next);
            }
        }
    }
};

pub fn inspectionWindowAt(start: GpsTime, leap: civil.Leap, system: gnss_types.System, t: GpsTime) Window {
    const window = windowAt(start, leap, system, t);
    const from = channels.replanOnOrAfter(.{ .ms = @intCast(window.from.ms - start.ms) });
    const until = channels.replanOnOrAfter(.{ .ms = @intCast(window.until.ms - start.ms) });
    return .{ .from = time.atEpoch(start, from), .until = time.atEpoch(start, until) };
}

fn Generations(comptime S: type) type {
    return ?*[2]S;
}

fn windowAt(start: GpsTime, leap: civil.Leap, system: gnss_types.System, t: GpsTime) Window {
    var from = start;
    var until = flight.nextLegBoundary(system, from, leap);
    while (!t.lessThan(until)) {
        from = until;
        until = flight.nextLegBoundary(system, from, leap);
    }
    return .{ .from = from, .until = until };
}

fn freeSets(gpa: std.mem.Allocator, sets: messages.Sets(Generations)) void {
    inline for (comptime std.enums.values(NavFamily)) |family| {
        if (@field(sets, @tagName(family))) |pair| gpa.destroy(pair);
    }
}
