const core = @import("shared").core;
const engine = @import("../engine.zig");
const types = core.types;
const Epoch = core.time.Epoch;
const Command = @import("shared").capi.command.Command;

pub const Applied = extern struct { epoch: u64, command: Command };

pub const Event = extern struct {
    epoch: u64,
    a: f64,
    b: f64,
    c: f64,
    kind: u32,
    code: u32,
    system: u32,
    svid: u32,
    signal: u32,
};

pub fn eventToC(ev: engine.events.Event) Event {
    var out: Event = .{ .epoch = 0, .a = 0, .b = 0, .c = 0, .kind = @intFromEnum(ev), .code = 0, .system = 0, .svid = 0, .signal = 0 };
    switch (ev) {
        .agc => |a| {
            out.epoch = a.epoch.ms;
            out.a = a.gain;
            out.b = a.clip_rate;
            out.c = if (a.reduced) 1 else 0;
        },
        .command_applied => |c| {
            out.epoch = c.epoch.ms;
            out.code = c.index;
        },
        .channel_added => |c| channelEvent(&out, c.epoch, c.key),
        .channel_removed => |c| channelEvent(&out, c.epoch, c.key),
        .ephemeris_switched => |s| {
            out.epoch = s.epoch.ms;
            out.system = @intFromEnum(s.sat.system);
            out.svid = s.sat.prn();
        },
    }
    return out;
}

fn channelEvent(out: *Event, epoch: Epoch, key: types.ChannelKey) void {
    out.epoch = epoch.ms;
    out.system = @intFromEnum(key.sat.system);
    out.svid = key.sat.prn();
    out.signal = @intFromEnum(key.signal);
}
