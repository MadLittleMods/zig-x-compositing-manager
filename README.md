# X Compositing Manager written in Zig

A basic "compositing manager" (aka compositor) for the X Window System that adds transparency/alpha
blending (compositing) to windows.

Normally, you'd get this same functionality for free via your desktop environment's
window manager which probably includes a "compositing manager".

This project is useful when you're running in a virtual X environment like `Xvfb` (X
virtual framebuffer) or `Xephyr` and need to work with multiple windows that overlay on
top of each other.

To paraphrase from the [*Adding
Transparency*](https://magcius.github.io/xplain/article/composite.html) page in the
Xplain series by Jasper St. Pierre; a "compositing manager" is needed because by
default, every pixel on the screen is owned by a single window at a time. At any given
point in time, you can point to a pixel, and the X server can tell you which window is
responsible for painting it. Windows in the X11 protocol sense, aren't a tangible thing.
They simply make their mark on the X server's front "root" buffer, as a series of pixels
which they own. The issue is that when the bottommost window is being clipped by another
window on top, we don't have access to the pixels that are being occluded at all; they
simply don't exist anymore. The topmost window owns that pixel.

To accomplish transparency, we redirect the output of all windows to off-screen buffers
and then composite them together to form the final image.

![Demo with three transparent overlapping windows traveling in a circle as they scale up and down (`DISPLAY=:99 zig build test --summary all -Dtest-filter="demo"`)](https://github.com/user-attachments/assets/2132fa0a-33fa-4283-9597-5a9b799ba8d7)


## Build and run standalone executable

Tested with Zig 0.11.0

 1. Build and run: `zig build run-main`
 1. Alternatively, you can build `zig build main` and run the binary artifact
    `./zig-out/bin/main`


## Install as a dependency in your Zig project

The compositing manager is meant to be used as a standalone executable to run alongside
your other X applications. However, it's still possible to include it as a dependency in
your own Zig project and build the `x-compositing-manager` executable from there. You
would probably want to do this if you wanted to programmatically launch the compositing
manager in your own Zig tests.

Tested with Zig 0.11.0

 1. Update your `build.zig.zon` to add the dependency:
    ```zig
    .{
        .name = "my-foo-project",
        .version = "0.0.0",
        .dependencies = .{
            .@"zig-x-compositing-manager" = .{
                .url = "https://github.com/MadLittleMods/zig-x-compositing-manager/archive/<some-commit-hash-abcde>.tar.gz",
                .hash = "1220416f31bac21c9f69c2493110064324b2ba9e0257ce0db16fb4f94657124d7abc",
            },
        },
    }
    ```
 1. Update your `build.zig` to build the executable:
    ```zig
    // Building the x-compositing-manager executable from our dependency
    {
        const x_compositing_manager_dep = b.dependency("zig-x-compositing-manager", .{
            .target = target,
            .optimize = optimize,
        });
        const x_compositing_manager_dep_exe = x_compositing_manager_dep.artifact("main");
        const install_artifact = b.addInstallArtifact(x_compositing_manager_dep_exe, .{
            // Rename the binary artifact
            .dest_sub_path = "x-compositing-manager",
        });

        const build_step = b.step("x-compositing-manager", "Build x-compositing-manager");
        build_step.dependOn(&install_artifact.step);
        all_step.dependOn(&install_artifact.step);

        const run_artifact = b.addRunArtifact(x_compositing_manager_dep_exe);
        run_artifact.step.dependOn(&install_artifact.step);
        // This allows the user to pass arguments to the application in the build
        // command itself, like this: `zig build run -- arg1 arg2 etc`
        if (b.args) |args| {
            run_artifact.addArgs(args);
        }

        const run_step = b.step("run-x-compositing-manager", "Run x-compositing-manager");
        run_step.dependOn(&run_artifact.step);
    }
    ```
 1. To run the compositing manager from your project, first use a `std.process.Child` to
    build it using `zig build x-compositing-manager`. Then, execute the generated binary
    in another `std.process.Child`, `./zig-out/bin/x-compositing-manager`.

    Ideally, we'd be able to use `zig build run-x-compositing-manager` directly to both
    build and run the executable in a single command in a `std.process.Child`, but
    [`ziglang/zig#20853`](https://github.com/ziglang/zig/issues/20853) prevents us from
    being able to kill the process cleanly.
    ```zig
    test "run X applications with the compositing manager" {
        const allocator = std.testing.allocator;

        // Ideally, we'd be able to build and run in the same command like `zig build
        // run-screen_play` but https://github.com/ziglang/zig/issues/20853 prevents us from being
        // able to kill the process cleanly. So we have to build and run in separate
        // commands.
        {
            const argv = [_][]const u8{ "zig", "build", "x-compositing-manager" };
            var build_process = std.process.Child.init(&argv, allocator);
            // Prevent writing to `stdout` so the test runner doesn't hang,
            // see https://github.com/ziglang/zig/issues/15091
            build_process.stdin_behavior = .Ignore;
            build_process.stdout_behavior = .Ignore;
            build_process.stderr_behavior = .Ignore;
            try build_process.spawn();
            const build_term = try build_process.wait();
            try std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, build_term);
        }
        var compositing_manager_process = blk: {
            const argv = [_][]const u8{"./zig-out/bin/x-compositing-manager"};
            var compositing_manager_process = std.process.Child.init(&argv, allocator);
            // Prevent writing to `stdout` so the test runner doesn't hang,
            // see https://github.com/ziglang/zig/issues/15091
            compositing_manager_process.stdin_behavior = .Ignore;
            compositing_manager_process.stdout_behavior = .Ignore;
            compositing_manager_process.stderr_behavior = .Ignore;
            try compositing_manager_process.spawn();

            break :blk compositing_manager_process;
        };

        // Test your own X applications
        //
        // This sleep is just a stub for your own X applications running
        std.time.sleep(3 * std.time.ns_per_s);

        // Kill the compositing manager process when we're done
        _ = try compositing_manager_process.kill();
    }
    ```


## Development

### Building

```sh
zig build run-main
```

```sh
zig build run-test_window -- 50 0 0x88ff0000
```


### Testing

> [!NOTE]
>
> Ideally, the tests should be self-contained and runnable without requiring additional
> setup, such as manually creating and configuring a display of the correct size. By
> default, it should just run in a headless environment and we'd have `Xvfb` as a
> dependency that we'd automatically build ourselves to run the tests. I hate when
> projects require you to install extra system dependencies to get things working. The
> only thing you should need is the right version of Zig.

Launch Xephyr (virtual X server that we can run our tests in):

```
Xephyr :99 -screen 1920x1080x24 -retro
```

 - `:99` specifies the display number to create/use in your virtual environment (you can use
   any number that doesn't collide with an existing display on your system)
 - `-screen 1920x1080x24` creates a 1920x1080 display with 24-bit color depth
 - `-retro` makes the cursor always visible

Run the tests:

```sh
DISPLAY=:99 zig build test --summary all
```

Filter down to only run specific tests:

```sh
DISPLAY=:99 zig build test --summary all -Dtest-filter="end-to-end"
```

If you're running into timeout errors and the Xehpyr screen is black instead of the
retro checkerboard, it probably means our composite manager process was accidentally
left running after the test ended and you just need to restart Xephyr to get a clean
test environment again.

![Three transparent windows overlapping each other with text updating to show how long each window has been running for. An end-to-end demonstration of the X compositing manager.](https://github.com/user-attachments/assets/887289ac-21d9-4213-accf-45da13ac1dcc)
