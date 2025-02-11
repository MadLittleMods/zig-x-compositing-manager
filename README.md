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


## Install:

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
 1. Update your `build.zig` to include the module:
    ```zig
    const x_compositing_manager_pkg = b.dependency("zig-x-compositing-manager", .{
        .target = target,
        .optimize = optimize,
    });
    const x_compositing_manager_mod = x_compositing_manager_pkg.module("zig-x-compositing-manager");
    // Make the `zig-x-compositing-manager` module available to be imported via `@import("zig-x-compositing-manager")`
    exe.addModule("zig-x-compositing-manager", x_compositing_manager_mod);
    exe_tests.addModule("zig-x-compositing-manager", x_compositing_manager_mod);
    ```

## Usage:

TODO


## Building

```sh
zig build run-main
```

```sh
zig build run-test_window -- 50 0 0x88ff0000
```


## Testing

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
