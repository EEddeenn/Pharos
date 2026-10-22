const publication = @import("domain/messages/publication");
const ism = @import("domain/messages/gps/ism");
pub const Integrity = struct {
    isf: u1,
    alert: u32 = 0,

    pub fn alerts(self: Integrity, prn: u8) bool {
        return (self.alert >> @intCast(prn - 1)) & 1 == 1;
    }
};

pub const Differential = struct { udra: i5, udra_rate: i5 };
pub const Declaration = struct {
    integrity: ?Integrity = null,
    text: ?[]const u8 = null,
    configuration: ?[63]u3 = null,
    ism: ?ism.Ism = null,
    differential: ?Differential = null,
};

pub const Publication = publication.Publication(Declaration);
