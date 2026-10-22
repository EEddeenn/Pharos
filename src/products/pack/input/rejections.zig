const std = @import("std");
const diagnostics = @import("base/diagnostics");
const gnss_types = @import("domain/gnss_types");
const civil = @import("domain/time/civil");

pub const Reason = enum { implausible, blank, mismatch, malformed, non_integral };
pub const RecordError = error{RejectedRecord};
pub const Named = union(enum) {
    record: struct { prn: u32, epoch: civil.Utc },
    label: []const u8,
};
pub const Rejection = struct {
    system: ?gnss_types.System,
    named: Named,
    message: []const u8,
    field: [:0]const u8 = "",
    reason: Reason = .implausible,
    location: ?diagnostics.Location = null,
    original_token: ?[]const u8 = null,

    pub fn fail(self: *Rejection, name: [:0]const u8, token: ?[]const u8, reason: Reason) RecordError {
        self.field = name;
        self.original_token = token;
        self.reason = reason;
        return error.RejectedRecord;
    }
};

/// One file's rejected records are summarized without retaining every rejected payload.
pub const Rejections = struct {
    groups: std.ArrayList(Group) = .empty,
    ignored: usize = 0,

    const Group = struct {
        first: Rejection,
        examples: [3]Named,
        count: usize,
    };

    pub fn add(self: *Rejections, arena: std.mem.Allocator, rejected: Rejection) std.mem.Allocator.Error!void {
        for (self.groups.items) |*group| {
            const first = group.first;
            if (first.system != rejected.system or first.reason != rejected.reason or
                !std.mem.eql(u8, first.message, rejected.message) or !std.mem.eql(u8, first.field, rejected.field)) continue;
            if (group.count < group.examples.len) group.examples[group.count] = rejected.named;
            group.count += 1;
            return;
        }
        var group: Group = .{ .first = rejected, .examples = undefined, .count = 1 };
        group.examples[0] = rejected.named;
        try self.groups.append(arena, group);
    }

    pub fn line(self: *Rejections, arena: std.mem.Allocator, system: ?gnss_types.System, message: []const u8, text: []const u8, number: usize, reason: Reason, field: [:0]const u8) std.mem.Allocator.Error!void {
        try self.add(arena, .{ .system = system, .message = message, .named = .{ .label = text[0..@min(text.len, 80)] }, .field = field, .reason = reason, .location = .{ .text = .{ .line = std.math.lossyCast(u32, number) } } });
    }

    pub fn ignore(self: *Rejections) void {
        self.ignored += 1;
    }

    pub fn report(self: *const Rejections, scope: diagnostics.Scope) std.mem.Allocator.Error!void {
        for (self.groups.items) |group| {
            var names: std.ArrayList(u8) = .empty;
            for (group.examples[0..@min(group.count, group.examples.len)], 0..) |named, i| {
                const separator = if (i == 0) "" else ", ";
                switch (named) {
                    .record => |at| try names.print(scope.diags.arena, "{s}{c}{d:0>2} {f}", .{ separator, group.first.system.?.rinexLetter(), at.prn, at.epoch }),
                    .label => |label| try names.print(scope.diags.arena, "{s}{f}", .{ separator, diagnostics.Escaped{ .text = label } }),
                }
            }
            if (group.count > group.examples.len) try names.print(scope.diags.arena, " and {d} more", .{group.count - group.examples.len});
            if (group.first.original_token) |token| try names.print(scope.diags.arena, "; token {f}", .{diagnostics.Escaped{ .text = token[0..@min(token.len, 80)] }});
            const reason: []const u8 = switch (group.first.reason) {
                .implausible => "is outside its allowed range",
                .blank => "is missing",
                .mismatch => "does not match the block's satellite",
                .malformed => "cannot be read",
                .non_integral => "must be a whole number",
            };
            const code: diagnostics.Code = switch (group.first.reason) {
                .implausible, .non_integral => .implausible_record,
                .blank => .missing_field,
                .mismatch, .malformed => .invalid_format,
            };
            try scope.warn(code, group.first.location, "{d} {s}{s}{s} record{s} skipped: {s}{s}{s}; {s}", .{
                group.count,                                                      if (group.first.system) |system| system.name() else "", if (group.first.system != null) " " else "", group.first.message, if (group.count == 1) "" else "s",
                if (group.first.field.len == 0) "a field" else group.first.field, " ",                                                    reason,                                      names.items,
            });
        }
        if (self.ignored != 0) try scope.note(.ignored_records, null, "{d} record{s} from systems, messages or slots not modelled by this core skipped", .{ self.ignored, if (self.ignored == 1) "" else "s" });
    }
};
