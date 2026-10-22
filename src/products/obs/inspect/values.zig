const std = @import("std");
const records = @import("domain/navigation/records");

const GpsTime = @import("domain/time/gps").GpsTime;
const Parameters = @import("domain/navigation/orbit/parameters").Parameters;

pub const Availability = enum { available, unavailable, not_applicable, disabled };

pub const Reason = enum {
    no_samples,
    signal_not_enabled,
    satellite_not_broadcast,
    no_navigation_record,
    no_available_record,
    unrepresentable_parameters,
    missing_utc,
    missing_eop,
    missing_time_offset,
    signal_has_no_pilot,
    ionosphere_not_resolved,
    system_not_enabled,
    ionosphere_disabled,
    accuracy_not_stated,
    no_active_publication,
    publication_not_yet_valid,
    publication_expired,
    family_has_no_publications,
    service_not_enabled,
    correction_payload_not_inspected,
    service_only,
};

pub const ExactInt = struct {
    value: i64,

    pub fn jsonStringify(self: ExactInt, writer: anytype) !void {
        var buffer: [21]u8 = undefined;
        try writer.write(std.mem.print(&buffer, "{d}", .{self.value}) catch unreachable);
    }
};

pub const Instant = struct {
    gps_ms: ExactInt,
    sub_ms: f64,
    units: @TypeOf(unit_values) = unit_values,

    const unit_values = .{ .gps_ms = "ms since GPS epoch", .sub_ms = "ms" };

    pub fn of(t: GpsTime) Instant {
        return .{ .gps_ms = .{ .value = t.ms }, .sub_ms = t.sub_ms };
    }
};

pub const Interval = struct {
    from_epoch_ms: ExactInt,
    until_epoch_ms: ExactInt,
    from_epoch_sub_ms: f64,
    until_epoch_sub_ms: f64,
    units: @TypeOf(unit_values) = unit_values,

    const unit_values = .{ .from_epoch_ms = "ms", .until_epoch_ms = "ms", .from_epoch_sub_ms = "ms", .until_epoch_sub_ms = "ms" };

    pub fn of(start: GpsTime, from: GpsTime, until: GpsTime) Interval {
        const from_fraction = from.sub_ms - start.sub_ms;
        const until_fraction = until.sub_ms - start.sub_ms;
        const from_carry: i64 = @intFromFloat(@floor(from_fraction));
        const until_carry: i64 = @intFromFloat(@floor(until_fraction));
        return .{
            .from_epoch_ms = .{ .value = from.ms - start.ms + from_carry },
            .until_epoch_ms = .{ .value = until.ms - start.ms + until_carry },
            .from_epoch_sub_ms = from_fraction - @as(f64, @floatFromInt(from_carry)),
            .until_epoch_sub_ms = until_fraction - @as(f64, @floatFromInt(until_carry)),
        };
    }
};

pub const Orbit = struct {
    mean_anomaly_rad: f64,
    mean_motion_delta_rad_per_s: f64,
    mean_motion_delta_rate_rad_per_s2: f64,
    eccentricity: f64,
    sqrt_semi_major_axis_sqrt_m: f64,
    semi_major_axis_rate_m_per_s: f64,
    ascending_node_rad: f64,
    inclination_rad: f64,
    argument_of_perigee_rad: f64,
    ascending_node_rate_rad_per_s: f64,
    inclination_rate_rad_per_s: f64,
    cuc_rad: f64,
    cus_rad: f64,
    crc_m: f64,
    crs_m: f64,
    cic_rad: f64,
    cis_rad: f64,
    clock_af0_s: f64,
    clock_af1_s_per_s: f64,
    clock_af2_s_per_s2: f64,
    units: @TypeOf(unit_values) = unit_values,

    const unit_values = .{
        .mean_anomaly_rad = "rad",
        .mean_motion_delta_rad_per_s = "rad/s",
        .mean_motion_delta_rate_rad_per_s2 = "rad/s^2",
        .eccentricity = "1",
        .sqrt_semi_major_axis_sqrt_m = "sqrt(m)",
        .semi_major_axis_rate_m_per_s = "m/s",
        .ascending_node_rad = "rad",
        .inclination_rad = "rad",
        .argument_of_perigee_rad = "rad",
        .ascending_node_rate_rad_per_s = "rad/s",
        .inclination_rate_rad_per_s = "rad/s",
        .cuc_rad = "rad",
        .cus_rad = "rad",
        .crc_m = "m",
        .crs_m = "m",
        .cic_rad = "rad",
        .cis_rad = "rad",
        .clock_af0_s = "s",
        .clock_af1_s_per_s = "s/s",
        .clock_af2_s_per_s2 = "s/s^2",
    };

    pub fn of(p: Parameters) Orbit {
        return .{
            .mean_anomaly_rad = p.m0,
            .mean_motion_delta_rad_per_s = p.delta_n,
            .mean_motion_delta_rate_rad_per_s2 = p.delta_n_dot,
            .eccentricity = p.ecc,
            .sqrt_semi_major_axis_sqrt_m = p.sqrt_a,
            .semi_major_axis_rate_m_per_s = p.a_dot,
            .ascending_node_rad = p.omega0,
            .inclination_rad = p.i0,
            .argument_of_perigee_rad = p.w,
            .ascending_node_rate_rad_per_s = p.omega_dot,
            .inclination_rate_rad_per_s = p.idot,
            .cuc_rad = p.cuc,
            .cus_rad = p.cus,
            .crc_m = p.crc,
            .crs_m = p.crs,
            .cic_rad = p.cic,
            .cis_rad = p.cis,
            .clock_af0_s = p.af0,
            .clock_af1_s_per_s = p.af1,
            .clock_af2_s_per_s2 = p.af2,
        };
    }
};

pub const GlonassOrbit = struct {
    position_ecef_m: [3]f64,
    velocity_ecef_m_per_s: [3]f64,
    acceleration_ecef_m_per_s2: [3]f64,
    gamma_n_s_per_s: f64,
    tau_n_s: f64,
    units: @TypeOf(unit_values) = unit_values,

    const unit_values = .{ .position_ecef_m = "m", .velocity_ecef_m_per_s = "m/s", .acceleration_ecef_m_per_s2 = "m/s^2", .gamma_n_s_per_s = "s/s", .tau_n_s = "s" };

    pub fn of(e: *const records.GlonassEphemeris) GlonassOrbit {
        return .{ .position_ecef_m = e.pos, .velocity_ecef_m_per_s = e.vel, .acceleration_ecef_m_per_s2 = e.acc, .gamma_n_s_per_s = e.gamma_n, .tau_n_s = e.tau_n };
    }
};
