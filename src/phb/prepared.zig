const PreparedScenario = @import("simulation/model/prepared_scenario").PreparedScenario;
const Display = @import("phb/model/display").Display;

pub const PreparedBundle = struct { scenario: PreparedScenario, display: Display };
