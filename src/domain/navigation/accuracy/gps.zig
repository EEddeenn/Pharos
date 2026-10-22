pub const Ura = struct { ed: i5, ned0: i5, ned1: u3, ned2: u3 };

pub fn ofLnav(ura_index: u4) Ura {
    return .{ .ed = ura_index, .ned0 = ura_index, .ned1 = 7, .ned2 = 7 };
}
