const std = @import("std");
const miku = @import("mikualloc.zig");

const BUFFER_CAPACITY = 256;

const mixed_rounds = 10_000_000;

const mixed_min = 80000;
const mixed_max = 80000;

const small_rounds = 10_000_000;
const small_min = 2048;
const small_max = 2048;

const medium_rounds = 10_000_000;
const medium_min = 32768;
const medium_max = 32768;

const big_rounds = 10_000_000;
const big_min = 4_194_04;
const big_max = 4_194_04;

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    const num_args = args.len - 1;

    if (num_args == 0) return try bench(1);

    for (0..num_args) |i| {
        const num_threads = try std.fmt.parseInt(u32, args[i + 1], 10);

        try bench(num_threads);
    }
}

fn bench(num_threads: u32) !void {
    try std.io.getStdOut().writer().print("=== Num Threads={} ===\n", .{num_threads});

    try std.io.getStdOut().writer().print("==Mixed Alloc==\n", .{});
    try miku_mixed(num_threads);
    // try smp_mixed(num_threads);
    // try miku_global_mixed(num_threads);
    try c_mixed(num_threads);

    // try gpa_mixed(num_threads);

    try std.io.getStdOut().writer().print("==Small Alloc==\n", .{});
    //
    try c_small(num_threads);
    try miku_small(num_threads);
    // try gpa_small(num_threads);
    //
    try std.io.getStdOut().writer().print("==Medium Alloc==\n", .{});
    //
    try c_medium(num_threads);
    try miku_medium(num_threads);
    // try gpa_medium(num_threads);
    //
    try std.io.getStdOut().writer().print("==Big Alloc==\n", .{});
    //
    try c_big(num_threads);
    try miku_big(num_threads);
    // try gpa_big(num_threads);
    //
    try std.io.getStdOut().writer().print("\n", .{});
}

///
/// Mixed
///
///
fn smp_mixed(num_threads: u32) !void {
    const smp = std.heap.smp_allocator;
    try runPerfTestAlloc("smp_mixed", mixed_min, mixed_max, smp, mixed_rounds, num_threads);
}

fn miku_mixed(num_threads: u32) !void {
    var miku_allocator = miku.MikuAllocator.init();
    // miku_allocator.init();
    const allocator = miku_allocator.allocator();

    try runPerfTestAlloc("miku/mixed", mixed_min, mixed_max, allocator, mixed_rounds, num_threads);
}

fn miku_global_mixed(num_threads: u32) !void {
    var miku_allocator = miku.MikuAllocator.init();
    // miku_allocator.init();

    const allocator = miku_allocator.allocator();

    try runPerfTestAlloc("miku_global_fixed/mixed", mixed_min, mixed_max, allocator, mixed_rounds, num_threads);
}

fn gpa_mixed(num_threads: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try runPerfTestAlloc("gpa/mixed", mixed_min, mixed_max, allocator, mixed_rounds, num_threads);
}

fn c_mixed(num_threads: u32) !void {
    const allocator = std.heap.c_allocator;

    try runPerfTestAlloc("c/mixed", mixed_min, mixed_max, allocator, mixed_rounds, num_threads);
}

//Small
//===========================

fn miku_small(num_threads: u32) !void {
    var miku_allocator = miku.MikuAllocator.init();

    const allocator = miku_allocator.allocator();

    try runPerfTestAlloc("miku/small", small_min, small_max, allocator, small_rounds, num_threads);
}

fn c_small(num_threads: u32) !void {
    const allocator = std.heap.c_allocator;

    try runPerfTestAlloc("c/small", small_min, small_max, allocator, small_rounds, num_threads);
}

fn miku_global_small(num_threads: u32) !void {
    const miku_allocator = miku.MikuAllocator.init();

    const allocator = miku_allocator.allocator();

    try runPerfTestAlloc("miku-global/small", small_min, small_max, allocator, small_rounds, num_threads);
}

fn gpa_small(num_threads: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try runPerfTestAlloc("gpa/small", small_min, small_max, allocator, small_rounds, num_threads);
}

///
/// Medium
///
fn miku_medium(num_threads: u32) !void {
    var miku_allocator = miku.MikuAllocator.init();
    const allocator = miku_allocator.allocator();

    try runPerfTestAlloc("miku/medium", medium_min, medium_max, allocator, medium_rounds, num_threads);
}

fn c_medium(num_threads: u32) !void {
    const allocator = std.heap.c_allocator;

    try runPerfTestAlloc("c/medium", medium_min, medium_max, allocator, medium_rounds, num_threads);
}

fn gpa_medium(num_threads: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try runPerfTestAlloc("gpa/medium", medium_min, medium_max, allocator, medium_rounds, num_threads);
}

///
/// Big
///
fn miku_big(num_threads: u32) !void {
    var miku_allocator = miku.MikuAllocator.init();

    const allocator = miku_allocator.allocator();

    try runPerfTestAlloc("miku/big", big_min, big_max, allocator, big_rounds, num_threads);
}

fn c_big(num_threads: u32) !void {
    const allocator = std.heap.c_allocator;

    try runPerfTestAlloc("c/big", big_min, big_max, allocator, big_rounds, num_threads);
}

fn gpa_big(num_threads: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try runPerfTestAlloc("gpa/big", big_min, big_max, allocator, big_rounds, num_threads);
}

//Copyright Joad Nacer

//Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

//The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

//THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

fn threadAllocWorker(params_ptr: *ThreadAllocWorkerParams) !void {
    const params = params_ptr.*;
    var slots = std.BoundedArray([]u8, BUFFER_CAPACITY){};
    var rounds: usize = params.max_rounds;

    var random_source = std.Random.DefaultPrng.init(1337 + params.thread_id);
    const rng = random_source.random();

    while (!params.start_flag.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    while (rounds > 0) {
        rounds -= 1;

        const free_chance = @as(f32, @floatFromInt(slots.len)) / @as(f32, @floatFromInt(slots.buffer.len - 1));
        const alloc_chance = 1.0 - free_chance;
        const alloc_amount = rng.intRangeAtMost(usize, params.min, params.max);

        if (slots.len > 0) {
            if (rng.float(f32) <= free_chance) {
                const index = rng.intRangeLessThan(usize, 0, slots.len);
                const ptr = slots.swapRemove(index);
                params.allocator.free(ptr);
            }
        }

        if (slots.len < slots.capacity()) {
            if (rng.float(f32) <= alloc_chance) {
                const item = try params.allocator.alloc(u8, alloc_amount);
                slots.appendAssumeCapacity(item);
            }
        }
    }

    for (slots.slice()) |ptr| {
        params.allocator.free(ptr);
    }
}

const ThreadAllocWorkerParams = struct {
    thread_id: usize,
    min: usize,
    max: usize,
    allocator: std.mem.Allocator,
    max_rounds: usize,
    start_flag: *std.atomic.Value(bool),
};

fn runPerfTestAlloc(tag: []const u8, min: usize, max: usize, allocator: std.mem.Allocator, max_rounds: usize, num_threads: u32) !void {
    var workers: []std.Thread = try std.heap.page_allocator.alloc(std.Thread, num_threads);

    defer std.heap.page_allocator.free(workers);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const params_array = try arena.allocator().alloc(ThreadAllocWorkerParams, num_threads);

    var start_flag = std.atomic.Value(bool).init(false);

    for (params_array, 0..) |*params, i| {
        params.* = .{
            .thread_id = i,
            .min = min,
            .max = max,
            .allocator = allocator,
            .max_rounds = max_rounds,
            .start_flag = &start_flag,
        };
        workers[i] = try std.Thread.spawn(.{}, threadAllocWorker, .{params});
    }

    start_flag.store(true, .release);
    var timer = try std.time.Timer.start();

    for (workers) |worker| {
        worker.join();
    }

    const elapsed_ns = timer.read();
    try std.io.getStdOut().writer().print(
        "time={d: >10.2}μs test={s} threads={d}\n",
        .{ @as(f64, @floatFromInt(elapsed_ns)) / 1000.0, tag, num_threads },
    );
}
