const std = @import("std");
const shared = @import("shared");
const capi = shared.capi;
const pharos_traj = @import("pharos_traj");
const pharos_pack = @import("pharos_pack");
const pharos_run = @import("pharos_run");
const pharos_obs = @import("pharos_obs");

pub const Named = struct { type: type, name: []const u8 };
pub const Enum = struct { type: type, name: []const u8, prefix: []const u8 };
const Function = struct { name: []const u8, type: type };
pub const Product = struct {
    prefix: []const u8,
    common: type,
    modules: []const type,
    handles: []const Named,
    records: []const Named,
    enums: []const Enum,
};

pub const traj: Product = .{
    .prefix = "pharos_traj",
    .common = pharos_traj.capi.common,
    .modules = &.{ pharos_traj.capi.traj, pharos_traj.capi.geometry },
    .handles = &.{
        .{ .type = pharos_traj.capi.traj.Handle, .name = "pharos_traj" },
        .{ .type = pharos_traj.capi.geometry.GeometryDescription, .name = "pharos_traj_geometry" },
    },
    .records = &.{
        .{ .type = pharos_traj.capi.traj.Diag, .name = "pharos_traj_diag" },
        .{ .type = pharos_traj.capi.traj.Info, .name = "pharos_traj_info" },
        .{ .type = pharos_traj.capi.traj.State, .name = "pharos_traj_state" },
    },
    .enums = &.{
        .{ .type = shared.core.diagnostics.Severity, .name = "pharos_traj_severity", .prefix = "PHAROS_TRAJ_SEVERITY" },
        .{ .type = shared.core.diagnostics.Code, .name = "pharos_traj_diag_code", .prefix = "PHAROS_TRAJ_DIAG" },
    },
};

pub const pack: Product = .{
    .prefix = "pharos_pack",
    .common = pharos_pack.capi.common,
    .modules = &.{pharos_pack.capi.pack},
    .handles = &.{
        .{ .type = pharos_pack.capi.pack.Handle, .name = "pharos_pack" },
        .{ .type = pharos_pack.capi.pack.NavDescription, .name = "pharos_pack_nav_description" },
    },
    .records = &.{
        .{ .type = pharos_pack.capi.pack.Diag, .name = "pharos_pack_diag" },
        .{ .type = pharos_pack.capi.pack.File, .name = "pharos_pack_file" },
        .{ .type = pharos_pack.capi.pack.Coverage, .name = "pharos_pack_coverage" },
        .{ .type = pharos_pack.capi.pack.Info, .name = "pharos_pack_info" },
    },
    .enums = &.{
        .{ .type = shared.core.diagnostics.Severity, .name = "pharos_pack_severity", .prefix = "PHAROS_PACK_SEVERITY" },
        .{ .type = shared.core.diagnostics.Code, .name = "pharos_pack_diag_code", .prefix = "PHAROS_PACK_DIAG" },
        .{ .type = shared.core.types.System, .name = "pharos_pack_system", .prefix = "PHAROS_PACK_SYSTEM" },
        .{ .type = shared.core.types.IqFormat, .name = "pharos_pack_iq_format", .prefix = "PHAROS_PACK_FORMAT" },
        .{ .type = shared.bundle.scenario.PositionFormat, .name = "pharos_pack_position_format", .prefix = "PHAROS_PACK_POSITION" },
    },
};

pub const run: Product = .{
    .prefix = "pharos_run",
    .common = pharos_run.capi.common,
    .modules = &.{pharos_run.capi.run},
    .handles = &.{.{ .type = pharos_run.capi.run.Handle, .name = "pharos_run" }},
    .records = &.{
        .{ .type = pharos_run.capi.run.Options, .name = "pharos_run_options" },
        .{ .type = pharos_run.capi.run.Info, .name = "pharos_run_info" },
        .{ .type = pharos_run.capi.run.ManifestFields, .name = "pharos_run_manifest_fields" },
        .{ .type = capi.command.Command, .name = "pharos_run_command" },
        .{ .type = pharos_run.capi.convert.Applied, .name = "pharos_run_applied" },
        .{ .type = pharos_run.capi.run.Block, .name = "pharos_run_block" },
        .{ .type = pharos_run.capi.convert.Event, .name = "pharos_run_event" },
    },
    .enums = &.{
        .{ .type = pharos_run.engine.run.NoiseMode, .name = "pharos_run_noise", .prefix = "PHAROS_RUN_NOISE" },
        .{ .type = pharos_run.synth.gain.Mode, .name = "pharos_run_gain", .prefix = "PHAROS_RUN_GAIN" },
        .{ .type = shared.core.types.System, .name = "pharos_run_system", .prefix = "PHAROS_RUN_SYSTEM" },
        .{ .type = shared.core.types.Signal, .name = "pharos_run_signal", .prefix = "PHAROS_RUN_SIGNAL" },
        .{ .type = shared.bundle.command.Kind, .name = "pharos_run_command_kind", .prefix = "PHAROS_RUN_CMD" },
        .{ .type = shared.bundle.command.PowerUnit, .name = "pharos_run_power_unit", .prefix = "PHAROS_RUN_POWER" },
        .{ .type = pharos_run.engine.events.Kind, .name = "pharos_run_event_kind", .prefix = "PHAROS_RUN_EVENT" },
    },
};

pub const obs: Product = .{
    .prefix = "pharos_obs",
    .common = pharos_obs.capi.common,
    .modules = &.{ pharos_obs.capi.source, pharos_obs.capi.output, pharos_obs.capi.truth },
    .handles = &.{
        .{ .type = pharos_obs.capi.source.Handle, .name = "pharos_obs_source" },
        .{ .type = pharos_obs.capi.output.Handle, .name = "pharos_obs_output" },
        .{ .type = pharos_obs.capi.truth.Handle, .name = "pharos_obs_truth" },
    },
    .records = &.{
        .{ .type = pharos_obs.capi.common.Bytes, .name = "pharos_obs_bytes" },
        .{ .type = pharos_obs.capi.output.Info, .name = "pharos_obs_output_info" },
        .{ .type = pharos_obs.capi.output.Batch, .name = "pharos_obs_output_batch" },
        .{ .type = capi.command.Command, .name = "pharos_obs_command" },
        .{ .type = pharos_obs.capi.truth.Satellite, .name = "pharos_obs_truth_satellite" },
        .{ .type = pharos_obs.capi.truth.Signal, .name = "pharos_obs_truth_signal" },
        .{ .type = pharos_obs.capi.truth.Epoch, .name = "pharos_obs_truth_epoch" },
        .{ .type = pharos_obs.capi.truth.InspectQuery, .name = "pharos_obs_inspect_query" },
    },
    .enums = &.{
        .{ .type = pharos_obs.output.Output, .name = "pharos_obs_kind", .prefix = "PHAROS_OBS_KIND" },
        .{ .type = shared.core.types.System, .name = "pharos_obs_system", .prefix = "PHAROS_OBS_SYSTEM" },
        .{ .type = shared.core.types.Signal, .name = "pharos_obs_signal", .prefix = "PHAROS_OBS_SIGNAL" },
        .{ .type = shared.stage.channels.State, .name = "pharos_obs_channel", .prefix = "PHAROS_OBS_CHANNEL" },
        .{ .type = pharos_obs.capi.truth.InspectGroup, .name = "pharos_obs_inspect_group", .prefix = "PHAROS_OBS_INSPECT" },
        .{ .type = shared.bundle.command.Kind, .name = "pharos_obs_command_kind", .prefix = "PHAROS_OBS_CMD" },
        .{ .type = shared.bundle.command.PowerUnit, .name = "pharos_obs_power_unit", .prefix = "PHAROS_OBS_POWER" },
    },
};

pub const products = [_]Product{ traj, pack, run, obs };

pub fn functions(comptime product: Product) []const Function {
    const common = capi.Common(product.common);
    comptime var out: []const Function = &.{
        .{ .name = product.prefix ++ "_abi_version", .type = @TypeOf(common.abiVersion) },
        .{ .name = product.prefix ++ "_last_error", .type = @TypeOf(common.lastError) },
    };
    for (product.modules) |module| {
        for (capi.functionNames(product.prefix, module)) |name| {
            out = out ++ [_]Function{.{ .name = name, .type = @TypeOf(@field(module, name)) }};
        }
    }
    return out;
}

pub fn upper(comptime text: []const u8) []const u8 {
    comptime var out: [text.len]u8 = undefined;
    for (text, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    const frozen = out;
    return &frozen;
}
