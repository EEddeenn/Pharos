const std = @import("std");
const core = @import("../core.zig");
const Lla = core.coord.Lla;
const Writer = std.Io.Writer;

pub fn head(w: *Writer, document: []const u8, placemark: []const u8) Writer.Error!void {
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<kml xmlns=\"http://www.opengis.net/kml/2.2\"> <Document>\n\t<name>");
    try escaped(w, document);
    try w.writeAll("</name>\n\t<Style id=\"trajectory\">\n" ++
        "\t\t<LineStyle>\n\t\t\t<color>7f00ffff</color>\n\t\t\t<width>4</width>\n\t\t</LineStyle>\n" ++
        "\t</Style>\n\t<Placemark>\n\t\t<name>");
    try escaped(w, placemark);
    try w.writeAll("</name>\n\t<styleUrl>#trajectory</styleUrl>\n" ++
        "\t\t<LineString>\n\t\t\t<altitudeMode>absolute</altitudeMode>\n" ++
        "\t\t\t<coordinates>\n");
}

pub fn coordinate(w: *Writer, p: Lla) Writer.Error!void {
    try w.print("\t\t\t\t{d:.9},{d:.9},{d:.4}\n", .{ core.constants.rad2deg(p.lon_rad), core.constants.rad2deg(p.lat_rad), core.geoid.altitude(p) });
}

pub fn foot(w: *Writer) Writer.Error!void {
    try w.writeAll("\t\t\t</coordinates>\n\t\t</LineString>\n\t</Placemark>\n</Document> </kml>\n");
}

fn escaped(w: *Writer, name: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < name.len) : (i += 1) switch (name[i]) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        // characters XML 1.0 does not allow: these, and U+FFFE and U+FFFF
        0...8, 11, 12, 14...31 => {},
        0xEF => if (i + 2 < name.len and name[i + 1] == 0xBF and name[i + 2] & 0xFE == 0xBE) {
            i += 2;
        } else {
            try w.writeByte(0xEF);
        },
        else => try w.writeByte(name[i]),
    };
}
