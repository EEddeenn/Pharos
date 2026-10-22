const std = @import("std");

const Io = std.Io;

const spin_limit = 1 << 12;

pub fn Pool(comptime Ctx: type) type {
    return struct {
        gpa: std.mem.Allocator,
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

        const Self = @This();

        pub fn create(gpa: std.mem.Allocator, io: Io, ctx: *Ctx, n: u32) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{ .gpa = gpa, .io = io, .ctx = ctx, .threads = &.{} };
            const threads = try gpa.alloc(std.Thread, n);
            errdefer gpa.free(threads);
            var spawned: u32 = 0;
            errdefer {
                self.threads = threads[0..spawned];
                self.stopThreads();
            }
            for (threads, 0..) |*t, id| {
                t.* = try std.Thread.spawn(.{}, worker, .{ self, id });
                spawned += 1;
            }
            self.threads = threads;
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.stopThreads();
            self.gpa.free(self.threads);
            self.gpa.destroy(self);
        }

        pub fn run(self: *Self, job: Ctx.Job, count: u32) void {
            self.mutex.lockUncancelable(self.io);
            self.job = job;
            self.count = count;
            self.generation += 1;
            const gen: u32 = @truncate(self.generation);
            self.completed.store(0, .monotonic);
            self.next.store(@as(u64, gen) << 32, .monotonic);
            self.mutex.unlock(self.io);
            self.wake.broadcast(self.io);
            self.take(self.threads.len, gen, job, count);
            // The job's last tasks are running on other threads: watch for them a while before sleeping.
            for (0..spin_limit) |_| {
                if (self.completed.load(.acquire) == count) return;
                std.atomic.spinLoopHint();
            }
            self.mutex.lockUncancelable(self.io);
            while (self.completed.load(.acquire) < count) self.done.waitUncancelable(self.io, &self.mutex);
            self.mutex.unlock(self.io);
        }

        fn stopThreads(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.quit = true;
            self.wake.broadcast(self.io);
            self.mutex.unlock(self.io);
            for (self.threads) |t| t.join();
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
