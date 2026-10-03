const std = @import("std");
const Io = std.Io;

pub fn Pool(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        io: Io,
        ctx: *Ctx,
        threads: []std.Thread,
        mutex: Io.Mutex = .init,
        wake: Io.Condition = .init,
        done: Io.Condition = .init,
        generation: u64 = 0,
        quit: bool = false,
        job: Ctx.Job = undefined,
        count: u32 = 0,
        next: std.atomic.Value(u32) = .init(0),
        finished: u32 = 0,

        pub fn init(gpa: std.mem.Allocator, io: Io, ctx: *Ctx, n: u32) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{ .io = io, .ctx = ctx, .threads = &.{} };
            const threads = try gpa.alloc(std.Thread, n);
            errdefer gpa.free(threads);
            var spawned: u32 = 0;
            errdefer {
                self.threads = threads[0..spawned];
                self.deinitThreads();
            }
            for (threads, 0..) |*t, id| {
                t.* = try std.Thread.spawn(.{}, worker, .{ self, id });
                spawned += 1;
            }
            self.threads = threads;
            return self;
        }

        fn deinitThreads(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.quit = true;
            self.wake.broadcast(self.io);
            self.mutex.unlock(self.io);
            for (self.threads) |t| t.join();
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.deinitThreads();
            gpa.free(self.threads);
            gpa.destroy(self);
        }

        pub fn dispatch(self: *Self, job: Ctx.Job, count: u32) void {
            self.mutex.lockUncancelable(self.io);
            self.job = job;
            self.count = count;
            self.next.store(0, .monotonic);
            self.finished = 0;
            self.generation += 1;
            self.wake.broadcast(self.io);
            self.mutex.unlock(self.io);
        }

        pub fn join(self: *Self, job: Ctx.Job, count: u32) void {
            self.take(self.threads.len, job, count);
        }

        pub fn wait(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            while (self.finished < self.threads.len) self.done.waitUncancelable(self.io, &self.mutex);
            self.mutex.unlock(self.io);
        }

        fn take(self: *Self, id: usize, job: Ctx.Job, count: u32) void {
            while (true) {
                const i = self.next.fetchAdd(1, .monotonic);
                if (i >= count) break;
                self.ctx.runTask(id, job, i);
            }
        }

        fn worker(self: *Self, id: usize) void {
            var seen: u64 = 0;
            while (true) {
                self.mutex.lockUncancelable(self.io);
                while (!self.quit and self.generation == seen) self.wake.waitUncancelable(self.io, &self.mutex);
                if (self.quit) {
                    self.mutex.unlock(self.io);
                    return;
                }
                seen = self.generation;
                const job = self.job;
                const count = self.count;
                self.mutex.unlock(self.io);

                self.take(id, job, count);

                self.mutex.lockUncancelable(self.io);
                self.finished += 1;
                if (self.finished == self.threads.len) self.done.signal(self.io);
                self.mutex.unlock(self.io);
            }
        }
    };
}
