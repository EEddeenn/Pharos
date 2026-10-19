const std = @import("std");
const spec = @import("shared").gnss.spec;
const codes = @import("shared").gnss.codes;
const types = @import("shared").core.types;
const set = @import("shared").stage.messages;

const Mask = u8;
const data_neg: Mask = 1;
const pilot_neg: Mask = 2;
const unread: i64 = std.math.minInt(i64);

pub const SymbolSource = struct {
    messages: set.MessageSet,
    pending: ?set.MessageSet = null,
    prn: u8,
    timing: spec.Frame,
    offset_ms: u16,
    secondary: ?[]const u1,
    cache_index: i64 = unread,
    cache_present: bool = false,
    cache: set.FrameBits = .{},
    boundary: ?Boundary = null,

    const Boundary = struct {
        index: i64,
        previous: set.FrameBits,
        current: ?set.FrameBits,
    };

    pub fn init(messages: set.MessageSet, sat: types.SatId, signal: types.Signal) SymbolSource {
        const row = spec.get(signal);
        return .{ .messages = messages, .prn = sat.prn(), .timing = spec.frameFor(signal, sat), .offset_ms = row.frame_offset_ms, .secondary = codes.secondaryCode(signal, sat) };
    }

    pub fn replaceSet(self: *SymbolSource, messages: set.MessageSet) void {
        // The sequence has just rebuilt the older of its two sets in place, so a set still pending is taken first.
        self.adopt();
        self.pending = messages;
    }

    fn adopt(self: *SymbolSource) void {
        const p = self.pending orelse return;
        self.messages = p;
        self.pending = null;
        self.boundary = null;
        self.cache_index = unread;
        self.cache_present = false;
    }

    const Location = struct { index: i64, bit: usize, nh: u1 };

    fn locate(self: *const SymbolSource, k: u64) Location {
        const code_ms: u64 = self.timing.code_length_ms;
        const bit_ms: u64 = code_ms * self.timing.nh_length;
        const ms = k * code_ms + self.offset_ms;
        const in_frame = ms % self.timing.frame_length_ms;
        const nh_pos: u5 = @intCast((in_frame % bit_ms) / code_ms);
        return .{
            .index = @intCast(ms / self.timing.frame_length_ms),
            .bit = @intCast(in_frame / bit_ms),
            .nh = @truncate(self.timing.nh_code >> nh_pos),
        };
    }

    fn pilotMask(self: *const SymbolSource, k: u64) Mask {
        const s = self.secondary orelse return 0;
        return s[k % s.len] * pilot_neg;
    }

    fn maskOf(bit: u1, nh: u1) Mask {
        return (bit ^ nh) * data_neg;
    }

    pub fn fill(self: *SymbolSource, k0: u64, out: []Mask) void {
        for (out, 0..) |*m, i| {
            const loc = self.locate(k0 + i);
            const bit: u1 = if (self.frameFor(loc.index)) self.cache.get(loc.bit) else 0;
            m.* = maskOf(bit, loc.nh) | self.pilotMask(k0 + i);
        }
    }

    fn frameFor(self: *SymbolSource, index: i64) bool {
        if (index != self.cache_index) {
            if (self.pending) |pending| {
                // The first frame read comes from the set the source holds; a set given later is taken where a cycle begins.
                if (self.cache_index != unread and index > self.cache_index and pending.setCycle(self.prn, index) != pending.setCycle(self.prn, self.cache_index)) {
                    self.boundary = null;
                    if (self.cache_present and index == self.cache_index + 1) {
                        var next: set.FrameBits = undefined;
                        const present = pending.frameBitsAfter(self.messages, self.prn, index, &next);
                        self.boundary = .{ .index = index, .previous = self.cache, .current = if (present) next else null };
                    }
                    self.messages = pending;
                    self.pending = null;
                }
            }
            self.cache_present = self.frameBits(index, &self.cache);
            self.cache_index = index;
        }
        return self.cache_present;
    }

    fn frameBits(self: *const SymbolSource, index: i64, out: *set.FrameBits) bool {
        if (self.boundary) |boundary| {
            if (index == boundary.index - 1) {
                out.* = boundary.previous;
                return true;
            }
            if (index == boundary.index) {
                out.* = boundary.current orelse return false;
                return true;
            }
        }
        return self.messages.frameBits(self.prn, index, out);
    }
};
