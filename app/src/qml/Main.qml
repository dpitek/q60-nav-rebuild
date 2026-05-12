// Q60 Nav Rebuild — Main QML root
// Two Windows: upper 8" nav, lower 7" hub
// QtObject root is required by qmlcachegen (only one root item allowed per file).
// Windows are accessed from C++ via root->findChildren<QQuickWindow*>()
import QtQuick 6.6
import QtQuick.Window 6.6
import "screens"
import "components"

QtObject {

    // ── Upper screen: 8" navigation display ──────────────────────────────────
    property var upperWindow: Window {
        id: upperScreen
        objectName: "upperScreen"
        width: 800
        height: 480
        title: "Q60 Nav — Upper"
        color: "#080d12"
        flags: Qt.FramelessWindowHint

        NavigationView {
            anchors.fill: parent
        }
    }

    // ── Lower screen: 7" control hub display ─────────────────────────────────
    property var lowerWindow: Window {
        id: lowerScreen
        objectName: "lowerScreen"
        width: 800
        height: 420
        title: "Q60 Nav — Lower"
        color: "#080d12"
        flags: Qt.FramelessWindowHint

        ControlHubView {
            anchors.fill: parent
        }
    }
}
