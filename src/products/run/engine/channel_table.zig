const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const signal_catalog = @import("domain/signals/catalog");
const sampling = @import("simulation/model/sampling");
const channel_selection = @import("simulation/state/channels");
const message_sets = @import("simulation/state/messages");
const symbol_source = @import("products/run/symbols/source");
const tables = @import("products/run/synthesis/code_tables");
const params = @import("products/run/synthesis/parameters");
const events = @import("products/run/engine/events");

const Payload = @import("domain/signals/payload").Payload;
const Epoch = @import("domain/time/gps").Epoch;

pub const Channel = struct {
    key: gnss_types.ChannelKey,
    track: usize,
    synth: params.ChannelConstants,
    freq: ?gnss_types.FreqId,
    symbols: symbol_source.SymbolSource,
    first_epoch: Epoch,
};

pub const ChannelTable = struct {
    channels: std.ArrayList(Channel),
    center: sampling.Hz,
    entry_epoch: Epoch = .zero,
    generated: std.EnumSet(gnss_types.Signal) = .empty,

    pub fn init(gpa: std.mem.Allocator, capacity: usize, center: sampling.Hz) error{OutOfMemory}!ChannelTable {
        return .{ .channels = try .initCapacity(gpa, capacity), .center = center };
    }

    pub fn deinit(self: *ChannelTable, gpa: std.mem.Allocator) void {
        self.channels.deinit(gpa);
    }

    fn close(self: *ChannelTable, epoch: Epoch, key: gnss_types.ChannelKey, ring: *events.Ring) bool {
        for (self.channels.items, 0..) |c, index| if (c.key == key) {
            _ = self.channels.orderedRemove(index);
            ring.push(.{ .channel_removed = .{ .epoch = epoch, .key = key } });
            return true;
        };
        return false;
    }

    pub fn reset(self: *ChannelTable) void {
        self.channels.clearRetainingCapacity();
        self.entry_epoch = .zero;
        self.generated = .empty;
    }

    pub fn enter(self: *ChannelTable, epoch: Epoch, ring: *events.Ring) void {
        self.entry_epoch = epoch;
        self.generated = .empty;
        for (self.channels.items) |c| {
            self.generated.insert(c.key.signal);
            ring.push(.{ .channel_added = .{ .epoch = epoch, .key = c.key } });
        }
    }

    pub fn apply(self: *ChannelTable, epoch: Epoch, changes: []const channel_selection.Change, sats: []const gnss_types.SatId, codes: *const tables.TableSet, sets: message_sets.SetView, payload: *const Payload, ring: *events.Ring) bool {
        var changed = false;
        for (changes) |change| {
            const sat = sats[change.track];
            const key: gnss_types.ChannelKey = .{ .sat = sat, .signal = change.signal };
            const freq = switch (change.action) {
                .state => {
                    changed = self.close(epoch, key, ring) or changed;
                    continue;
                },
                .enter => |freq| freq,
                .readmit => |freq| blk: {
                    _ = self.close(epoch, key, ring);
                    break :blk freq;
                },
            };
            const row = signal_catalog.get(change.signal);
            self.channels.appendAssumeCapacity(.{
                .key = key,
                .track = change.track,
                .synth = .{
                    .if_hz = @as(i64, @intCast(row.carrierHz(freq))) - self.center.hz,
                    .code_ms = row.code.period_ms,
                    .entries_per_ms = row.entriesPerMs(),
                    .scale = row.signal.system(),
                    .table = codes.find(key).?,
                },
                .freq = freq,
                .symbols = .init(message_sets.forChannel(sets, payload, key).?, sat, change.signal),
                .first_epoch = epoch,
            });
            changed = true;
            ring.push(.{ .channel_added = .{ .epoch = epoch, .key = key } });
        }
        if (epoch.ms == self.entry_epoch.ms) self.generated = .empty;
        for (self.channels.items) |c| self.generated.insert(c.key.signal);
        return changed;
    }
};
