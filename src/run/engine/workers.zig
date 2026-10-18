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
        // The job's generation in the high half and its next task in the low, so a worker that wakes late for a job
        // takes nothing of a later one, and a job ends with its last task, however many workers have woken.
        next: std.atomic.Value(u64) = .init(0),
        completed: std.atomic.Value(u32) = .init(0),

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

        pub fn dispatch(self: *Self, job: Ctx.Job, count: u32) u32 {
            self.mutex.lockUncancelable(self.io);
            self.job = job;
            self.count = count;
            self.generation += 1;
            const gen: u32 = @truncate(self.generation);
            self.completed.store(0, .monotonic);
            self.next.store(@as(u64, gen) << 32, .monotonic);
            self.wake.broadcast(self.io);
            self.mutex.unlock(self.io);
            return gen;
        }

        pub fn join(self: *Self, gen: u32, job: Ctx.Job, count: u32) void {
            self.take(self.threads.len, gen, job, count);
        }

        pub fn wait(self: *Self, count: u32) void {
            self.mutex.lockUncancelable(self.io);
            while (self.completed.load(.acquire) < count) self.done.waitUncancelable(self.io, &self.mutex);
            self.mutex.unlock(self.io);
        }

        fn take(self: *Self, id: usize, gen: u32, job: Ctx.Job, count: u32) void {
            var v = self.next.load(.monotonic);
            while (@as(u32, @truncate(v >> 32)) == gen and @as(u32, @truncate(v)) < count) {
                if (self.next.cmpxchgWeak(v, v + 1, .monotonic, .monotonic)) |actual| {
                    v = actual;
                    continue;
                }
                self.ctx.runTask(id, job, @truncate(v));
                if (self.completed.fetchAdd(1, .acq_rel) + 1 == count) {
                    self.mutex.lockUncancelable(self.io);
                    self.done.signal(self.io);
                    self.mutex.unlock(self.io);
                }
                v = self.next.load(.monotonic);
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
                const gen: u32 = @truncate(self.generation);
                const job = self.job;
                const count = self.count;
                self.mutex.unlock(self.io);

                self.take(id, gen, job, count);
            }
        }
    };
}
