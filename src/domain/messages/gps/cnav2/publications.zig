const publication = @import("domain/messages/publication");
const time = @import("domain/time/gps");
const messages = @import("domain/messages/gps/publication");
const pages = @import("domain/messages/gps/cnav2/pages");
pub const Payload = pages.Payload;
pub const Content = struct {
    declaration: *const messages.Declaration,
    configuration: ?Payload = null,
    ism: ?struct { reference: time.GpsTime, payload: Payload } = null,

    pub fn init(src: *const messages.Declaration) Content {
        var out: Content = .{ .declaration = src };
        if (src.configuration) |*codes| out.configuration = configurationPage(codes);
        if (src.ism) |*i| {
            var payload: Payload = .{};
            var w = payload.writer();
            pages.encodeIsm(i, &w);
            out.ism = .{ .reference = i.reference, .payload = payload };
        }
        return out;
    }
};

pub const PreparedPublication = publication.Publication(Content);

pub fn configurationPage(codes: *const [63]u3) Payload {
    var payload: Payload = .{};
    var w = payload.writer();
    pages.encodeConfiguration(codes, &w);
    return payload;
}
