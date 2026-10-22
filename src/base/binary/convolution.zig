const g1_mask: u7 = 0x4F;
const g2_mask: u7 = 0x6D;

pub const Symbols = struct { g1: u1, g2: u1 };

pub const Encoder = struct {
    state: u6 = 0,
    invert_g2: bool = false,

    pub fn push(self: *Encoder, bit: u1) Symbols {
        const register: u7 = (@as(u7, self.state) << 1) | bit;
        const g1 = parity(register & g1_mask);
        const g2 = parity(register & g2_mask) ^ @intFromBool(self.invert_g2);
        self.state = @truncate(register);
        return .{ .g1 = g1, .g2 = g2 };
    }
};

fn parity(x: u7) u1 {
    return @truncate(@popCount(x));
}
