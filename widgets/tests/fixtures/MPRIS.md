# Private MPRIS fixture

Run the focused integration test from the repository root:

```sh
python -m unittest discover -s widgets/tests -p test_mpris_native.py -v
```

It needs the installed `dbus-run-session`, Quickshell and Python Gio bindings. The test clears the inherited session bus address before starting its own bus. Its silent player owns only `org.mpris.MediaPlayer2.blox_fixture`. Qt runs offscreen with private temporary XDG directories. No window, audio device, desktop controls or normal media player participates.

`MprisNative.qml` uses the actual `NativeProvider`, `MprisAdapter`, `WidgetHost` and `MusicView`. The test checks initial metadata, position, duration and artwork readiness. It dispatches play/pause, next and previous through the native provider and confirms that the fake service received the corresponding MPRIS methods. Quickshell currently implements toggle playing with separate Play and Pause calls.

The service also accepts a standard MPRIS SetPosition call and emits Seeked. The test checks that the adapter then observes 42 seconds. This tests incoming seeks. The adapter currently has no outgoing seek action.

During hide, the test checks that the host clears its snapshot and the provider has zero music consumers. It changes metadata, position and artwork on the private service before revealing the host. The first accepted ready observation after reveal must contain the changed fixture track and a new generation.

Successful runs print fixture observations and received method names inside the captured subprocess output. All files and processes owned by the private service and bus are removed when the test ends. This verifies the real D-Bus integration and QML readiness rules. It makes no claim about physical desktop frames or audio playback.
