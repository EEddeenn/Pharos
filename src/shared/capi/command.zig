const std = @import("std");
const core = @import("../core.zig");
const command = @import("../bundle.zig").command;
const ErrorBuffer = @import("../capi.zig").ErrorBuffer;
const types = core.types;

pub const Command = extern struct {
    apply_at_epoch: u64 = 0,
    value: f64 = 0,
    kind: u32,
    system: u32 = 0,
    svid: u32 = 0,
    unit: u32 = 0,
    use_default: u32 = 0,
};

pub fn decode(given: Command, err: *ErrorBuffer) ?command.Command {
    return fromC(given) orelse {
        err.set("malformed command", .{});
        return null;
    };
}

pub fn rejected(comptime S: type, err: *ErrorBuffer, e: error{ InvalidValue, EpochPassed }) S {
    err.set("submit rejected: {s}", .{switch (e) {
        error.InvalidValue => "the command's value is out of range",
        error.EpochPassed => "the command's epoch has passed",
    }});
    return .arg;
}

fn fromC(c: Command) ?command.Command {
    const kind = std.enums.fromInt(command.Kind, c.kind) orelse return null;
    const action: command.Action = switch (kind) {
        .noise_floor_dbm_hz => .{ .noise_floor_dbm_hz = c.value },
        .elevation_mask => .{ .elevation_mask = core.constants.deg2rad(c.value) },
        .signal_power => blk: {
            const system = std.enums.fromInt(types.System, c.system) orelse return null;
            const target: command.Target = if (c.svid == 0)
                .{ .whole = system }
            else
                .{ .sat = types.SatId.fromPrn(system, c.svid) catch return null };
            const level: ?command.PowerLevel = if (c.use_default != 0) null else .{
                .unit = std.enums.fromInt(command.PowerUnit, c.unit) orelse return null,
                .value = c.value,
            };
            break :blk .{ .signal_power = .{ .target = target, .level = level } };
        },
    };
    return .{ .apply_at_epoch = c.apply_at_epoch, .action = action };
}

pub fn toC(c: command.Command) Command {
    var out: Command = .{ .kind = @backingInt(c.action), .apply_at_epoch = c.apply_at_epoch };
    switch (c.action) {
        .noise_floor_dbm_hz => |v| out.value = v,
        .elevation_mask => |v| out.value = core.constants.rad2deg(v),
        .signal_power => |p| {
            out.system = @backingInt(p.target.system());
            out.svid = switch (p.target) {
                .whole => 0,
                .sat => |s| s.prn(),
            };
            if (p.level) |l| {
                out.unit = @backingInt(l.unit);
                out.value = l.value;
            } else out.use_default = 1;
        },
    }
    return out;
}
