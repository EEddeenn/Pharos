const signal_catalog = @import("domain/signals/catalog");
const codes = @import("domain/signals/codes/generate");
const gnss_types = @import("domain/gnss_types");
const set = @import("simulation/state/messages");

const Mask = u8;
const data_neg: Mask = 1;
const pilot_neg: Mask = 2;

pub const SymbolSource = struct {
    messages: set.MessageSet,
    pending: ?set.MessageSet = null,
    prn: u8,
    timing: signal_catalog.Frame,
    offset_ms: u16,
    secondary: ?[]const u1,
    cached: ?CachedFrame = null,
    boundary: ?Boundary = null,

    const CachedFrame = struct { index: i64, bits: ?set.FrameBits };

    const Boundary = struct {
        index: i64,
        previous: set.FrameBits,
        current: ?set.FrameBits,
    };

    const Location = struct { index: i64, bit: usize, nh: u1 };

    pub fn init(messages: set.MessageSet, sat: gnss_types.SatId, signal: gnss_types.Signal) SymbolSource {
        const row = signal_catalog.get(signal);
        return .{ .messages = messages, .prn = sat.prn(), .timing = signal_catalog.frameFor(signal, sat), .offset_ms = row.frame_offset_ms, .secondary = codes.secondaryCode(signal, sat) };
    }

    pub fn replaceSet(self: *SymbolSource, messages: set.MessageSet) void {
        // The sequence has just rebuilt the older of its two sets in place, so a set still pending is taken first.
        self.adopt();
        self.pending = messages;
    }

    // Reads, in order, every frame after the last one read and before code period k's, as the windows a seek skipped
    // would have; a source no window has read reads only the frame before.
    pub fn catchUp(self: *SymbolSource, k: u64) void {
        const index = self.locate(k).index - 1;
        const previous = if (self.cached) |*cached| cached.index else {
            _ = self.frameFor(index);
            return;
        };
        var i = previous + 1;
        while (i <= index) : (i += 1) _ = self.frameFor(i);
    }

    pub fn fill(self: *SymbolSource, k0: u64, out: []Mask) void {
        for (out, 0..) |*m, i| {
            const loc = self.locate(k0 + i);
            const bit: u1 = if (self.frameFor(loc.index)) |bits| bits.get(loc.bit) else 0;
            m.* = maskOf(bit, loc.nh) | self.pilotMask(k0 + i);
        }
    }

    fn adopt(self: *SymbolSource) void {
        const p = self.pending orelse return;
        self.messages = p;
        self.pending = null;
        self.boundary = null;
        self.cached = null;
    }

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

    fn frameFor(self: *SymbolSource, index: i64) ?*const set.FrameBits {
        if (self.cached) |*cached| {
            if (index == cached.index) return if (cached.bits) |*bits| bits else null;
            if (self.pending) |pending| {
                // The first frame read comes from the set the source holds; a set given later is taken where a cycle begins.
                if (index > cached.index and pending.setCycle(self.prn, index) != pending.setCycle(self.prn, cached.index)) {
                    self.boundary = null;
                    if (cached.bits) |*bits| if (index == cached.index + 1) {
                        var next: set.FrameBits = undefined;
                        const present = pending.frameBitsAfter(self.messages, self.prn, index, &next);
                        self.boundary = .{ .index = index, .previous = bits.*, .current = if (present) next else null };
                    };
                    self.messages = pending;
                    self.pending = null;
                }
            }
        }
        self.cached = .{ .index = index, .bits = @as(set.FrameBits, undefined) };
        const cached = &self.cached.?;
        if (!self.frameBits(index, &cached.bits.?)) cached.bits = null;
        return if (cached.bits) |*bits| bits else null;
    }

    fn frameBits(self: *const SymbolSource, index: i64, out: *set.FrameBits) bool {
        if (self.boundary) |*boundary| {
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
