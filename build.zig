const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "compositing_manager",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Other example of using zigx,
    // https://github.com/marler8997/image-viewer/blob/f189f2547890d61a1770327e105b01fc704f98c4/build.zig#L43-L44
    const zigx_dep = b.dependency("zigx", .{});

    // Building executables
    // ============================================
    //
    // Based on the zap build: https://github.com/zigzap/zap/blob/8a2d077bd8627c429de4fef3b1899296e6201c0a/build.zig
    const all_step = b.step("all", "build all executables");
    inline for ([_]struct {
        name: []const u8,
        src: []const u8,
    }{
        // zig build run-main
        .{ .name = "main", .src = "src/main.zig" },
        // zig build run-test_window
        .{ .name = "test_window", .src = "src/main_test_window.zig" },
    }) |exe_cfg| {
        const exe_name = exe_cfg.name;
        const exe_src = exe_cfg.src;
        const exe_build_desc = try std.fmt.allocPrint(
            b.allocator,
            "Build the {s} example",
            .{exe_name},
        );
        const exe_run_stepname = try std.fmt.allocPrint(
            b.allocator,
            "run-{s}",
            .{exe_name},
        );
        const exe_run_stepdesc = try std.fmt.allocPrint(
            b.allocator,
            "Run the {s} example",
            .{exe_name},
        );
        const example_step = b.step(exe_name, exe_build_desc);

        const example_exe = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = .{ .path = exe_src },
            .target = target,
            .optimize = optimize,
        });
        // Make the `zigx` module available to be imported via `@import("x")`
        example_exe.addModule("x", zigx_dep.module("zigx"));

        // install the artifact - depending on the "example"
        const example_build_step = b.addInstallArtifact(example_exe, .{});

        // This *creates* a Run step in the build graph, to be executed when another
        // step is evaluated that depends on it. The next line below will establish
        // such a dependency.
        const example_run_cmd = b.addRunArtifact(example_exe);
        // By making the run step depend on the install step, it will be run from the
        // installation directory rather than directly from within the cache directory.
        // This is not necessary, however, if the application depends on other installed
        // files, this ensures they will be present and in the expected location.
        example_run_cmd.step.dependOn(&example_build_step.step);

        // This allows the user to pass arguments to the application in the build
        // command itself, like this: `zig build run -- arg1 arg2 etc`
        if (b.args) |args| {
            example_run_cmd.addArgs(args);
        }

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build run`
        // This will evaluate the `run` step rather than the default, which is "install".
        const example_run_step = b.step(exe_run_stepname, exe_run_stepdesc);
        example_run_step.dependOn(&example_run_cmd.step);

        example_step.dependOn(&example_build_step.step);
        all_step.dependOn(&example_build_step.step);
    }

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Testing
    // ============================================
    {
        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build test`
        // This will evaluate the `test` step rather than the default, which is "install".
        const test_step = b.step("test", "Run tests");
        const test_filter = b.option([]const u8, "test-filter", "Filter for test");

        // Creates a step for unit testing. This only builds the test executable
        // but does not run it.
        const unit_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
            .filter = test_filter,
        });
        unit_tests.addModule("x", zigx_dep.module("zigx"));

        const run_unit_tests_cmd = b.addRunArtifact(unit_tests);
        // This forces tests to always be re-run instead of returning the cached result.
        run_unit_tests_cmd.has_side_effects = true;

        test_step.dependOn(&run_unit_tests_cmd.step);
    }
}
