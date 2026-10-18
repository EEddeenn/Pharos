const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const types = core.types;
pub const model = @import("inspect/model.zig");
pub const messages = @import("inspect/messages.zig");
pub const value = @import("inspect/value.zig");

pub const Group = enum {
    model,
    navigation,
    messages,
    service,
};

pub const Groups = std.EnumSet(Group);

pub const Query = struct {
    epoch: core.time.Epoch,
    sat: types.SatId,
    signal: types.Signal,
    groups: Groups = .full,

    pub fn includes(self: Query, group: Group) bool {
        return self.groups.contains(group);
    }

    pub fn valid(self: Query) bool {
        return self.sat.valid() and self.sat.system == self.signal.system();
    }
};

pub const Channel = struct {
    status: value.Availability,
    reason: ?value.Reason = null,
    configured: bool,
    broadcasts: bool,
    maskedOut: bool,
    state: ?shared.stage.channels.State = null,
    commanded: bool,
    cn0DbHz: ?f64 = null,
    noiseFloorDbmHz: f64,
    elevationMaskDeg: f64,
    units: struct {
        cn0DbHz: []const u8 = "dB-Hz",
        noiseFloorDbmHz: []const u8 = "dBm/Hz",
        elevationMaskDeg: []const u8 = "deg",
    } = .{},
};

pub const Result = struct {
    version: u32 = 1,
    epochMs: value.ExactInt,
    endpoint: bool,
    target: struct {
        system: types.System,
        svid: u8,
        signal: types.Signal,
        family: types.NavFamily,
    },
    channel: Channel,
    model: ?model.Model = null,
    navigation: ?model.Navigation = null,
    messages: ?messages.Messages = null,
    service: ?messages.Service = null,
};
