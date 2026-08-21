#!/usr/bin/env python3
import json
import subprocess


def emit(icon, state, tooltip, *, microphone=0, video=0, available=True, ready=True, can_change=False, permission="not-required", reason=None):
    print(json.dumps({
        "icon": icon,
        "class": state,
        "active": microphone > 0 or video > 0,
        "microphoneCount": microphone,
        "videoCount": video,
        "details": tooltip,
        "tooltip": tooltip,
        "capability": {
            "available": available,
            "ready": ready,
            "canChange": can_change,
            "permission": permission,
            "reason": reason,
        },
    }))


try:
    result = subprocess.run(
        ["pw-dump"],
        check=True,
        capture_output=True,
        text=True,
        timeout=4,
    )
    objects = json.loads(result.stdout)
except FileNotFoundError as error:
    emit("󰍹", "error", f"Privacy status unavailable: {error}", available=False, ready=False, reason="command-unavailable")
    raise SystemExit(0)
except (subprocess.SubprocessError, json.JSONDecodeError) as error:
    emit("󰍹", "error", f"Privacy status unavailable: {error}", available=True, ready=False, reason="query-failed")
    raise SystemExit(0)

nodes = {
    item.get("id"): item.get("info", {}).get("props", {})
    for item in objects
    if item.get("type") == "PipeWire:Interface:Node"
}
microphone_streams = set()
video_streams = set()

for item in objects:
    if item.get("type") != "PipeWire:Interface:Link":
        continue

    info = item.get("info", {})
    if info.get("state") != "active":
        continue

    output_id = info.get("output-node-id")
    input_id = info.get("input-node-id")
    output_class = nodes.get(output_id, {}).get("media.class", "")
    input_class = nodes.get(input_id, {}).get("media.class", "")

    if output_class == "Audio/Source" and input_class.startswith("Stream/Input/Audio"):
        microphone_streams.add(input_id)

    if "Video" in output_class or "Video" in input_class:
        stream_id = input_id if input_class.startswith("Stream/") else output_id
        video_streams.add(stream_id)

microphone_count = len(microphone_streams)
video_count = len(video_streams)
details = []
if microphone_count:
    details.append(f"Microphone capture: {microphone_count}")
if video_count:
    details.append(f"Video/screen capture: {video_count}")

if details:
    emit(
        "󰍹",
        "active",
        "\n".join(details),
        microphone=microphone_count,
        video=video_count,
    )
else:
    emit("󰍹", "idle", "No active microphone, camera or screen capture")
