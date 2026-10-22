const std = @import("std");

pub fn parse(comptime E: type, text: []const u8) ?E {
    for (std.enums.values(E)) |value| {
        if (std.mem.eql(u8, E.words.get(value), text)) return value;
    }
    return null;
}

pub fn words(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (std.enums.values(E), 0..) |value, i| out = out ++ (if (i == 0) "" else ", ") ++ E.words.get(value);
        return out;
    }
}

pub fn choices(comptime E: type) []const u8 {
    comptime {
        const tags = std.enums.values(E);
        var out: []const u8 = "";
        for (tags, 0..) |value, i| out = out ++ (if (i == 0) "" else if (i + 1 == tags.len) " or " else ", ") ++ E.words.get(value);
        return out;
    }
}

pub fn tagNames(comptime E: type) std.EnumArray(E, []const u8) {
    var table: std.EnumArray(E, []const u8) = undefined;
    for (std.enums.values(E)) |value| table.set(value, @tagName(value));
    return table;
}
