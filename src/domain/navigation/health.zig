pub const Status = enum {
    ok,
    degraded,
    dead,
    unstated,

    pub fn flies(self: Status) bool {
        return self != .dead;
    }
};

pub const almanac_health_all: u9 = 0x1FF;

pub fn flagged(set: bool) Status {
    return if (set) .degraded else .ok;
}
