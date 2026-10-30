# DinoSaver

A screensaver and lock screen for Windows, written in PowerShell with some embedded C#. It has five animated skins:

- **Dino**: an auto-playing version of Chrome's offline dinosaur game. It runs, jumps the cacti, ducks the pterodactyls, and switches between day and night every 700 points.
- **Matrix rain**: columns of half-width katakana falling with fading green trails.
- **Three-body**: a new random three-body system every round, integrated with an adaptive time step and a little softening. Energy drift stays under 1% over thousands of frames. When one star gets thrown out and the other two settle into a binary, the camera follows the binary, fades out and starts a new system.
- **Double pendulum**: 140 double pendulums whose starting angles differ by 0.00001 rad, integrated with RK4. They swing together as one ribbon, start to split after about 13 seconds and fan out completely by about 30.
- **Flow field**: thousands of particles drifting through a 3D Perlin-noise wind field whose third axis is time.

## Run

Double-click `start.bat`. A small window lets you pick a skin (or random) and choose whether to mute the system audio while it runs.

- Default password: `dino`. Run `设置密码.bat` to change it; only a SHA-256 hash is stored, in `password.hash`.
- To close it, click the button in the bottom-right corner or press Esc, then type the password.
- From the command line: `dino_saver.ps1 -Skin dino|matrix|orbit|pendulum|flow|random`, `-NoPicker` (reuse the last choice), `-TestRun 10` (exits by itself after 10 seconds).

## What it changes while running

- A full-screen topmost window. The cursor hides after 3 seconds without movement.
- A low-level keyboard hook that swallows Win, Alt+Tab, Alt+Esc, Ctrl+Esc, Alt+F4 and Ctrl+Shift+Esc. It goes away with the process; nothing is written to the registry.
- Three- and four-finger touchpad gestures are turned off and restored on exit. The original values are backed up in `touchpad_backup.json`; `恢复触控板手势.bat` restores them by hand if needed.
- System audio is muted and restored on exit (optional).
- The display is kept awake.

It keeps out accidental key presses, not a determined person: Ctrl+Alt+Del still works, as it should. Don't use it as a security tool.

## Performance

Each frame has a budget of about 30 ms. Matrix rain, the three-body system, the pendulums and the flow field draw into their own pixel buffers, with a hand-written anti-aliased line routine, instead of calling GDI+ for every glyph or line. A GDI+ draw call costs about 10 µs, so a few thousand of them use up the whole frame. Measured at 2520×1680: dino 9.0 ms, matrix 11.4 ms, three-body 8.5 ms, pendulums 5.6 ms, flow field 8.7 ms per frame.

## Notes

- `.ps1` files have to be saved as UTF-8 with BOM; without it, Windows PowerShell 5.1 reads them as GBK and the Chinese text breaks the script.
- The full documentation (in Chinese) is in `说明.txt`, including how to add a skin.
- The dino skin is a tribute to the offline dinosaur game in Google Chrome (Chromium, BSD-3-Clause). The sprites are redrawn as pixel runs in `skins/dino.ps1`.

## License

MIT
