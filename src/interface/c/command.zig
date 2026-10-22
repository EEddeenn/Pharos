const std = @import("std");
const c_buffers = @import("interface/c/buffers");
const command = @import("simulation/model/command");
const power = @import("simulation/model/power");
const gnss_types = @import("domain/gnss_types");
const angles = @import("base/math/angles");
const ErrorBuffer = c_buffers.ErrorBuffer;

pub const Command = extern struct {
    apply_at_epoch: u64 = 0,
    value: f64 = 0,
    kind: u32,
    system: u32 = 0,
    svid: u32 = 0,
    unit: u32 = 0,
    use_default: u32 = 0,
};

pub fn decode(c: Command, err: *ErrorBuffer) ?command.Command {
    const kind = defined(command.Kind, "kind", c.kind, err) orelse return null;
    const action: command.Action = switch (kind) {
        .noise_floor_dbm_hz => .{ .noise_floor_dbm_hz = c.value },
        .elevation_mask => .{ .elevation_mask = angles.deg2rad(c.value) },
        .signal_power => blk: {
            const system = defined(gnss_types.System, "system", c.system, err) orelse return null;
            const target: power.Target = if (c.svid == 0)
                .{ .whole = system }
            else
                .{ .sat = gnss_types.SatId.fromPrn(system, c.svid) catch {
                    err.set("a {s} svid must be at most {d}, got {d}", .{ system.displayName(), system.capacity(), c.svid });
                    return null;
                } };
            const level: ?power.Level = if (c.use_default != 0) null else .{
                .unit = defined(power.Unit, "unit", c.unit, err) orelse return null,
                .value = c.value,
            };
            break :blk .{ .signal_power = .{ .target = target, .level = level } };
        },
    };
    return .{ .apply_at_epoch = c.apply_at_epoch, .action = action };
}

pub fn rejected(comptime S: type, err: *ErrorBuffer, e: error{ InvalidValue, EpochPassed }) S {
    err.set("submit rejected: {s}", .{switch (e) {
        error.InvalidValue => "the command's value is out of range",
        error.EpochPassed => "the command's epoch has passed",
    }});
    return .arg;
}

pub fn toC(c: command.Command) Command {
    var out: Command = .{ .kind = @backingInt(c.action), .apply_at_epoch = c.apply_at_epoch };
    switch (c.action) {
        .noise_floor_dbm_hz => |v| out.value = v,
        .elevation_mask => |v| out.value = angles.rad2deg(v),
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

fn defined(comptime E: type, comptime name: []const u8, value: u32, err: *ErrorBuffer) ?E {
    return std.enums.fromInt(E, value) orelse {
        err.set(name ++ " must be from 0 to {d}, got {d}", .{ std.enums.values(E).len - 1, value });
        return null;
    };
}
