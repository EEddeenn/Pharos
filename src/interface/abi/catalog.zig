const std = @import("std");
const traj_context = @import("products/traj/c_api/context");
const pack_context = @import("products/pack/c_api/context");
const run_context = @import("products/run/c_api/context");
const sampling = @import("simulation/model/sampling");
const configuration = @import("simulation/model/config");
const gain = @import("products/run/synthesis/gain");
const events = @import("products/run/engine/events");
const session = @import("products/obs/output/session");
const channels = @import("simulation/state/channels");
const gnss_types = @import("domain/gnss_types");
const obs_context = @import("products/obs/c_api/context");
const output = @import("products/obs/c_api/output");
const source = @import("products/obs/c_api/source");
const truth = @import("products/obs/c_api/truth");
const c_api_pack = @import("products/pack/c_api/pack");
const convert = @import("products/run/c_api/convert");
const c_api_run = @import("products/run/c_api/run");
const geometry = @import("products/traj/c_api/geometry");
const c_api_traj = @import("products/traj/c_api/traj");
const command = @import("simulation/model/command");
const diagnostic_types = @import("base/diagnostics");
const c_command = @import("interface/c/command");
const c_exports = @import("interface/c/exports");
const c_diagnostics = @import("interface/c/diagnostics");
const power = @import("simulation/model/power");
const NoiseMode = @import("products/run/engine/run").NoiseMode;
const ByteView = @import("interface/c/buffers").ByteView;

pub const Named = struct { type: type, name: []const u8 };
pub const Enum = struct { type: type, name: []const u8, prefix: []const u8 };
const Function = struct { name: []const u8, type: type };
pub const Product = struct {
    context: type,
    modules: []const type,
    handles: []const Named,
    records: []const Named,
    enums: []const Enum,
};

pub const traj: Product = .{
    .context = traj_context.Context,
    .modules = &.{ c_api_traj, geometry },
    .handles = &.{
        .{ .type = c_api_traj.Handle, .name = "pharos_traj" },
        .{ .type = geometry.GeometryDescription, .name = "pharos_traj_geometry" },
    },
    .records = &.{
        .{ .type = c_api_traj.Diag, .name = "pharos_traj_diag" },
        .{ .type = c_diagnostics.DiagnosticView, .name = "pharos_traj_diagnostic_view" },
        .{ .type = ByteView, .name = "pharos_traj_byte_view" },
        .{ .type = c_api_traj.Info, .name = "pharos_traj_info" },
        .{ .type = c_api_traj.State, .name = "pharos_traj_state" },
    },
    .enums = &.{
        .{ .type = diagnostic_types.Severity, .name = "pharos_traj_severity", .prefix = "PHAROS_TRAJ_SEVERITY" },
        .{ .type = diagnostic_types.Code, .name = "pharos_traj_diag_code", .prefix = "PHAROS_TRAJ_DIAG" },
        .{ .type = c_diagnostics.LocationKind, .name = "pharos_traj_location_kind", .prefix = "PHAROS_TRAJ_LOCATION" },
    },
};

pub const pack: Product = .{
    .context = pack_context.Context,
    .modules = &.{c_api_pack},
    .handles = &.{
        .{ .type = c_api_pack.Handle, .name = "pharos_pack" },
        .{ .type = c_api_pack.NavDescription, .name = "pharos_pack_nav_description" },
    },
    .records = &.{
        .{ .type = c_api_pack.Diag, .name = "pharos_pack_diag" },
        .{ .type = c_diagnostics.DiagnosticView, .name = "pharos_pack_diagnostic_view" },
        .{ .type = ByteView, .name = "pharos_pack_byte_view" },
        .{ .type = c_api_pack.File, .name = "pharos_pack_file" },
        .{ .type = c_api_pack.Coverage, .name = "pharos_pack_coverage" },
        .{ .type = c_api_pack.CoverageView, .name = "pharos_pack_coverage_view" },
        .{ .type = c_api_pack.Info, .name = "pharos_pack_info" },
    },
    .enums = &.{
        .{ .type = diagnostic_types.Severity, .name = "pharos_pack_severity", .prefix = "PHAROS_PACK_SEVERITY" },
        .{ .type = diagnostic_types.Code, .name = "pharos_pack_diag_code", .prefix = "PHAROS_PACK_DIAG" },
        .{ .type = c_diagnostics.LocationKind, .name = "pharos_pack_location_kind", .prefix = "PHAROS_PACK_LOCATION" },
        .{ .type = gnss_types.System, .name = "pharos_pack_system", .prefix = "PHAROS_PACK_SYSTEM" },
        .{ .type = sampling.IqFormat, .name = "pharos_pack_iq_format", .prefix = "PHAROS_PACK_FORMAT" },
        .{ .type = configuration.PositionFormat, .name = "pharos_pack_position_format", .prefix = "PHAROS_PACK_POSITION" },
    },
};

pub const run: Product = .{
    .context = run_context.Context,
    .modules = &.{c_api_run},
    .handles = &.{.{ .type = c_api_run.Handle, .name = "pharos_run" }},
    .records = &.{
        .{ .type = c_api_run.Options, .name = "pharos_run_options" },
        .{ .type = c_api_run.Info, .name = "pharos_run_info" },
        .{ .type = c_api_run.ManifestFields, .name = "pharos_run_manifest_fields" },
        .{ .type = c_command.Command, .name = "pharos_run_command" },
        .{ .type = convert.Applied, .name = "pharos_run_applied" },
        .{ .type = c_api_run.Block, .name = "pharos_run_block" },
        .{ .type = convert.Event, .name = "pharos_run_event" },
    },
    .enums = &.{
        .{ .type = NoiseMode, .name = "pharos_run_noise", .prefix = "PHAROS_RUN_NOISE" },
        .{ .type = gain.Mode, .name = "pharos_run_gain", .prefix = "PHAROS_RUN_GAIN" },
        .{ .type = gnss_types.System, .name = "pharos_run_system", .prefix = "PHAROS_RUN_SYSTEM" },
        .{ .type = gnss_types.Signal, .name = "pharos_run_signal", .prefix = "PHAROS_RUN_SIGNAL" },
        .{ .type = command.Kind, .name = "pharos_run_command_kind", .prefix = "PHAROS_RUN_CMD" },
        .{ .type = power.Unit, .name = "pharos_run_power_unit", .prefix = "PHAROS_RUN_POWER" },
        .{ .type = events.Kind, .name = "pharos_run_event_kind", .prefix = "PHAROS_RUN_EVENT" },
    },
};

pub const obs: Product = .{
    .context = obs_context.Context,
    .modules = &.{ source, output, truth },
    .handles = &.{
        .{ .type = source.Handle, .name = "pharos_obs_source" },
        .{ .type = output.Handle, .name = "pharos_obs_output" },
        .{ .type = truth.Handle, .name = "pharos_obs_truth" },
    },
    .records = &.{
        .{ .type = ByteView, .name = "pharos_obs_byte_view" },
        .{ .type = output.Info, .name = "pharos_obs_output_info" },
        .{ .type = output.Batch, .name = "pharos_obs_output_batch" },
        .{ .type = c_command.Command, .name = "pharos_obs_command" },
        .{ .type = truth.Satellite, .name = "pharos_obs_truth_satellite" },
        .{ .type = truth.Signal, .name = "pharos_obs_truth_signal" },
        .{ .type = truth.Epoch, .name = "pharos_obs_truth_epoch" },
        .{ .type = truth.InspectQuery, .name = "pharos_obs_inspect_query" },
    },
    .enums = &.{
        .{ .type = session.OutputKind, .name = "pharos_obs_kind", .prefix = "PHAROS_OBS_KIND" },
        .{ .type = gnss_types.System, .name = "pharos_obs_system", .prefix = "PHAROS_OBS_SYSTEM" },
        .{ .type = gnss_types.Signal, .name = "pharos_obs_signal", .prefix = "PHAROS_OBS_SIGNAL" },
        .{ .type = channels.State, .name = "pharos_obs_channel", .prefix = "PHAROS_OBS_CHANNEL" },
        .{ .type = truth.InspectGroup, .name = "pharos_obs_inspect_group", .prefix = "PHAROS_OBS_INSPECT" },
        .{ .type = command.Kind, .name = "pharos_obs_command_kind", .prefix = "PHAROS_OBS_CMD" },
        .{ .type = power.Unit, .name = "pharos_obs_power_unit", .prefix = "PHAROS_OBS_POWER" },
    },
};

pub const products = [_]Product{ traj, pack, run, obs };

pub fn functions(comptime product: Product) []const Function {
    const common = c_exports.Common(product.context);
    comptime var out: []const Function = &.{
        .{ .name = product.context.prefix ++ "_abi_version", .type = @TypeOf(common.abiVersion) },
        .{ .name = product.context.prefix ++ "_source_digest", .type = @TypeOf(common.sourceDigest) },
        .{ .name = product.context.prefix ++ "_last_error", .type = @TypeOf(common.lastError) },
    };
    for (product.modules) |module| {
        for (c_exports.functionNames(product.context.prefix, module)) |name| {
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
