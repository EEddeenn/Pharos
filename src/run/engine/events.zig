const types = @import("shared").core.types;
const Epoch = @import("shared").core.time.Epoch;

const capacity: usize = 1024;

pub const Kind = enum(u32) {
    agc = 1,
    command_applied = 2,
    channel_added = 3,
    channel_removed = 4,
    ephemeris_switched = 5,
};

pub const Event = union(Kind) {
    agc: @import("../synth.zig").gain.Adjustment,
    command_applied: struct { epoch: Epoch, index: u32 },
    channel_added: struct { epoch: Epoch, key: types.ChannelKey },
    channel_removed: struct { epoch: Epoch, key: types.ChannelKey },
    ephemeris_switched: struct { epoch: Epoch, sat: types.SatId },
};

pub const Ring = struct {
    items: [capacity]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    dropped: u32 = 0,

    pub fn push(self: *Ring, event: Event) void {
        if (self.len == capacity) {
            self.dropped +|= 1;
            return;
        }
        self.items[(self.head + self.len) % capacity] = event;
        self.len += 1;
    }

    pub fn next(self: *Ring) ?Event {
        if (self.len == 0) return null;
        const event = self.items[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return event;
    }

    pub fn count(self: *const Ring) usize {
        return self.len;
    }

    pub fn truncate(self: *Ring, n: usize) void {
        self.len = @min(self.len, n);
    }

    pub fn retainSwitches(self: *Ring, from: Epoch) void {
        var kept: usize = 0;
        for (0..self.len) |i| {
            const event = self.items[(self.head + i) % capacity];
            switch (event) {
                .ephemeris_switched => |s| if (s.epoch.ms >= from.ms) {
                    self.items[(self.head + kept) % capacity] = event;
                    kept += 1;
                },
                else => {},
            }
        }
        self.len = kept;
    }
};
