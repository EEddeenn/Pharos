const time = @import("../../../core.zig").time;
const field = @import("../../../codec.zig").field;
const messages = @import("../messages.zig");
const pages = @import("pages.zig");

pub const Payload = pages.Payload;

pub const Content = struct {
    sources: messages.Sources,
    configuration: ?Payload = null,
    ism: ?struct { reference: time.GpsTime, payload: Payload } = null,

    pub fn build(src: messages.Sources) (error{ValueOutOfRange} || field.Error)!Content {
        try src.validate();
        var out: Content = .{ .sources = src };
        if (src.configuration) |*codes| out.configuration = configurationPage(codes);
        if (src.ism) |*i| {
            var payload: Payload = .{};
            var w = payload.writer();
            try pages.encodeIsm(i, &w);
            out.ism = .{ .reference = i.reference, .payload = payload };
        }
        return out;
    }
};

pub fn configurationPage(codes: *const [63]u3) Payload {
    var payload: Payload = .{};
    var w = payload.writer();
    pages.encodeConfiguration(codes, &w);
    return payload;
}

pub const PreparedPublication = @import("../../publication.zig").Publication(Content);
