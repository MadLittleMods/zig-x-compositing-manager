A basic "compositing manager" for the X Window System that adds transparency/alpha
blending (compositing) to windows.

Normally, you'd get this same functionality for free via your desktop environment's
window manager which probably includes a "compositing manager".

This project is useful to use when you're running in a virtual X environment like `Xvfb`
(X virtual framebuffer) or `Xephyr` and need to work with multiple windows that overlay
on top of each other.

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
