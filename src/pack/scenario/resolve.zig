const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const bundle = shared.bundle;
const ionosphere = bundle.ionosphere;
const Request = @import("request.zig").Request;

const Error = error{ MissingIonoParameters, MissingGalileoIonoParameters, MissingBdsIonoParameters };

pub fn resolve(request: *const Request, iono: core.iono.Broadcast, epochs: u64) Error!bundle.scenario.Scenario {
    return .{
        .name = request.name,
        .start = request.start,
        .trajectory_file = request.trajectory_file,
        .duration_ms = request.duration_ms orelse epochs,
        .nav_files = request.nav_files,
        .antenna = request.antenna,
        .precise = request.precise,
        .has = request.has,
        .ppp_b2b = request.ppp_b2b,
        .ionosphere = if (request.samples != null or request.observation != null) .{ .ready = try resolveIonosphere(request, iono) } else .inactive,
        .messages = request.messages,
        .signals = request.signals,
        .elevation_mask_rad = request.elevation_mask_rad,
        .mask_out = request.mask_out,
        .samples = request.samples,
        .observation = request.observation,
        .position = request.position,
        .power = request.power,
    };
}

fn resolveIonosphere(request: *const Request, navigation: core.iono.Broadcast) Error!ionosphere.Resolved {
    const block = request.ionosphere;
    var sets = navigation;
    switch (block) {
        .klobuchar => |c| sets.klobuchar = c orelse sets.klobuchar,
        .bds_klobuchar => |c| sets.bds_klobuchar = c orelse sets.bds_klobuchar,
        .nequick => |c| sets.nequick = c orelse sets.nequick,
        .bdgim => |c| sets.bdgim = c orelse sets.bdgim,
        .auto, .none => {},
    }
    const klobuchar = sets.klobuchar orelse core.iono.klobuchar.Model.default_broadcast;
    const gps: ionosphere.Applied = .{
        .model = .klobuchar,
        .source = if (sets.klobuchar != null) .navigation else .built_in,
    };
    var resolved: ionosphere.Resolved = .{
        .requested = block.model(),
        .systems = .initFill(.{ .model = .none, .source = .none }),
        .broadcast = .{
            .klobuchar = klobuchar,
            .bds_klobuchar = sets.bds_klobuchar orelse klobuchar,
            .nequick = sets.nequick,
            .bdgim = sets.bdgim,
        },
    };
    if (block == .auto) {
        var enabled = request.enabledSystems().iterator();
        while (enabled.next()) |system| {
            const applied: ionosphere.Applied = switch (system) {
                .gps, .glo => gps,
                .gal => .{
                    .model = if (sets.nequick != null) .nequick else return error.MissingGalileoIonoParameters,
                    .source = .navigation,
                },
                .bds => .{
                    .model = if (sets.bdgim != null)
                        .bdgim
                    else if (sets.bds_klobuchar != null)
                        .bds_klobuchar
                    else
                        return error.MissingBdsIonoParameters,
                    .source = .navigation,
                },
            };
            resolved.systems.set(system, applied);
        }
        return resolved;
    }
    const selected = block.model().model().?;
    switch (selected) {
        .klobuchar, .none => {},
        .bds_klobuchar => if (sets.bds_klobuchar == null) return error.MissingIonoParameters,
        .nequick => if (sets.nequick == null) return error.MissingIonoParameters,
        .bdgim => if (sets.bdgim == null) return error.MissingIonoParameters,
    }
    resolved.systems = std.EnumArray(core.types.System, ionosphere.Applied).initFill(.{
        .model = selected,
        .source = if (block == .none)
            .none
        else if (block.given())
            .scenario
        else if (block == .klobuchar and sets.klobuchar == null)
            .built_in
        else
            .navigation,
    });
    return resolved;
}
