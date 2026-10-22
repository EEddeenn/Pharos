const std = @import("std");
const flight_plan = @import("simulation/model/flight_plan");
const records = @import("domain/navigation/records");
const reference = @import("domain/navigation/reference");
const MessageChoice = @import("domain/messages/content").Choice;

pub const Binding = struct {
    reference: flight_plan.Ref,
    group_delay: records.GroupDelays = .{},
    sources: std.EnumMap(records.NavSource, u32) = .{},
    p1: u2 = 0,
    messages: []const MessageChoice = &.{},

    pub fn input(self: *const Binding, ephemerides: records.Ephemerides, attributes: *reference.Attributes) reference.Reference {
        attributes.* = .{};
        return switch (self.reference) {
            .kepler => |index| blk: {
                const selected = &ephemerides.kepler[index];
                for (std.enums.values(records.NavSource)) |source| if (self.sources.get(source)) |donor| attributes.put(reference.attributesOf(selected, &ephemerides.kepler[donor]), donor);
                break :blk .{ .kepler = .{ .record = selected, .group_delay = &self.group_delay, .attributes = attributes } };
            },
            .glonass => |index| .{ .glonass = .{ .record = &ephemerides.glonass[index], .group_delay = &self.group_delay } },
        };
    }

    pub fn sameSelection(self: *const Binding, other: *const Binding) bool {
        if (!self.sameBase(other)) return false;
        for (std.enums.values(records.NavSource)) |source| if (self.sources.get(source) != other.sources.get(source)) return false;
        return true;
    }

    /// Numerical continuity ignores an equal-valued donor's identity. The fitted answer is not an input to this rule.
    pub fn sameValues(self: *const Binding, other: *const Binding, ephemerides: records.Ephemerides) bool {
        if (!self.sameBase(other)) return false;
        const selected = switch (self.reference) {
            .kepler => |index| &ephemerides.kepler[index],
            .glonass => return true,
        };
        for (std.enums.values(records.NavSource)) |source| {
            const left = self.sources.get(source);
            const right = other.sources.get(source);
            if (left == null or right == null) {
                if (left != right) return false;
                continue;
            }
            const a = reference.attributesOf(selected, &ephemerides.kepler[left.?]);
            const b = reference.attributesOf(selected, &ephemerides.kepler[right.?]);
            if (!std.meta.eql(a, b)) return false;
        }
        return true;
    }

    fn sameBase(self: *const Binding, other: *const Binding) bool {
        if (!std.meta.eql(self.reference, other.reference) or self.p1 != other.p1) return false;
        for (std.enums.values(records.GroupDelayTerm)) |term| if (self.group_delay.get(term) != other.group_delay.get(term)) return false;
        return true;
    }
};

pub const Leg = struct { from_ms: u64, binding: ?Binding };
pub const PlanChoices = struct { timelines: [flight_plan.satellite_count][]const Leg };
