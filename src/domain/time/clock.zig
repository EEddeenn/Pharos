const GpsTime = @import("domain/time/gps").GpsTime;

pub const Poly = struct {
    toc: GpsTime,
    af0: f64,
    af1: f64,
    af2: f64,

    pub fn bias(self: Poly, t: GpsTime) f64 {
        const dt = t.secondsSince(self.toc);
        return self.af0 + (self.af1 + self.af2 * dt) * dt;
    }

    pub fn drift(self: Poly, t: GpsTime) f64 {
        return self.af1 + 2.0 * self.af2 * t.secondsSince(self.toc);
    }

    pub fn plus(self: Poly, other: Poly) Poly {
        return .{
            .toc = self.toc,
            .af0 = self.af0 + other.bias(self.toc),
            .af1 = self.af1 + other.drift(self.toc),
            .af2 = self.af2 + other.af2,
        };
    }
};
