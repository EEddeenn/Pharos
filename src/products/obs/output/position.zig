const time = @import("domain/time/gps");
const coordinates = @import("domain/earth/coordinates");
const kml = @import("domain/trajectory/formats/kml");
const positions = @import("domain/trajectory/formats/position_text");

const Io = @import("std").Io;
const PositionFormat = @import("simulation/model/config").PositionFormat;

const kml_document = "Pharos receiver trajectory";
const kml_placemark = "Receiver";

pub fn positionHeader(w: *Io.Writer, format: PositionFormat) Io.Writer.Error!void {
    switch (format) {
        .ecef => try w.writeAll(positions.header(.ecef)),
        .lla => try w.writeAll(positions.header(.lla)),
        .kml => try kml.head(w, kml_document, kml_placemark),
    }
}

pub fn positionEpoch(w: *Io.Writer, format: PositionFormat, t: time.GpsTime, pos: coordinates.Ecef, lla: coordinates.Lla) Io.Writer.Error!void {
    switch (format) {
        .ecef => try positions.ecefLine(w, t, pos),
        .lla => try positions.llaLine(w, t, lla),
        .kml => try kml.coordinate(w, lla),
    }
}

pub fn positionFooter(w: *Io.Writer, format: PositionFormat) Io.Writer.Error!void {
    if (format == .kml) try kml.foot(w);
}
