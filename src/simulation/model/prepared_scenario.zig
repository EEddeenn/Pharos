const GpsTime = @import("domain/time/gps").GpsTime;
const Leap = @import("domain/time/civil").Leap;
const Config = @import("simulation/model/config").Config;
const FlightPlan = @import("simulation/model/flight_plan").FlightPlan;
const PreparedMessages = @import("simulation/model/prepared_messages").PreparedMessages;
const ServicePlan = @import("simulation/model/services").ServicePlan;
const Product = @import("domain/navigation/precise/product").Product;
const PhaseCentres = @import("domain/navigation/antenna/phase_centre").PhaseCentres;
const Payload = @import("domain/signals/payload").Payload;
const Trajectory = @import("domain/trajectory/trajectory").Trajectory;

pub const Span = struct {
    start: GpsTime,
    epochs: u64,
    leap_seconds: i8,
    leap_seconds_after: i8,
    leap_change: ?GpsTime,

    pub fn of(start: GpsTime, epochs: u64, leap: Leap) Span {
        const at_start = leap.atMs(start.ms).count;
        var out: Span = .{ .start = start, .epochs = epochs, .leap_seconds = at_start, .leap_seconds_after = at_start, .leap_change = null };
        if (leap.nextChange(start.ms + 1)) |change| if (change.at_ms - start.ms < epochs) {
            out.leap_seconds_after = change.count;
            out.leap_change = .{ .ms = change.at_ms };
        };
        return out;
    }
};

pub const PreparedScenario = struct {
    config: Config,
    trajectory: Trajectory,
    flight_plan: FlightPlan,
    messages: ?PreparedMessages,
    services: ServicePlan,
    precise: ?*const Product,
    phase_centres: PhaseCentres,
    payload: Payload,

    pub fn epochs(self: *const PreparedScenario) u64 {
        return self.config.duration_ms;
    }

    pub fn span(self: *const PreparedScenario) Span {
        return .of(self.config.start, self.epochs(), self.flight_plan.leap);
    }
};
