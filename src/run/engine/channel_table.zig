const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const types = core.types;
const spec = gnss.spec;
const msg = @import("../msg.zig");
const stage = @import("shared").stage;
const geometry = @import("geometry.zig");
const events = @import("events.zig");
const tables = @import("../synth.zig").tables;
const params = @import("../synth.zig").params;
const Epoch = core.time.Epoch;

pub const Channel = struct {
    key: types.ChannelKey,
    track: usize,
    synth: params.ChannelConstants,
    freq: ?types.FreqId,
    symbols: msg.symbol.SymbolSource,
    first_epoch: Epoch,
    last_epoch: ?Epoch = null,

    pub fn activeAt(self: *const Channel, epoch: Epoch) bool {
        const last = self.last_epoch orelse return epoch.ms >= self.first_epoch.ms;
        return epoch.ms >= self.first_epoch.ms and epoch.ms < last.ms;
    }
};

pub const ChannelTable = struct {
    gpa: std.mem.Allocator,
    channels: std.ArrayList(Channel) = .empty,
    center: core.types.Hz,
    changes: u64 = 0,
    entry_epoch: Epoch = .zero,
    generated: std.EnumSet(types.Signal) = .empty,

    pub fn init(gpa: std.mem.Allocator, center: core.types.Hz) ChannelTable {
        return .{ .gpa = gpa, .center = center };
    }

    pub fn deinit(self: *ChannelTable) void {
        self.channels.deinit(self.gpa);
    }

    pub fn reset(self: *ChannelTable) void {
        self.channels.clearRetainingCapacity();
        self.changes = 0;
        self.entry_epoch = .zero;
        self.generated = .empty;
    }

    fn find(self: *const ChannelTable, key: types.ChannelKey) ?*Channel {
        for (self.channels.items) |*c| {
            if (c.last_epoch == null and c.key == key) return c;
        }
        return null;
    }

    pub fn prune(self: *ChannelTable, epoch: Epoch) void {
        var i: usize = 0;
        while (i < self.channels.items.len) {
            if (self.channels.items[i].last_epoch) |last| if (last.ms <= epoch.ms) {
                _ = self.channels.orderedRemove(i);
                continue;
            };
            i += 1;
        }
    }

    pub fn enter(self: *ChannelTable, epoch: Epoch, ring: *events.Ring) void {
        self.prune(epoch);
        self.entry_epoch = epoch;
        self.generated = .empty;
        for (self.channels.items) |c| {
            self.generated.insert(c.key.signal);
            ring.push(.{ .channel_added = .{ .epoch = epoch, .key = c.key } });
        }
    }

    pub fn apply(self: *ChannelTable, epoch: Epoch, changes: []const stage.sequence.Change, rows: []const geometry.Row, table_set: *const tables.TableSet, snapshot: stage.messages.Snapshot, payload: *const gnss.payload.Payload, ring: *events.Ring) !void {
        for (changes) |change| {
            const row = rows[change.track];
            const key = types.ChannelKey.init(row.sat, change.signal);
            if (change.state != .held) {
                const c = self.find(key) orelse continue;
                c.last_epoch = epoch;
                self.changes += 1;
                ring.push(.{ .channel_removed = .{ .epoch = epoch, .key = key } });
                continue;
            }
            const row_spec = spec.get(change.signal);
            const freq = row.seen.?.delays.freq;
            const carrier = row_spec.carrierHz(freq);
            const code = row_spec.code;
            try self.channels.append(self.gpa, .{
                .key = key,
                .track = change.track,
                .synth = .{
                    .if_hz = @as(i64, @intCast(carrier)) - self.center.hz,
                    .code_ms = code.data_period_ms,
                    .entries_per_ms = code.entriesPerMs(),
                    .scale = row_spec.signal.system(),
                    .table = table_set.find(key) orelse return error.Internal,
                },
                .freq = freq,
                .symbols = msg.symbol.SymbolSource.init(stage.messages.forChannel(snapshot, payload, key).?, row.sat, change.signal),
                .first_epoch = epoch,
            });
            self.changes += 1;
            ring.push(.{ .channel_added = .{ .epoch = epoch, .key = key } });
        }
        if (epoch.ms == self.entry_epoch.ms) self.generated = .empty;
        for (self.channels.items) |c| {
            if (c.last_epoch == null) self.generated.insert(c.key.signal);
        }
    }
};
