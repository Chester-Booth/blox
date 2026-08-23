pragma Singleton
import QtQuick

QtObject {
    readonly property string shellDir: "/nonexistent/shell"

    function env(name) {
        return "";
    }
}
