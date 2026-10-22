const dictionary = @import("base/text/dictionary");

pub const NavKind = enum {
    ephemeris,
    almanac,

    pub const words = dictionary.tagNames(NavKind);
};

pub const NavFile = struct { path: []const u8, kind: NavKind };
pub const PreciseFiles = struct { orbit: []const []const u8, clock: []const []const u8 };

pub const Names = struct {
    name: []const u8,
    trajectory_file: []const u8,
    trajectory_name: []const u8,
    nav_files: []const NavFile,
    antenna: ?[]const u8,
    precise: ?PreciseFiles,
};
