pub const command = @import("bundle/command.zig");
pub const ionosphere = @import("bundle/ionosphere.zig");
pub const scenario = @import("bundle/scenario.zig");
pub const messages = @import("bundle/messages.zig");
pub const navigation = @import("bundle/navigation.zig");
pub const precise = @import("bundle/precise.zig");
pub const antex = @import("bundle/antex.zig");
pub const plan = @import("bundle/plan.zig");
pub const format = @import("bundle/format.zig");
const core = @import("core.zig");
const GpsTime = core.time.GpsTime;
const trajectory = @import("trajectory.zig");
const Trajectory = trajectory.Trajectory;

pub const Span = struct {
    start: GpsTime,
    epochs: u64,
    leap_seconds: i8,
    leap_seconds_after: i8,
    leap_change: ?GpsTime,
};

pub const Bundle = struct {
    scenario: scenario.Scenario,
    navigation: navigation.NavSet,
    plan: plan.Plan,
    trajectory: Trajectory,

    pub fn epochs(self: *const Bundle) u64 {
        return self.scenario.duration_ms;
    }

    pub fn span(self: *const Bundle) Span {
        const start = self.scenario.start;
        const length = self.epochs();
        const leap = self.plan.leap;
        const at_start = leap.atMs(start.ms).count;
        var out: Span = .{ .start = start, .epochs = length, .leap_seconds = at_start, .leap_seconds_after = at_start, .leap_change = null };
        if (leap.nextChange(start.ms + 1)) |change| if (change.at_ms - start.ms < length) {
            out.leap_seconds_after = change.count;
            out.leap_change = .{ .ms = change.at_ms };
        };
        return out;
    }

    pub fn validate(self: *const Bundle) ?[]const u8 {
        if (self.scenario.validate()) |why| return why;
        if (self.trajectory.invalid()) |bad| return trajectory.reason(bad.reason);
        if (self.scenario.duration_ms > self.trajectory.epochs()) return "the scenario's duration is longer than the trajectory";
        if (!self.plan.start.eql(self.scenario.start)) return "the plan does not start where the scenario does";
        if (self.plan.span_ms != self.epochs() + plan.grid_ms) return "the plan does not span the run and a minute";
        if (self.plan.validate(&self.navigation, &self.scenario)) |why| return why;
        return self.navigation.validate(self.plan.leap);
    }
};
