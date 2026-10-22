const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const model = @import("products/obs/inspect/project");
const messages = @import("products/obs/inspect/messages");
const value = @import("products/obs/inspect/values");
const time = @import("domain/time/gps");
const channels = @import("simulation/state/channels");

pub const Group = enum {
    model,
    navigation,
    messages,
    service,
};

pub const Groups = std.EnumSet(Group);

pub const Query = struct {
    epoch: time.Epoch,
    sat: gnss_types.SatId,
    signal: gnss_types.Signal,
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
    state: ?channels.State = null,
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
        system: gnss_types.System,
        svid: u8,
        signal: gnss_types.Signal,
        family: gnss_types.NavFamily,
    },
    channel: Channel,
    model: ?model.Model = null,
    navigation: ?model.Navigation = null,
    messages: ?messages.Messages = null,
    service: ?messages.Service = null,
};
