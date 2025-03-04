const std = @import("std");

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("mimalloc", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const lib = b.addStaticLibrary(.{
        .name = "mikualloc",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("mikualloc.zig"),
    });
    lib.addIncludePath(upstream.path("include"));
    lib.installHeadersDirectory(upstream.path("src"), "", .{
        .include_extensions = &.{
            "bitmap.h",
            "prim/windows/etw.h",
        },
    });
    lib.installHeadersDirectory(upstream.path("include"), "", .{
        .include_extensions = &.{
            "mimalloc.h",
            "mimalloc/atomic.h",
            "mimalloc/bits.h",
            "mimalloc/internal.h",
            "mimalloc/prim.h",
            "mimalloc/track.h",
        },
    });
    lib.addCSourceFiles(.{
        .root = upstream.path("src"),

        .files = &.{
            "alloc-aligned.c",
            // "alloc-posix.c",
            "alloc.c",
            // "alloc-override"  should inlcluded from alloc.
            // "arena-meta.c",
            "arena.c",
            "bitmap.c",
            //bitmam.h
            // "free.c", this file should be included from alloc.c
            "heap.c",
            "init.c",
            "libc.c",
            "options.c",
            "os.c",
            // "page-map.c",
            // "page-queue.c", //this page should be included from page.c
            "page.c",
            "random.c",
            "stats.c",
            "static.c",
            "prim/prim.c",
            // "prim/emscripten/prim.c",
            // "prim/osx/alloc-override-zone.c",
            // "prim/osx/prim.c",
            // "prim/unix/prim.c",
            // "prim/wasi/prim.c",
            // "prim/windows/prim.c",
        },
        .flags = &.{
            "-DNDEBUG=1",
            "-DMI_SECURE=0",
            "-DMI_STAT=0",
            "-std=gnu99",
            "-Wall",
            "-Wextra",
        },
    });

    lib.linkLibC();

    b.installArtifact(lib);

    const unit_test = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("mikualloc.zig"),
    });

    unit_test.linkLibrary(lib);

    const run_unit_test = b.addRunArtifact(unit_test);

    const test_step = b.step("test", "Run Library test");
    test_step.dependOn(&run_unit_test.step);
}
