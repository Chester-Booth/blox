import QtQuick

QtObject {
    id: root

    required property var host
    property bool open: false
    property string key: ""
    property string target: ""
    property real hue: 0
    property real saturation: 0
    property real value: 1
    property string hex: "#ffffff"

    function componentHex(component) {
        return Math.round(Math.max(0, Math.min(255, component))).toString(16).padStart(2, "0");
    }

    function hsvHex(hue, saturation, value) {
        const sector = ((hue % 1) + 1) % 1 * 6;
        const chroma = value * saturation;
        const intermediate = chroma * (1 - Math.abs(sector % 2 - 1));
        const offset = value - chroma;
        let red = 0;
        let green = 0;
        let blue = 0;
        if (sector < 1) {
            red = chroma;
            green = intermediate;
        } else if (sector < 2) {
            red = intermediate;
            green = chroma;
        } else if (sector < 3) {
            green = chroma;
            blue = intermediate;
        } else if (sector < 4) {
            green = intermediate;
            blue = chroma;
        } else if (sector < 5) {
            red = intermediate;
            blue = chroma;
        } else {
            red = chroma;
            blue = intermediate;
        }
        return "#" + componentHex((red + offset) * 255) + componentHex((green + offset) * 255) + componentHex((blue + offset) * 255);
    }

    function load(colour) {
        const normalised = /^#[0-9a-fA-F]{6}$/.test(String(colour || "")) ? colour : "#ffffff";
        const value = String(normalised).replace("#", "");
        const red = parseInt(value.slice(0, 2), 16) / 255;
        const green = parseInt(value.slice(2, 4), 16) / 255;
        const blue = parseInt(value.slice(4, 6), 16) / 255;
        const maximum = Math.max(red, green, blue);
        const minimum = Math.min(red, green, blue);
        const delta = maximum - minimum;
        let nextHue = 0;
        if (delta > 0) {
            if (maximum === red)
                nextHue = ((green - blue) / delta % 6) / 6;
            else if (maximum === green)
                nextHue = ((blue - red) / delta + 2) / 6;
            else
                nextHue = ((red - green) / delta + 4) / 6;
        }
        hue = nextHue < 0 ? nextHue + 1 : nextHue;
        saturation = maximum === 0 ? 0 : delta / maximum;
        root.value = maximum;
        hex = "#" + value.toLowerCase();
    }

    function show(key, target) {
        if (!host.candidate)
            return ;

        root.key = key;
        root.target = target || "";
        const overrideValues = target && host.candidate.overrides ? host.candidate.overrides[target] : null;
        const previewValues = target === "ansi" && host.previewData ? host.previewData.ansi : null;
        const colour = overrideValues && overrideValues[key] ? overrideValues[key] : previewValues && previewValues[key] ? previewValues[key] : host.candidate.colours[key];
        load(colour);
        host.rememberOverlayFocus();
        open = true;
        Qt.callLater(() => {
            host.host.focusColourPicker();
        });
    }

    function apply(value) {
        if (!/^#[0-9a-fA-F]{6}$/.test(value))
            return ;

        hex = value.toLowerCase();
        if (target)
            host.setOverride(target, key, hex);
        else
            host.setColour(key, hex);
    }

    function update() {
        apply(hsvHex(hue, saturation, value));
    }

}
