# Widget process ownership

`quickshell.service` runs Quickshell directly under systemd (`Type=exec`, `KillMode=control-group`), so systemd owns the service cgroup and tears down all widget children whenever the shell stops or restarts.

Individual widget commands and PTY terminal sessions are launched by `widgets/lib/blox_widgets/ownership.py` inside their own session and process group (`os.setsid()` + `PR_SET_PDEATHSIG`), tracked by a Linux `pidfd` for instant exit notifications. Cancelling or closing a widget sends `SIGTERM` then `SIGKILL` to the full process group and closes all pipe/PTY descriptors.
