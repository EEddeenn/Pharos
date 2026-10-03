const text = @import("text.zig");
const ism = @import("ism.zig");

pub const Integrity = struct {
    isf: u1,
    alert: u32 = 0,

    pub fn alerts(self: Integrity, prn: u8) bool {
        return (self.alert >> @intCast(prn - 1)) & 1 == 1;
    }
};

pub const Differential = struct { udra: i5, udra_rate: i5 };

pub const Sources = struct {
    integrity: ?Integrity = null,
    text: ?[]const u8 = null,
    configuration: ?[63]u3 = null,
    ism: ?ism.Ism = null,
    differential: ?Differential = null,

    pub fn validate(self: *const Sources) error{ValueOutOfRange}!void {
        if (self.text) |t| if (!text.valid(t)) return error.ValueOutOfRange;
        if (self.configuration) |codes| for (codes) |c| if (c > 5) return error.ValueOutOfRange;
        if (self.ism) |*i| try ism.check(i);
    }

    pub fn build(src: Sources) error{ValueOutOfRange}!Sources {
        try src.validate();
        return src;
    }
};

pub const Publication = @import("../publication.zig").Publication(Sources);
