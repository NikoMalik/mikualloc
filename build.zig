const std = @import("std");

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("mimalloc", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
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

    lib.want_lto = true;

    lib.addCSourceFiles(.{
        .root = upstream.path("src"),

        .files = &.{
            // "alloc-aligned.c",
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
            // "options.c",
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
            //
            "-Ofast",
            "-flto",

            "-march=native",
            "-funroll-loops",

            //
            "-DMI_SECURE=0", // 0 || 1 for debug
            "-DMI_DEBUG=0", // 0  || 3 for debug
            "-DMI_STAT=0", // 0   || 1 for debug
            "-DMI_NO_THP=1",
            "-DMIMALLOC_DECOMMIT_EXTEND=0",
            // "-DMI_SEGMENT_CACHE=256",
            "-DMI_PURGE_DECOMMITS=0",
            "-DMI_LOCAL_DYNAMIC_TLS=1",
            "-DMI_USE_ENVIRON=0",

            "-fno-exceptions",
            "-fno-unwind-tables",
            "-ftree-vectorize",
            "-fno-stack-protector",

            "-ffast-math",
            "-fomit-frame-pointer",
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

    //==================================//
    //BENCH
    //==================================//
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("bench.zig"),

        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .use_lld = true,
    });
    bench_exe.want_lto = true;

    bench_exe.linkLibC();
    bench_exe.linkLibrary(lib);
    b.installArtifact(bench_exe);

    const run_bench_exe = b.addRunArtifact(bench_exe);

    const bench_step = b.step("bench", "Run Bench ");
    bench_step.dependOn(&run_bench_exe.step);
}
