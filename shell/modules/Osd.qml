import QtQuick
import Quickshell

Scope {
    id: root

    property alias scriptRoot: controller.scriptRoot

    function preview(kind, percent, isMuted) {
        controller.preview(kind, percent, isMuted);
    }

    function show(kind, percent, isMuted) {
        controller.show(kind, percent, isMuted);
    }

    function showNotice(title, message, iconName, level, durationMs) {
        controller.showNotice(title, message, iconName, level, durationMs);
    }

    function showFan(profile) {
        controller.showFan(profile);
    }

    function showGpu(mode) {
        controller.showGpu(mode);
    }

    function showBlueLight(mode, active) {
        controller.showBlueLight(mode, active);
    }

    OsdController {
        id: controller
    }

    OsdIpc {
        controller: controller
    }

    OsdSurface {
        controller: controller
    }

}
