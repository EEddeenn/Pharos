const gnss_types = @import("domain/gnss_types");
const l5_frame_ms = 6000;
const l2c_frame_ms = 12_000;
pub const Carrier = enum {
    l5,
    l2c,

    pub fn of(signal: gnss_types.Signal) Carrier {
        return switch (signal) {
            .l2c => .l2c,
            .l5 => .l5,
            else => unreachable,
        };
    }

    pub fn frameMs(self: Carrier) u32 {
        return switch (self) {
            .l5 => l5_frame_ms,
            .l2c => l2c_frame_ms,
        };
    }

    fn towStep(self: Carrier) i64 {
        return if (self == .l2c) 2 else 1;
    }
};

pub const frame_ms = Carrier.l5.frameMs();
const messages_per_week = 100_800;
pub const messages_per_superframe = 100;
pub const dc_messages_per_superframe = 4;
pub const Available = struct {
    utc: bool,
    eop: bool,
    almanac: bool,
    ggto: u2,
    ism: bool,
    dc: bool,
    text: bool,
};

pub const Type = enum(u6) { ephemeris_1 = 10, ephemeris_2 = 11, reduced_almanac = 12, clock_differential = 13, ephemeris_differential = 14, text = 15, clock_iono = 30, clock_reduced_almanac = 31, clock_eop = 32, clock_utc = 33, clock_differential_both = 34, clock_ggto = 35, clock_text = 36, clock_midi_almanac = 37, ism = 40 };
pub const Slot = struct {
    kind: Type,
    tow_next: u17,
    almanac: u5 = 0,
    ggto: u1 = 0,
    dc_cycle: i64 = 0,
    dc_step: u2 = 0,
    text: i64 = 0,
};

pub fn slot(index: i64, carrier: Carrier, available: Available) Slot {
    const step = carrier.towStep();
    const message_in_week = @mod(index, @divExact(messages_per_week, step));
    const group_in_week = @divFloor(message_in_week, 4);
    const group_in_superframe = @mod(group_in_week, 25);
    const cycle = @divFloor(index, messages_per_superframe);
    var result: Slot = .{ .kind = .ephemeris_1, .tow_next = @intCast(@mod((message_in_week + 1) * step, messages_per_week)) };
    const utc: Type = if (available.utc) .clock_utc else .clock_iono;
    switch (@mod(message_in_week, 4)) {
        0 => {},
        1 => result.kind = .ephemeris_2,
        2 => {
            const ordinal: u5 = @intCast(2 * @divFloor(group_in_superframe, 6) + @intFromBool(@mod(group_in_superframe, 6) >= 4));
            switch (@mod(group_in_superframe, 6)) {
                0 => result.kind = if (available.ism) .ism else .clock_iono,
                1 => if (available.dc) {
                    result.dc_cycle = cycle;
                    result.dc_step = @intCast(@divFloor(group_in_superframe, 6));
                    result.kind = if (carrier == .l5)
                        .clock_differential_both
                    else if (result.dc_step == 0)
                        .clock_differential
                    else
                        .ephemeris_differential;
                } else {
                    result.kind = utc;
                },
                2, 4 => if (carrier == .l2c and ordinal >= 5 and available.text) {
                    result.kind = .text;
                    result.text = 3 * cycle + ordinal - 5;
                } else if (available.almanac) {
                    result.kind = if (carrier == .l5) .clock_reduced_almanac else .reduced_almanac;
                    result.almanac = ordinal;
                } else {
                    result.kind = .clock_iono;
                },
                else => if (available.almanac) {
                    result.kind = .clock_midi_almanac;
                    result.almanac = @intCast(8 * @mod(cycle, 4) + ordinal);
                } else {
                    result.kind = .clock_iono;
                },
            }
        },
        else => {
            const absolute_group = @divFloor(index, 4);
            switch (@mod(absolute_group, 6)) {
                0 => result.kind = .clock_iono,
                1 => result.kind = utc,
                2 => result.kind = if (available.ggto > 0) .clock_ggto else .clock_iono,
                3 => if (carrier == .l5 and available.text) {
                    result.kind = .clock_text;
                    result.text = @divFloor(absolute_group, 6);
                } else {
                    result.kind = .clock_iono;
                },
                4 => if (available.ggto == 2) {
                    result.kind = .clock_ggto;
                    result.ggto = 1;
                } else {
                    result.kind = utc;
                },
                else => result.kind = if (available.eop) .clock_eop else utc,
            }
        },
    }
    return result;
}
