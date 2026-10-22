const GpsTime = @import("domain/time/gps").GpsTime;

pub const Cadence = struct {
    offset_ms: i64,
    first: i64,
    served_through: i64,

    pub fn init(offset_ms: i64, start: GpsTime) Cadence {
        const first = @divFloor(start.ms - offset_ms, 1000);
        return .{ .offset_ms = offset_ms, .first = first, .served_through = first - 1 };
    }

    pub fn next(self: *Cadence, t: GpsTime) ?i64 {
        if (self.served_through >= @divFloor(t.ms - self.offset_ms, 1000)) return null;
        self.served_through += 1;
        return self.served_through;
    }

    pub fn timeOf(self: Cadence, second: i64) GpsTime {
        return .{ .ms = second * 1000 + self.offset_ms };
    }
};

pub fn due(second: i64, interval_s: u32) bool {
    return @mod(second, interval_s) == 0;
}
