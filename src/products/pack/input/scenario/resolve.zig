const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const ionosphere_config = @import("simulation/model/ionosphere");
const request_model = @import("products/pack/input/scenario/request");
const selection = @import("simulation/model/signals");
const quantize = @import("domain/messages/fields/ionosphere");
const klobuchar_model = @import("domain/propagation/ionosphere/klobuchar");
const Request = request_model.Request;
const Config = @import("simulation/model/config").Config;
const Diagnostics = @import("base/diagnostics").Diagnostics;

const Error = std.mem.Allocator.Error || error{ MissingIonoParameters, MissingGalileoIonoParameters, MissingBdsIonoParameters };

pub fn resolve(request: *const Request, iono: ionosphere_model.SuppliedCoefficients, epochs: u64, diags: *Diagnostics) Error!Config {
    return .{
        .start = request.start,
        .duration_ms = request.duration_ms orelse epochs,
        .has = request.has,
        .ppp_b2b = request.ppp_b2b,
        .ionosphere = if (request.samples != null or request.observation != null) .{ .ready = try resolveIonosphere(request, iono, diags) } else .inactive,
        .signals = request.signals,
        .elevation_mask_rad = request.elevation_mask_rad,
        .mask_out = request.mask_out,
        .samples = request.samples,
        .observation = request.observation,
        .position = request.position,
        .power = request.power,
    };
}

fn resolveIonosphere(request: *const Request, navigation: ionosphere_model.SuppliedCoefficients, diags: *Diagnostics) Error!ionosphere_config.Resolved {
    const block = request.ionosphere;
    var sets = navigation;
    switch (block) {
        .klobuchar => |c| sets.klobuchar = c orelse sets.klobuchar,
        .bds_klobuchar => |c| sets.bds_klobuchar = c orelse sets.bds_klobuchar,
        .nequick => |c| sets.nequick = c orelse sets.nequick,
        .bdgim => |c| sets.bdgim = c orelse sets.bdgim,
        .auto, .none => {},
    }
    const klobuchar = sets.klobuchar orelse klobuchar_model.Model.default_broadcast;
    const gps: ionosphere_config.Applied = .{
        .model = .klobuchar,
        .source = if (sets.klobuchar != null) .navigation else .built_in,
    };
    var resolved: ionosphere_config.Resolved = .{
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
        var enabled = selection.systems(request.signals).iterator();
        while (enabled.next()) |system| {
            const applied: ionosphere_config.Applied = switch (system) {
                .gps, .glo => gps,
                .gal => .{
                    .model = if (sets.nequick != null) .nequick else return error.MissingGalileoIonoParameters,
                    .source = .navigation,
                },
                .bds => .{
                    // The model the listed signals carry, BDGIM in B-CNAV1 to 3 and the BDS Klobuchar in D1/D2; the other one where the data lacks it.
                    .model = if (sets.bdgim != null and (carriesBdgim(request) or sets.bds_klobuchar == null))
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
        try canonicalize(&resolved, block, diags);
        return resolved;
    }
    const selected = block.model().model().?;
    switch (selected) {
        .klobuchar, .none => {},
        .bds_klobuchar => if (sets.bds_klobuchar == null) return error.MissingIonoParameters,
        .nequick => if (sets.nequick == null) return error.MissingIonoParameters,
        .bdgim => if (sets.bdgim == null) return error.MissingIonoParameters,
    }
    resolved.systems = std.EnumArray(gnss_types.System, ionosphere_config.Applied).initFill(.{
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
    try canonicalize(&resolved, block, diags);
    return resolved;
}

fn carriesBdgim(request: *const Request) bool {
    return selection.carries(request.signals, request.start, .bcnav1) or selection.carries(request.signals, request.start, .bcnav2) or selection.carries(request.signals, request.start, .bcnav3);
}

fn canonicalize(resolved: *ionosphere_config.Resolved, supplied: request_model.Ionosphere, diags: *Diagnostics) std.mem.Allocator.Error!void {
    const before = resolved.broadcast;
    resolved.broadcast = .{
        .klobuchar = quantize.klobuchar(before.klobuchar),
        .bds_klobuchar = quantize.klobuchar(before.bds_klobuchar),
        .nequick = if (before.nequick) |value| quantize.nequick(value) else null,
        .bdgim = if (before.bdgim) |value| quantize.bdgim(value) else null,
    };
    const changed = switch (supplied) {
        .klobuchar => |value| value != null and !std.meta.eql(before.klobuchar, resolved.broadcast.klobuchar),
        .bds_klobuchar => |value| value != null and !std.meta.eql(before.bds_klobuchar, resolved.broadcast.bds_klobuchar),
        .nequick => |value| value != null and !std.meta.eql(before.nequick, resolved.broadcast.nequick),
        .bdgim => |value| value != null and !std.meta.eql(before.bdgim, resolved.broadcast.bdgim),
        .auto, .none => false,
    };
    if (changed) try diags.warn(.ionosphere_rounded, "ionosphere.parameters", "the supplied coefficients were rounded to the units broadcast by their navigation messages", .{});
}
