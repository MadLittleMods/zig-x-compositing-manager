# Developer notes

A collection of references and notes while developing this project.


## Reference

Spec:

 - X Composite extension spec: https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/blob/master/compositeproto.txt
 - XML definitions of the protocol for the Composite extension (XCB): https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/77d7fc04da729ddc5ed4aacf30253726fac24dca/src/composite.xml
 - Extended Window Manager Hints: https://specifications.freedesktop.org/wm-spec/1.3/

Guides and blog posts:

 - https://magcius.github.io/xplain/article/composite.html
 - https://wingolog.org/archives/2008/07/26/so-you-want-to-build-a-compositor
 - https://www.talisman.org/~erlkonig/misc/x11-composite-tutorial/


Compositing manager examples:

 - Extremely basic X11 compositing window manager written in C with Xlib and OpenGL: https://github.com/obiwac/x-compositing-wm
 - Sample X compositing manager (the original demo): https://gitlab.freedesktop.org/xorg/app/xcompmgr
    - `xcompmgr` is a sample compositing manager for X servers supporting the `XFIXES`, `DAMAGE`, `RENDER`, and `COMPOSITE` extensions.  It enables basic eye-candy effects.
 - https://github.com/gustavosbarreto/compmgr
 - https://projects.mini-dweeb.org/projects/unagi

Other window manager examples:

 - https://github.com/mackstann/tinywm
 - https://github.com/Airblader/node-tinywm
 - [https://github.com/sidorares/node-x11/examples/windowmanager/wm.js](https://github.com/sidorares/node-x11/blob/070877bd71276b69f973f487d20969743ed3ec6d/examples/windowmanager/wm.js)
 - https://code.google.com/archive/p/winmalist/


## Relevant tools

 - `Xvfb`: X virtual framebuffer
    - Also `xvfb-run` to run a command in a virtual framebuffer (this will start and stop xvfb for you)
    - `xvfb-run --server-num 99 --server-args "-ac -screen 0 1920x1080x24" firefox`: Run Firefox in
      a virtual framebuffer with a 1920x1080 display with 24-bit color depth.
 - `Xephyr`: Nested X server that runs as an X application. It's basically a way to
   create a new X11 screen that appears as a window on your desktop.
    - `Xephyr :99 -screen 1920x1080x24`: Creates a new 1920x1080 display with 24-bit
      color depth. Then you can run `DISPLAY=:99 firefox` to run Firefox on that display.
