import QtQml

QtObject {
    property var palette: ({
        background: "#161a20", foreground: "#e8edf4", muted: "#8e9bab",
        accent: "#80bfff", border: "#384252", positive: "#8bd5a0",
        warning: "#edcf84", negative: "#ef8f91"
    })
    property url iconRoot: ""
    property string fontFamily: "Sans Serif"
    property string monospaceFamily: "monospace"
    property real fontSize: 14
    property var font: ({family: fontFamily, size: fontSize, monospaceFamily: monospaceFamily})
    property real radiusScale: 1
    property real densityScale: 1
}
