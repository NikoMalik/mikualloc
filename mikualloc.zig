const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const math = std.math;
const AtomicUsize = std.atomic.Value(usize);
const simd = std.simd;
const mimalloc = @cImport({
    @cInclude("mimalloc.h");
});

comptime {
    assert(!builtin.single_threaded);
}

//============================================================================================//
//CONSTS
pub const KB = @as(usize, 1024);
pub const MB = KB << 1;
pub const MI_MAX_ALIGN_SIZE = 16;
pub const MI_SMALL_SIZE_MAX: usize = 128 * @sizeOf(*anyopaque);
const SHIFT_CTZ = 4;

const min_class = math.log2(math.ceilPowerOfTwoAssert(usize, 1 + @sizeOf(usize)));
const slab_len = math.ceilPowerOfTwo(usize, @max(std.heap.page_size_max, 64 * KB)) catch unreachable;
const slab_log2 = math.log2(slab_len);
const size_class_count = slab_log2 - min_class;
const max_alloc_search = 1;

const cache_small = 64;
const cache_big = 512;

const isDebug = std.builtin.Mode.Debug == builtin.mode;
const isRelease = std.builtin.Mode.Debug != builtin.mode and !isTest;
const isTest = builtin.is_test;
const allow_assert = isDebug or isTest or std.builtin.OptimizeMode.ReleaseSafe == builtin.mode;

//============================================================================================//

const Me = @This();

const max_thread_count = 256;

cpu_count: u32,
threads: [max_thread_count]Thread,

var global: Me = .{
    .threads = @splat(.{}),

    .cpu_count = 0,
};

threadlocal var thread_index: u32 = 0;

inline fn getCpuCount() u32 {
    const cpu_count = @atomicLoad(u32, &global.cpu_count, .unordered);
    if (cpu_count != 0) return cpu_count;
    const n: u32 = @min(std.Thread.getCpuCount() catch max_thread_count, max_thread_count);
    return if (@cmpxchgStrong(u32, &global.cpu_count, 0, n, .monotonic, .monotonic)) |other| other else n;
}

//===========================================================================//
const Cache = struct {
    const num_lists = size_class_count;
    const cache_size = cache_big;

    free_masks: [num_lists]usize = @splat(0),
    free_ptrs: [num_lists][cache_size]usize = [_][cache_size]usize{[_]usize{0} ** cache_size} ** num_lists,

    inline fn hasSpace(self: *Cache, class: usize) bool {
        return self.free_masks[class] != @bitSizeOf(usize) - @ctz(class - 1);
    }

    pub fn init() Cache {
        return .{
            .free_masks = @splat(0),
            .free_ptrs = std.mem.zeroes([num_lists][cache_size]usize),
        };
    }

    inline fn tryWrite(self: *Cache, class: usize, ptr: [*]u8) bool {
        if (comptime allow_assert) {
            assert(class < num_lists);
        }
        const mask = self.free_masks[class];
        const free_slot = @ctz(~mask);

        if (free_slot >= cache_size) return false;

        self.free_ptrs[class][free_slot] = @intFromPtr(ptr);
        self.free_masks[class] |= @as(usize, 1) << @as(u6, @intCast(free_slot));
        return true;
    }

    inline fn tryRead(self: *Cache, class: usize) ?[*]u8 {
        if (comptime allow_assert) {
            assert(class < num_lists);
        }
        const mask = self.free_masks[class];
        if (mask == 0) return null;

        const used_slot = @ctz(mask);

        @prefetch(&self.free_ptrs[class][used_slot], .{ .rw = .read, .locality = 3 });

        const ptr = self.free_ptrs[class][used_slot];
        self.free_masks[class] &= ~(@as(usize, 1) << @as(u6, @intCast(used_slot)));
        return @ptrFromInt(ptr);
    }

    inline fn isPointerInCache(self: *Cache, ptr: [*]u8) bool {
        const target = @intFromPtr(ptr);

        for (0..num_lists) |class| {
            const mask = self.free_masks[class];
            var bits = mask;

            while (bits != 0) {
                const idx = @ctz(bits);
                bits &= bits - 1;

                if (self.free_ptrs[class][idx] == target) return true;
            }
        }
        return false;
    }

    inline fn isEmpty(self: *Cache, list_idx: usize) bool {
        return self.free_masks[list_idx] == 0;
    }
};
threadlocal var threadCache: Cache = Cache.init();

//===========================================================================//

//===========================================================================//
pub const SpinLock = struct {
    _: void align(std.atomic.cache_line) = {},
    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    pub fn acquire(self: *SpinLock) void {
        var attempts: u32 = 0;
        while (true) {
            if (self.locked.cmpxchgWeak(
                0,
                1,
                .acquire,
                .monotonic,
            )) |_| {
                for (
                    0..3,
                ) |_| @prefetch(&self.locked, .{
                    .rw = .read,
                    .locality = 1,
                    .cache = .data,
                });

                attempts += 1;
            } else {
                break;
            }
        }
    }

    pub inline fn tryLock(self: *SpinLock) bool {
        return self.locked.cmpxchgWeak(
            0,
            1,
            .acquire,
            .monotonic,
        ) == null;
    }

    pub inline fn release(self: *SpinLock) void {
        self.locked.store(
            0,
            .release,
        );
    }
};

//===========================================================================//

//==========================================================================//
const Thread = struct {
    /// Avoid false sharing.
    _: void align(std.atomic.cache_line) = {},
    mutex: SpinLock = .{ .locked = .{ .raw = 0 } },
    next_addrs: [size_class_count]usize = @splat(0),
    frees: [size_class_count]usize = @splat(0),
    inline fn lock() *Thread {
        const cpu_count = getCpuCount();

        while (true) {
            var t = &global.threads[thread_index];
            if (t.mutex.tryLock()) return t;

            const index = (thread_index) % cpu_count;
            t = &global.threads[index];
            if (t.mutex.tryLock()) {
                thread_index = index;
                return t;
            }
        }
    }

    inline fn unlock(t: *Thread) void {
        t.mutex.release();
    }
};
//==========================================================================//

//==========================================================================//

pub const MikuAllocator = struct {
    pub const malloc_size = mimalloc.mi_malloc_size;

    const size_classes = blk: {
        var classes: [size_class_count]usize = undefined;
        var i: usize = 0;

        while (i < size_class_count) : (i += 1) {
            classes[i] = (1 << (i + min_class));
        }
        break :blk classes;
    };
    const Self = @This();

    pub fn init() Self {
        mimalloc.mi_option_disable(mimalloc.mi_option_eager_commit);
        mimalloc.mi_option_enable(mimalloc.mi_option_reserve_huge_os_pages);

        return .{};
    }

    //==========================================================================//
    inline fn sizeClassIndex(
        len: usize,
        alignment: std.mem.Alignment,
    ) usize {
        return @max(@bitSizeOf(usize) - @clz(len - 1), @intFromEnum(alignment), min_class) - min_class;
    }

    // ==================================================================//

    inline fn slotSize(class: usize) usize {
        return size_classes[class];
    }

    pub fn allocator(
        self: *Self,
    ) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        const allocated = @call(std.builtin.CallModifier.always_inline, alignedAlloc, .{ len, alignment });
        return allocated;
    }

    fn alignedAlloc(
        len: usize,
        alignment: std.mem.Alignment,
    ) ?[*]align(MI_MAX_ALIGN_SIZE) u8 {
        const class = sizeClassIndex(len, alignment);

        if (len >= cache_small and len <= cache_big) {
            @branchHint(.likely);
            if (threadCache.hasSpace(class)) {
                // if (comptime allow_assert) {
                //     std.debug.print("has space bro", .{});
                // }
                if (threadCache.tryRead(class)) |cached_ptr| {
                    return @alignCast(@ptrCast(cached_ptr));
                }
            }
        }

        if (class >= size_class_count) {
            @branchHint(.unlikely);
            return @alignCast(@ptrCast(mimalloc.mi_malloc_aligned(len, alignment.toByteUnits())));
        }

        const slot_size = slotSize(class);
        if (comptime allow_assert) {
            assert(slab_len % slot_size == 0);
        }
        var search_count: u8 = 0;

        var t = Thread.lock();

        outer: while (true) {
            const top_free_ptr = t.frees[class];
            if (top_free_ptr != 0) {
                @branchHint(.likely);
                defer t.unlock();
                const node: *usize = @ptrFromInt(top_free_ptr);
                t.frees[class] = node.*;
                const addr: [*]u8 = @ptrFromInt(top_free_ptr);
                return @alignCast(addr);
            }

            const next_addr = t.next_addrs[class];
            if ((next_addr % slab_len) != 0) {
                @branchHint(.likely);
                defer t.unlock();
                t.next_addrs[class] = next_addr + slot_size;
                const addr: [*]u8 = @ptrFromInt(next_addr);
                return @alignCast(addr);
            }

            if (search_count >= max_alloc_search) {
                @branchHint(.likely);
                defer t.unlock();
                const slab_alignment = std.mem.Alignment.fromByteUnits(slab_len);
                const slab = mimalloc.mi_malloc_aligned(slab_len, slab_alignment.toByteUnits()) orelse return null; // 65569
                if (comptime allow_assert) {
                    assert(@intFromPtr(slab) % slab_len == 0);
                }
                t.next_addrs[class] = @intFromPtr(slab) + slot_size;
                return @alignCast(@ptrCast(slab));
            }

            t.unlock();
            const cpu_count = getCpuCount();
            if (comptime allow_assert) {
                assert(cpu_count != 0);
            }
            var index = thread_index;
            while (true) {
                @branchHint(.unlikely);
                index = (index + 1) % cpu_count;
                t = &global.threads[index];
                if (t.mutex.tryLock()) {
                    thread_index = index;
                    search_count += 1;
                    continue :outer;
                }
            }
        }
    }

    inline fn canUseAlign(
        alignment: std.mem.Alignment,
        _: usize,
    ) bool {
        const align_bytes = alignment.toByteUnits();
        return @ctz(align_bytes) <= SHIFT_CTZ; // alignment <= 16 bytes
        // return @ctz(align_bytes) <= @ctz(MI_MAX_ALIGN_SIZE);
    }
    inline fn size_ptr(
        ptr: [*]u8,
    ) usize {
        return @as(usize, @intCast(mimalloc.mi_malloc_usable_size(ptr)));
    }

    fn resize(
        _: *anyopaque,
        buf: []u8,
        log2_align: std.mem.Alignment,
        new_len: usize,
        _: usize,
    ) bool {
        if (comptime allow_assert) {
            const alignment = log2_align.toByteUnits();
            assert(new_len > 0);
            assert(buf.len > 0);
            assert(alignment > 0);
        }
        const class = sizeClassIndex(buf.len, log2_align);
        const new_class = sizeClassIndex(new_len, log2_align);
        if (class >= size_class_count) {
            if (new_class < size_class_count) return false;
            if (new_len <= buf.len) {
                return true;
            }

            const available = size_ptr(buf.ptr);

            if (available >= new_len) {
                if (mimalloc.mi_expand(buf.ptr, new_len)) |_| {
                    return true;
                }
            }
        }

        return new_class == class;
        // return false;
    }

    fn free(
        _: *anyopaque,
        buf: []u8,
        log2_align: std.mem.Alignment,
        _: usize,
    ) void {
        if (comptime allow_assert) {
            assert(mimalloc.mi_is_in_heap_region(buf.ptr));
            assert(@intFromPtr(buf.ptr) != 0x00);
        }

        const actual_size: usize = buf.len;

        // const size_ptr_buf = size_ptr(buf.ptr);
        // if (comptime allow_assert) {
        //     std.debug.print("usable_size : {d}\n", .{size_ptr_buf});
        // }

        const class = sizeClassIndex(actual_size, log2_align);

        const aligned_size = log2_align.toByteUnits();
        if (class >= size_class_count) {
            @branchHint(.unlikely);

            mimalloc.mi_free_size_aligned(buf.ptr, actual_size, aligned_size);

            return;
        }

        if (class < size_class_count and threadCache.free_masks[class] < cache_big) {
            if (threadCache.tryWrite(class, buf.ptr)) {
                return;
            }
        }
        const node: *usize = @ptrCast(@alignCast(buf.ptr));
        const t = Thread.lock();
        defer t.unlock();

        node.* = t.frees[class];
        t.frees[class] = @intFromPtr(node);
    }
};

inline fn isPointerInThreadFreeList(ptr: [*]u8) bool {
    const t = Thread.lock();
    defer t.unlock();
    for (t.frees) |head| {
        var current = head;
        while (current != 0) {
            if (current == @intFromPtr(ptr)) return true;
            const node = @as(*usize, @ptrFromInt(current));
            current = node.*;
        }
    }
    return false;
}

//==========================================================================//

test "basic allocation" {
    std.debug.print("hallo\n", .{});
    var miku = MikuAllocator.init();
    const allocator = miku.allocator();

    const ptr = try allocator.alloc(u8, 100);
    allocator.free(ptr);
}

test "free from thread list" {
    var miku = MikuAllocator.init();
    const allocator = miku.allocator();

    const mem = try allocator.alloc(u8, 512);
    allocator.free(mem);
    const mem2 = try allocator.alloc(u8, 512);
    try std.testing.expect(mem.ptr == mem2.ptr);
}

test "hello wolrd alloc" {
    std.debug.print("hello world alloc\n", .{});

    var miku = MikuAllocator.init();
    const allocator = miku.allocator();

    const hello = "Hello World\n";
    const ptr = try allocator.dupe(u8, hello);
    const usable_size = MikuAllocator.size_ptr(ptr.ptr);
    std.debug.print("size_ptr :{d}", .{usable_size});
    const ptr_2 = try allocator.dupe(u8, hello);
    std.debug.print("size_ptr_2 : {d}", .{MikuAllocator.size_ptr(ptr_2.ptr)});
    // defer allocator.free(ptr);
    std.debug.print("ptr: {s}\n", .{ptr});
}

test "Allocation failure" {
    var miku = MikuAllocator.init();
    const allocator = miku.allocator();

    _ = allocator.alloc(u8, std.math.maxInt(usize)) catch |err| {
        std.debug.assert(err == error.OutOfMemory);
        return;
    };

    @panic("Should not reach here!");
}

test "usable_size" {
    var miku = MikuAllocator.init();
    const allocator = miku.allocator();
    const ptr = try allocator.alloc(u8, 32);
    defer allocator.free(ptr);
    const usable_size = MikuAllocator.size_ptr(ptr.ptr);
    assert(usable_size >= 32);
}
//
test "Benchmark gpa" {
    var gpu = std.heap.GeneralPurposeAllocator(.{ .verbose_log = false, .safety = false }){};
    const gpuAllocator = gpu.allocator();

    const start = std.time.nanoTimestamp();

    for (0..1_000_000) |_| {
        const ptr = try gpuAllocator.alloc(u8, 32);
        gpuAllocator.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "gpa", duration });
}

test "Benchmark c_allocator " {
    var heap = std.heap.c_allocator;

    const start = std.time.nanoTimestamp();

    for (0..1_000_000) |_| {
        const ptr = try heap.alloc(u8, 32);
        heap.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "c_allocator", duration });
}

test "Benchmark miku" {
    var miku = MikuAllocator.init();
    const mikuAllocator = miku.allocator();

    const start = std.time.nanoTimestamp();

    for (0..1_000_000) |_| {
        const ptr = try mikuAllocator.alloc(u8, 32);
        mikuAllocator.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "mikualloc", duration });
}

test "Benchmark smp" {
    const smp = std.heap.smp_allocator;

    const start = std.time.nanoTimestamp();

    for (0..1_000_000) |_| {
        const ptr = try smp.alloc(u8, 32);
        smp.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "smp", duration });
}

test "Benchmark malloc" {
    const start = std.time.nanoTimestamp();

    for (0..1_000_000) |_| {
        const ptr = std.c.malloc(32);
        std.c.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "malloc", duration });
}

test "Benchmark mimalloc" {
    const start = std.time.nanoTimestamp();

    for (0..1_000_000) |_| {
        const ptr = mimalloc.mi_malloc_small(32);
        mimalloc.mi_free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "mimmaloc", duration });
}

// 1KB ALLOC
// ===========
//
//
test "Benchmark gpa/1" {
    var gpu = std.heap.GeneralPurposeAllocator(.{ .verbose_log = false, .safety = false }){};
    const gpuAllocator = gpu.allocator();

    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = try gpuAllocator.alloc(u8, KB);
        gpuAllocator.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "gpa_kb", duration });
}

test "Benchmark c_allocator/1 " {
    var heap = std.heap.c_allocator;

    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = try heap.alloc(u8, KB);
        heap.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "c_allocator_kb", duration });
}

test "Benchmark miku/1" {
    var miku = MikuAllocator{};
    const mikuAllocator = miku.allocator();

    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = try mikuAllocator.alloc(u8, KB);
        mikuAllocator.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "mikualloc_kb", duration });
}

test "Benchmark smp/1" {
    const smp = std.heap.smp_allocator;

    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = try smp.alloc(u8, KB);
        smp.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "smp_kb", duration });
}

test "Benchmark malloc/1" {
    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = std.c.malloc(KB);
        std.c.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "malloc_kb", duration });
}

test "Benchmark mimalloc/1" {
    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = mimalloc.mi_malloc(KB);
        mimalloc.mi_free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "mimmaloc_kb", duration });
}

//===========
//1 MB ALLOC
//===========
test "Benchmark gpa/2" {
    var gpu = std.heap.GeneralPurposeAllocator(.{ .verbose_log = false, .safety = false }){};
    const gpuAllocator = gpu.allocator();

    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = try gpuAllocator.alloc(u8, MB);
        gpuAllocator.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "gpa_kb", duration });
}

test "Benchmark c_allocator/2 " {
    var heap = std.heap.c_allocator;

    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = try heap.alloc(u8, MB);
        heap.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "c_allocator_mb", duration });
}

test "Benchmark miku/2" {
    var miku = MikuAllocator.init();
    const mikuAllocator = miku.allocator();

    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = try mikuAllocator.alloc(u8, MB);
        mikuAllocator.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "mikualloc_mb", duration });
}

test "Benchmark smp/2" {
    const smp = std.heap.smp_allocator;

    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = try smp.alloc(u8, MB);
        smp.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "smp_mb", duration });
}

test "Benchmark malloc/2" {
    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = std.c.malloc(MB);
        std.c.free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "malloc_mb", duration });
}

test "Benchmark mimalloc/2" {
    const start = std.time.nanoTimestamp();

    for (0..1_000_00) |_| {
        const ptr = mimalloc.mi_malloc(MB);
        mimalloc.mi_free(ptr);
    }

    const duration = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    std.debug.print("{s}: {d} ns/op\n", .{ "mimmaloc_mb", duration });
}
