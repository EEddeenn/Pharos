const gnss_types = @import("domain/gnss_types");
const health = @import("domain/navigation/health");
const accuracy = @import("domain/navigation/accuracy/gps");

const Status = health.Status;

const Components = struct {
    l1: Status = .ok,
    l2: Status = .ok,
    l5: Status = .ok,
    l1ca: Status = .ok,
    l1c: Status = .ok,
    l2c: Status = .ok,

    fn signal(self: Components, which: gnss_types.Signal) Status {
        return switch (which) {
            .l1ca => self.l1ca,
            .l1c => self.l1c,
            .l2c => self.l2c,
            .l5 => self.l5,
            else => .ok,
        };
    }
};

pub const LnavExtra = struct {
    ura_index: u4,
    health: u6,
    l2_codes: u2,
    l2p_data: bool,
    fit_interval: bool,

    pub const almanac_health_bits: u9 = health.almanac_health_all;

    pub const transmission_lead_s: f64 = 7200;

    pub fn signalStatus(self: LnavExtra, signal: gnss_types.Signal) Status {
        return self.components().signal(signal);
    }

    pub fn healthy(self: LnavExtra) bool {
        const c = self.components();
        return c.l1ca.flies() or c.l1c.flies() or c.l2c.flies() or c.l5.flies();
    }

    pub fn carrierHealth(self: LnavExtra) ?u3 {
        const c = self.components();
        if (c.l1 == .unstated or c.l2 == .unstated or c.l5 == .unstated) return null;
        return carriers(c.l1 == .dead, c.l2 == .dead, c.l5 == .dead);
    }

    pub fn l1cHealth(self: LnavExtra) ?bool {
        return switch (self.components().l1c) {
            .ok => false,
            .degraded, .dead => true,
            .unstated => null,
        };
    }

    pub fn almanacHealth(self: LnavExtra) u9 {
        return (if (self.dataBad()) @as(u9, 0b111 << 5) else 0) | (self.health & 0x1F);
    }

    fn components(self: LnavExtra) Components {
        return componentsOf(@truncate(self.health));
    }

    fn dataBad(self: LnavExtra) bool {
        return self.health >> 5 != 0;
    }
};

pub const CnavFlags = struct {
    integrity_status: bool,
    l2c_phasing: bool,
    alert: bool,
};

pub const CnavExtra = struct {
    ura: accuracy.Ura,
    l1_health: bool,
    l2_health: bool,
    l5_health: bool,
    flags: ?CnavFlags = null,

    pub const almanac_health_bits: u9 = health.almanac_health_all;

    pub const transmission_lead_s: f64 = 5400;

    pub fn signalStatus(self: CnavExtra, signal: gnss_types.Signal) Status {
        const bad = switch (signal) {
            // The L1 bit speaks for L1 C/A and L1C at second hand (SPS PS 2.3.2.1 note 4): 0 says some code is OK.
            .l1ca, .l1c => return if (self.l1_health) .degraded else .unstated,
            .l2c => self.l2_health,
            .l5 => self.l5_health,
            else => return .unstated,
        };
        return health.flagged(bad);
    }

    pub fn healthy(_: CnavExtra) bool {
        return true;
    }

    pub fn almanacHealth(self: CnavExtra) u9 {
        return lnavHealth(self.carrierHealth());
    }

    pub fn carrierHealth(self: CnavExtra) u3 {
        return carriers(self.l1_health, self.l2_health, self.l5_health);
    }
};

pub const Cnav2Extra = struct {
    ura: accuracy.Ura,
    l1_health: bool,
    integrity_status: ?bool = null,

    pub const almanac_health_bits: u9 = health.almanac_health_all;

    pub const transmission_lead_s: f64 = CnavExtra.transmission_lead_s;

    pub fn signalStatus(self: Cnav2Extra, signal: gnss_types.Signal) Status {
        return if (signal == .l1c) health.flagged(self.l1_health) else .unstated;
    }

    pub fn healthy(_: Cnav2Extra) bool {
        return true;
    }

    // Table 20-VIII has no code for L1C alone.
    pub fn almanacHealth(_: Cnav2Extra) u9 {
        return 0;
    }
};

fn allComponents(status: Status) Components {
    return .{ .l1 = status, .l2 = status, .l5 = status, .l1ca = status, .l1c = status, .l2c = status };
}

fn componentsOf(code: u5) Components {
    return switch (code) {
        0b00000 => allComponents(.ok),
        0b00001 => allComponents(.degraded),
        0b00010 => allComponents(.dead),
        0b00011 => allComponents(.degraded),
        0b00100, 0b00101, 0b00110 => .{ .l1 = .degraded },
        0b00111, 0b01000, 0b01001 => .{ .l2 = .degraded },
        // Table 20-VIII's "L1 C" is L1 C/A: ICD-GPS-200C wrote it before L1C existed.
        0b01010, 0b01100 => .{ .l1 = .degraded, .l1ca = .degraded },
        0b01011 => .{ .l1 = .degraded, .l1ca = .dead },
        0b01101, 0b01111 => .{ .l2 = .degraded, .l2c = .degraded },
        0b01110 => .{ .l2 = .degraded, .l2c = .dead },
        0b10000, 0b10001, 0b10010 => .{ .l1 = .degraded, .l2 = .degraded },
        0b10011, 0b10101 => .{ .l1 = .degraded, .l2 = .degraded, .l1ca = .degraded, .l2c = .degraded },
        0b10100 => .{ .l1 = .degraded, .l2 = .degraded, .l1ca = .dead, .l2c = .dead },
        0b10110, 0b11000 => .{ .l1 = .degraded, .l1ca = .degraded, .l1c = .degraded },
        0b10111 => .{ .l1 = .dead, .l1ca = .dead, .l1c = .dead },
        0b11001, 0b11011 => .{ .l2 = .degraded, .l2c = .degraded },
        0b11010 => .{ .l2 = .dead, .l2c = .dead },
        0b11100 => allComponents(.dead),
        0b11101 => allComponents(.degraded),
        0b11110 => .{ .l1 = .degraded, .l2 = .degraded, .l5 = .degraded, .l1ca = .unstated, .l1c = .unstated, .l2c = .unstated },
        0b11111 => allComponents(.unstated),
    };
}

fn carriers(l1: bool, l2: bool, l5: bool) u3 {
    return (@as(u3, @intFromBool(l1)) << 2) | (@as(u3, @intFromBool(l2)) << 1) | @intFromBool(l5);
}

fn lnavHealth(bits: u3) u9 {
    return switch (bits) {
        0b000, 0b001 => 0,
        0b100, 0b101 => 0b10111,
        0b010, 0b011 => 0b11010,
        0b110 => 0b111_11111,
        0b111 => 0b111_00010,
    };
}
