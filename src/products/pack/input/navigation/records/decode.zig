const time = @import("domain/time/gps");
const records = @import("domain/navigation/records");
const plausible = @import("products/pack/input/admission/navigation");
const fields = @import("products/pack/input/navigation/fields");

pub const Failure = enum { malformed, blank, non_integral, out_of_range };
pub const Blank = error{BlankField};
pub const Error = fields.Error || Blank;

pub const Body = struct {
    rows: []const [4]?f64,
    source_lines: []const []const u8,
    token: ?[]const u8 = null,
    field: [:0]const u8 = "",
    failure: Failure = .malformed,

    pub fn get(self: *Body, row: usize, col: usize, comptime name: [:0]const u8) Blank!f64 {
        self.field = name;
        self.token = fields.column(self.source_lines[row], 4 + 19 * col, 19);
        self.failure = .malformed;
        return self.rows[row][col] orelse {
            self.failure = .blank;
            return error.BlankField;
        };
    }

    pub fn integer(self: *Body, comptime T: type, row: usize, col: usize, comptime name: [:0]const u8) Error!T {
        return self.integerValue(T, try self.get(row, col, name), name);
    }

    pub fn integerValue(self: *Body, comptime T: type, value: f64, comptime name: [:0]const u8) fields.Error!T {
        self.field = name;
        return fields.integerValue(T, value) catch |err| {
            self.failure = switch (err) {
                error.NonIntegral => .non_integral,
                error.OutOfRange => .out_of_range,
            };
            return error.MalformedRecord;
        };
    }

    pub fn optionalInteger(self: *Body, comptime T: type, row: usize, col: usize, comptime name: [:0]const u8) fields.Error!?T {
        const value = self.opt(row, col) orelse return null;
        self.token = fields.column(self.source_lines[row], 4 + 19 * col, 19);
        return try self.integerValue(T, value, name);
    }

    pub fn opt(self: *const Body, row: usize, col: usize) ?f64 {
        return self.rows[row][col];
    }

    pub fn putDelay(self: *const Body, delays: *records.GroupDelays, term: records.GroupDelayTerm, row: usize, col: usize) void {
        if (self.opt(row, col)) |v| delays.put(term, v);
    }
};

pub const Completion = struct {
    toe: time.GpsTime,
    toc: time.GpsTime,
    iode: u16 = 0,
    iodc: u16 = 0,
    top: ?time.GpsTime = null,
    a_dot: f64 = 0,
    delta_n_dot: f64 = 0,
    group_delay: records.GroupDelays = records.GroupDelays.init(.{}),
    extra: @FieldType(records.KeplerEphemeris, "extra"),
};

pub const Toe = struct { week: i64, ms: i64 };

pub fn sowNearReference(ref: time.ScaleTime, sow: f64) fields.Error!time.GpsTime {
    if (!(sow >= 0 and sow < time.s_per_week)) return error.MalformedRecord;
    const s: i64 = @intFromFloat(@round(sow));
    const ref_s: i64 = ref.ms / 1000;
    var week = ref.period;
    if (s - ref_s > plausible.half_week_s) week -= 1;
    if (ref_s - s > plausible.half_week_s) week += 1;
    return time.GpsTime.fromScaleWeekMs(ref.scale, week, s * 1000, 0);
}

pub fn toeOfBody(body: *Body) Error!Toe {
    const toe_sow = try body.get(2, 0, "toe");
    if (!(toe_sow >= 0 and toe_sow < time.s_per_week)) return error.MalformedRecord;
    const week = try body.integer(i64, 4, 2, "week");
    if (week < 0 or week > time.max_week) {
        body.failure = .out_of_range;
        return error.MalformedRecord;
    }
    return .{ .week = week, .ms = @intFromFloat(@round(toe_sow * 1000.0)) };
}

pub fn bitsOf(comptime T: type, body: *Body, row: usize, col: usize, comptime name: [:0]const u8) Error!T {
    const n = try body.integer(i64, row, col, name);
    const width = @typeInfo(T).int.bits;
    if (n < -(1 << (width - 1)) or n >= 1 << width) {
        body.failure = .out_of_range;
        return error.MalformedRecord;
    }
    return @intCast(@mod(n, 1 << width));
}
