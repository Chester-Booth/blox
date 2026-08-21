import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    required property OsdController controller

    IpcHandler {
        function volume(percent: string, muted: string) : string {
            controller.show("volume", percent, muted);
            return "ok";
        }

        function brightness(percent: string) : string {
            controller.show("brightness", percent, false);
            return "ok";
        }

        function mic(percent: string, muted: string) : string {
            controller.show("mic", percent, muted);
            return "ok";
        }

        function keyboard(percent: string) : string {
            controller.show("keyboard", percent, false);
            return "ok";
        }

        function fan(profile: string) : string {
            controller.showFan(profile);
            return "ok";
        }

        function blueLight(mode: string, active: string) : string {
            controller.showBlueLight(mode, active);
            return "ok";
        }

        function gpu(mode: string) : string {
            controller.showGpu(mode);
            return "ok";
        }

        function caps(enabled: string) : string {
            controller.show("caps", enabled === "true" || enabled === "1" || enabled === "yes" ? 100 : 0, enabled);
            return "ok";
        }

        function camera(enabled: string) : string {
            const active = enabled === "true" || enabled === "1" || enabled === "yes";
            controller.show("camera", active ? 100 : 0, !active);
            return "ok";
        }

        function touchpad(enabled: string) : string {
            const active = enabled === "true" || enabled === "1" || enabled === "yes";
            controller.show("touchpad", active ? 100 : 0, !active);
            return "ok";
        }

        function notice(title: string, message: string, icon: string, level: string, durationMs: string) : string {
            controller.showNotice(title, message, icon, level, durationMs);
            return "ok";
        }

        target: "osd"
    }

}
