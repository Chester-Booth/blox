# Windowless GPU correctness fixture

This optional local check renders the actual SDK, native views and terminal canvas into a 640 by 360 texture. Run it from the repository root:

```sh
python widgets/tests/gpu-fixture/run.py
```

It requires the already installed CMake, Ninja, C++ compiler, Qt 6.12 development and private headers, Pillow, Bubblewrap and the RADV Vulkan driver. The default device is the AMD render node at `/dev/dri/renderD128`. The runner rejects a Vulkan device reported as a CPU or virtual device. It does not install anything.

The Vulkan setup reuses the small Qt 6.12 private headless adapter from the earlier phase 5 renderer probe. Its presentation method always returns false. A `QQuickRenderControl` renders into a `QRhi` texture and reads pixels back. The `QQuickWindow` remains invisible and has no native handle. The software comparison uses the same RenderControl and QML, with a `QImage` paint target.

Both processes run inside separate Bubblewrap namespaces. Only the GPU process receives a render node. Neither receives DRM card nodes, host display sockets, session buses, input devices or network access. Source and fonts are read-only. Temporary run and home directories belong to the fixture. Each rendering process has a twelve second alarm and the runner imposes a fifteen second timeout. This is a bounded correctness check, with no cadence, timing score or benchmark loop.

The checked-in QML instantiates the real `WidgetHost` and `WidgetTheme`. Python builds validated profiles with `default_widget()` and supplies frozen, labelled preview observations. No native data adaptor or command runs. The selected cases cover opaque and transparent backgrounds, rounded fullscreen layouts, clock ticks and hands, CPU rings and charts, network charts, artwork and a radial music progress ring.

The terminal cases use the real ANSI screen model and broker output queue. A clear update is replaced before transport, leaving a sequence gap and only the next row in `changedRuns`. The first content draw must still clear both rows. A later hide and fresh reveal must contain the new generation without the previous coloured cells.

Every case captures the first draw whose pre-sync host state is visible, then a later frozen draw. Those two images must match exactly within each backend. The runner also checks geometry, alpha, rounded corners and terminal coloured/cleared pixels. It reports software versus Vulkan raster differences rather than treating different font and edge antialiasing as pixel equality.

Results go to `~/.cache/blox-widget-gpu-fixture`, or the directory passed with `--output`. `comparison.json` contains the checks and QML source hashes. Separate backend JSON files record the device, draw count and native-window assertions. PNGs include first and later images, plus a labelled comparison montage composited over the same dark background.

The first run found missing clock ticks, metric rings and chart lines in the first content draw. The production clock now uses retained Qt Quick rectangles. Rings and charts use synchronous public `QtQuick.Shapes` paths. This removes their dependency on a later Canvas image upload. The fixture checks the resulting first readbacks. It makes no claim about a host compositor, desktop presentation, performance or memory savings.
