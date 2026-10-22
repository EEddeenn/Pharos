const records = @import("domain/navigation/records");
const antenna = @import("domain/navigation/antenna/catalog");
const trajectory = @import("domain/trajectory/trajectory");
const flight_plan = @import("simulation/model/flight_plan");
const file = @import("phb/model/file");
const stored_plan = @import("phb/model/plan");
const names = @import("phb/model/names");
const PreparedScenario = @import("simulation/model/prepared_scenario").PreparedScenario;

/// Borrows the source facts and choices until the bundle's arena is released.
pub const Display = struct {
    ephemerides: records.Ephemerides,
    antennas: []const antenna.Antenna,
    names: names.Names,
    timelines: [flight_plan.satellite_count][]const stored_plan.Leg,

    pub fn fromFile(source: *const file.File) Display {
        return .{
            .ephemerides = source.ephemerides,
            .antennas = source.antennas,
            .names = source.names,
            .timelines = source.plan.timelines,
        };
    }

    pub fn choice(self: *const Display, id: flight_plan.LegId) *const stored_plan.Binding {
        return &self.timelines[flight_plan.slot(id.sat)][id.index].binding.?;
    }

    pub fn trajectoryValue(self: *const Display, prepared: *const PreparedScenario) trajectory.Trajectory {
        return .{ .name = self.names.trajectory_name, .knots = prepared.trajectory.knots };
    }
};
