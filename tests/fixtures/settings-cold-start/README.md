# Settings cold recovery

This fixture runs the real Settings controller and state with native Quickshell Process objects. Private Python stubs replace the three Settings helpers. It checks successful initial reading, disabled recovery and both recovery failures without using the desktop, manager or user configuration.

Run with native Quickshell installed. Both directories must belong to you. The output path must be unused, and the runtime parent must allow Unix socket paths below 108 bytes.

```sh
python3 -I -S -B tests/fixtures/settings-cold-start/run.py --output /home/blox/.cache/blox-settings-cold-UNUSED --runtime-parent /home/blox/.cache
```

Each Qt child has a five-second bound. The fixture retains every output, helper event and private runtime directory. It uses software/offscreen Qt, fresh HOME/XDG roles and no inherited desktop, audio or bus connection. It makes no timing or performance acceptance claim.
