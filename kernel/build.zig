const std = @import("std");

pub fn build(b: *std.Build) void {
    // Define a freestanding x86_64 cross-compilation target.
    var target: std.zig.CrossTarget = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };

    // Disable CPU features that require additional initialization like MMX,
    // SSE/2 and AVX. That requires us to enable the soft-float feature.
    const Target = std.Target.x86;
    target.cpu_features_add.addFeatureSet(Target.featureSet(&.{.soft_float}));
    target.cpu_features_sub.addFeatureSet(Target.featureSet(&.{ .mmx, .sse, .sse2, .avx, .avx2 }));

    // Build the kernel itself.
    const optimize = b.standardOptimizeOption(.{});
    const limine = b.dependency("limine", .{});
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(target),
        .optimize = optimize,
        .code_model = .kernel,
        .single_threaded = true,
        .pic = true,
    });

    kernel.root_module.addImport("limine", limine.module("limine"));
    kernel.setLinkerScriptPath(b.path("linker.ld"));

    // Disable LTO. This prevents issues with limine requests
    kernel.want_lto = false;

    // Add additional C defines, include directories and source files.
    kernel.defineCMacro("UACPI_SIZED_FREES", "1");

    kernel.addIncludePath(b.path("flanterm"));
    kernel.addIncludePath(b.path("uacpi/include"));

    kernel.addCSourceFiles(.{
        .root = b.path("flanterm"),
        .files = &.{ "flanterm.c", "backends/fb.c" },
        .flags = &.{"-fno-sanitize=undefined"},
    });

    kernel.addCSourceFiles(.{
        .root = b.path("uacpi/source"),
        .files = &.{
            "tables.c",
            "types.c",
            "uacpi.c",
            "utilities.c",
            "interpreter.c",
            "opcodes.c",
            "namespace.c",
            "stdlib.c",
            "shareable.c",
            "opregion.c",
            "default_handlers.c",
            "io.c",
            "notify.c",
            "sleep.c",
            "registers.c",
            "resources.c",
            "event.c",
            "mutex.c",
            "osi.c",
        },
    });

    // Install the kernel as an artifact.
    b.installArtifact(kernel);
}
