// Q60 Nav Rebuild — Main QML root
// Apple CarPlay aesthetic redesign
// Two Windows: upper 8" nav, lower 7" hub
// QtObject root required by qmlcachegen (only one root item allowed per file).
// Windows accessed from C++ via root->findChildren<QQuickWindow*>()
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
        color: "#000000"
        flags: Qt.FramelessWindowHint

        // Root container for upper screen
        Item {
            id: upperRoot
            anchors.fill: parent

            // Full-screen nav view
            NavigationView {
                anchors.fill: parent
            }

            // ── Welcome overlay (profile greeting on startup) ───────────────
            // Shown for ~3s when a key-fob profile is matched, or until the
            // driver selects a profile when no key slot is recognised.
            // Sits above the map (z:50) but below the call overlay (z:100).
            WelcomeOverlay {
                anchors.fill: parent
                z: 50
            }

            // ── Incoming call overlay (upper screen) ───────────────────────
            Loader {
                id: incomingCallOverlayUpper
                anchors.fill: parent
                z: 100
                active: StatusBridge.callActive && !incomingCallDismissed

                property bool incomingCallDismissed: false

                // Reset dismissed state when a new call starts
                Connections {
                    target: StatusBridge
                    function onCallActiveChanged(active) {
                        if (active) incomingCallOverlayUpper.incomingCallDismissed = false
                    }
                }

                sourceComponent: Component {
                    IncomingCallView {
                        callerName:   ""
                        callerNumber: ""
                        onAnswered:  incomingCallOverlayUpper.incomingCallDismissed = true
                        onDeclined:  incomingCallOverlayUpper.incomingCallDismissed = true
                    }
                }

                // 200ms fade transition
                opacity: active ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.InOutSine } }
            }
        }
    }

    // ── Lower screen: 7" control hub display ─────────────────────────────────
    property var lowerWindow: Window {
        id: lowerScreen
        objectName: "lowerScreen"
        width: 800
        height: 420
        title: "Q60 Nav — Lower"
        color: "#000000"
        flags: Qt.FramelessWindowHint

        // Root container for lower screen
        Item {
            id: lowerRoot
            anchors.fill: parent

            // Full-screen control hub
            ControlHubView {
                anchors.fill: parent
            }

            // ── Incoming call overlay (lower screen) ───────────────────────
            Loader {
                id: incomingCallOverlayLower
                anchors.fill: parent
                z: 100
                active: StatusBridge.callActive && !incomingCallDismissedLower

                property bool incomingCallDismissedLower: false

                Connections {
                    target: StatusBridge
                    function onCallActiveChanged(active) {
                        if (active) incomingCallOverlayLower.incomingCallDismissedLower = false
                    }
                }

                sourceComponent: Component {
                    IncomingCallView {
                        callerName:   ""
                        callerNumber: ""
                        onAnswered:  incomingCallOverlayLower.incomingCallDismissedLower = true
                        onDeclined:  incomingCallOverlayLower.incomingCallDismissedLower = true
                    }
                }

                opacity: active ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.InOutSine } }
            }
        }
    }
}
