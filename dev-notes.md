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
 - https://jichu4n.com/posts/how-x-window-managers-work-and-how-to-write-one-part-i/

Other window manager articles:

 - https://www.uninformativ.de/blog/postings/2016-01-05/0/POSTING-en.html

Other articles:

 - Basic Graphics Programming With The XCB Library: https://www.x.org/releases/X11R7.6/doc/libxcb/tutorial/index.html
 - Exploring Xorg connections (part 1): https://hereket.com/posts/exploring-xorg-connections/
 - Monitoring Raw X11 Communication or why Chromium opens 7 Xorg connections (part 2): https://hereket.com/posts/monitoring-raw-x11-communication/

Compositing manager examples:

 - https://github.com/dosbre/xray
 - Extremely basic X11 compositing window manager written in C with Xlib and OpenGL: https://github.com/obiwac/x-compositing-wm
 - Sample X compositing manager (the original demo): https://gitlab.freedesktop.org/xorg/app/xcompmgr
    - `xcompmgr` is a sample compositing manager for X servers supporting the `XFIXES`, `DAMAGE`, `RENDER`, and `COMPOSITE` extensions.  It enables basic eye-candy effects.
 - https://github.com/gustavosbarreto/compmgr
 - https://projects.mini-dweeb.org/projects/unagi
 - [`LamaAni/WebMachine` -> `Testing/cwm.js`](https://github.com/LamaAni/WebMachine/blob/033a0ccafc658a65d8f8f95776113be6681f5edf/Testing/cwm.js
 - https://github.com/yshui/picom/

Other window manager examples:

 - Written in Zig:
   - Tiling window manager: https://github.com/isaac-westaway/Zenith
   - Tiling window manager: https://github.com/MaFackler/uwm
   - Tiling window manager: https://github.com/Luukdegram/juicebox
   - https://github.com/erikbackman/ewm
   - https://github.com/Eloitor/ZigWindowManager
   - Tiling window manager: https://github.com/zuranthus/zwm
   - Tiling window manager: https://github.com/pra1rie/fuckwm
   - https://github.com/last-arg/buoy
   - Tiling window manager: https://github.com/chip2n/zwm
   - Rewrite of `dwm` in Zig: https://github.com/MainKt/zwm
   - https://github.com/Polymethylmethacrylat/m349wm
 - https://github.com/jichu4n/basic_wm
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
    - `Xephyr :99 +extension COMPOSITE -screen 300x300x24` Create a new display with the
      composite extension enabled.


### Using `Xephyr`

(run these commands in separate terminals or put them in the background with `&`)
```sh
# Create a new display with Xephyr
Xephyr :99 -screen 1920x1080x24

# Start an application in the new display
DISPLAY=:99 firefox
```

The Xephyr source code (git repo) is in the `xserver` repository in the
[`hw/kdrive/xephyr`
directory](https://gitlab.freedesktop.org/xorg/xserver/-/tree/master/hw/kdrive/ephyr).

#### Cursor is not visible in Xephyr window

All of the relevant flags you would think would do something don't work to get a cursor
showing up by default.

Examples of flags that do not work:
```
Xephyr :99 -screen 1920x1080x24 -sw-cursor -softCursor
Xephyr :99 -screen 1920x1080x24 -host-cursor
```

The only flag that seems to make the cursor always visible is `-retro`. This makes the
background tile (`party_like_its_1989`) and makes the cursor visible by default. As far
as I can tell and skimming the code, it doesn't have any other side-effects so it
definately seems worth using instead of worrying about creating your own cursors.

```
Xephyr :99 -screen 1920x1080x24 -retro
```

The default cursor is a small "x" from the `cursor` font at glyph index `0` and `1`. You
can see how this is created for Xephyr in the
[`CreateRootCursor(...)`](https://gitlab.freedesktop.org/xorg/xserver/-/blob/d98b36461a142f451a509e52f3faa98baea12ccd/dix/cursor.c#L481-517)
function. X11 requests:
[`OpenFont`](https://www.x.org/releases/X11R7.7/doc/xproto/x11protocol.html#requests:OpenFont)
->
[`CreateGlyphCursor`](https://www.x.org/releases/X11R7.7/doc/xproto/x11protocol.html#requests:CreateGlyphCursor).
I first came across the "x" cursor from a [ffmpeg recording using
`x11grab`](https://github.com/MadLittleMods/fps-aim-analyzer/pull/10).

![Xephyr running with the `-retro` flag. The "x" in the middle is the default cursor](https://github.com/user-attachments/assets/f4d25cf7-bece-48fe-a68f-38c9cb707949)


Relevant links:

 - https://bugs.freedesktop.org/show_bug.cgi?id=69388
 - https://lists.x.org/archives/xorg-devel/2013-September/037801.html

As far as I can tell, normally, your window manager would set a default cursor on the
root window during a
[`CreateWindow`](https://www.x.org/releases/X11R7.7/doc/xproto/x11protocol.html#requests:CreateWindow)
or
[`ChangeWindowAttributes`](https://www.x.org/releases/X11R7.7/doc/xproto/x11protocol.html#requests:ChangeWindowAttributes)
request. Then any child application windows just specify `cursor: None` to inherit their
parents cursor. Any other cursors that an application uses would be created with
[`CreateCursor`](https://www.x.org/releases/X11R7.7/doc/xproto/x11protocol.html#requests:CreateCursor).

For example, with the `galculator` application (just a small example program for
illustration), the only cursor it creates is a `text` I-beam cursor for selecting the
output number. You can trace this using `x11trace galculator`. At least on Manjaro
Linux, you need to install the `xtrace` package to get the `x11trace` command.
Confusingly, you might already have a `xtrace` command but that's not the same thing.
And if you run `galculator` in Xephyr (`DISPLAY=:99 galculator`), your cursor is
invisible (can only see the button hover highlights) until you move it over the area
where the `text` I-beam cursor displays and move it out where it finally falls back to
the default "x" cursor everywhere.

I have no idea how cursor themes work or how various applications make cursors
consistent across your system. I'm guessing there is some freedesktop.org standard for
this but I haven't looked into it yet.
