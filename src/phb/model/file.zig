const records = @import("domain/navigation/records");
const precise = @import("domain/navigation/precise/product");
const antenna = @import("domain/navigation/antenna/catalog");
const trajectory = @import("domain/trajectory/trajectory");
const systems = @import("simulation/model/systems");
const publications = @import("simulation/model/publications");
const prepared_messages = @import("simulation/model/prepared_messages");
const plan = @import("phb/model/plan");
const names = @import("phb/model/names");
const Leap = @import("domain/time/civil").Leap;
const Config = @import("simulation/model/config").Config;

/// Canonical input facts and pack's choices. Runtime indexes and prepared message blocks are derived.
pub const File = struct {
    config: Config,
    knots: []const trajectory.Knot,
    ephemerides: records.Ephemerides,
    antennas: []const antenna.Antenna,
    precise: ?precise.Data,
    leap: Leap,
    plan: plan.PlanChoices,
    almanacs: ?prepared_messages.StoredAlmanacs,
    systems: systems.Stored,
    publications: publications.Publications,
    names: names.Names,
};
