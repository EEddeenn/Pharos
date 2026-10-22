const binding = @import("simulation/tracking/binding");
const tracking = @import("simulation/tracking/track");
const message_content = @import("domain/messages/content");
const flight = @import("simulation/model/flight_plan");
const kepler_parameters = @import("domain/navigation/orbit/parameters");
const gnss_types = @import("domain/gnss_types");
const corrections = @import("products/run/services/corrections");

const GpsTime = @import("domain/time/gps").GpsTime;

pub const Source = struct {
    ephemerides: binding.Inputs,
    scale: gnss_types.System,
    satellites: [256]tracking.Track = @splat(.{}),

    // A frame the run starts inside of is made from the state at the start: nothing is known before it.
    pub fn notBefore(self: *const Source, t: GpsTime) GpsTime {
        return if (t.lessThan(self.ephemerides.flight_plan.start)) self.ephemerides.flight_plan.start else t;
    }

    /// What a satellite's corrected family carries on the leg in force at `t`.
    pub fn contentAt(self: *const Source, sat: gnss_types.SatId, family: gnss_types.NavFamily, t: GpsTime) ?*const message_content.Content {
        return self.ephemerides.flight_plan.contentAt(sat, family, self.notBefore(t));
    }

    pub fn bindingStartAt(self: *const Source, sat: gnss_types.SatId, t: GpsTime) ?flight.LegId {
        return self.ephemerides.flight_plan.bindingStartAt(sat, self.notBefore(t));
    }

    pub fn correctionAgainst(self: *Source, sat: gnss_types.SatId, reference: *const kepler_parameters.Parameters, t: GpsTime, relativity: corrections.Relativity) ?corrections.Correction {
        const at = self.notBefore(t);
        return corrections.against(self.trackAt(sat, at), reference, at, relativity, self.ephemerides.flight_plan.scaleOffset(self.scale, at));
    }

    fn trackAt(self: *Source, sat: gnss_types.SatId, t: GpsTime) *tracking.Track {
        const slot = &self.satellites[sat.key()];
        _ = slot.advanceTo(self.ephemerides, sat, t);
        return slot;
    }
};
