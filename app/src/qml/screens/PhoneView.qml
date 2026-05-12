// PhoneView — Bluetooth phone call UI
// Apple CarPlay aesthetic redesign
// All StatusBridge bindings preserved exactly.
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── No active call ──────────────────────────────────────────────────────
    Column {
        anchors.centerIn: parent
        spacing: 20
        visible: !StatusBridge.callActive

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 80; height: 80; radius: 40
            color: StatusBridge.btConnected ? "rgba(10,132,255,0.15)" : "#1C1C1E"
            border {
                color: StatusBridge.btConnected ? "#0A84FF" : "rgba(255,255,255,0.1)"
                width: 2
            }
            Text {
                anchors.centerIn: parent
                text: "✆"
                color: StatusBridge.btConnected ? "#0A84FF" : "#3A3A3C"
                font { pixelSize: 32 }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: StatusBridge.btConnected ? "Phone Connected" : "No Phone Connected"
            color: StatusBridge.btConnected ? "#FFFFFF" : "#8E8E93"
            font { family: "Roboto"; pixelSize: 17; weight: Font.SemiBold }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: StatusBridge.btConnected
                  ? "Incoming calls will appear here"
                  : "Pair via phone Bluetooth settings"
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }
        }
    }

    // ── Active call UI ──────────────────────────────────────────────────────
    Column {
        anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.top
            topMargin: 28
        }
        spacing: 20
        visible: StatusBridge.callActive

        // Active call badge
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            height: 28; radius: 14
            width: activeBadgeLabel.width + 28
            color: "rgba(48,209,88,0.2)"
            border { color: "#30D158"; width: 1 }

            Text {
                id: activeBadgeLabel
                anchors.centerIn: parent
                text: "Active Call"
                color: "#30D158"
                font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
            }
        }

        // Caller info
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 6

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Incoming"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 28; weight: Font.Bold }
            }

            // Call timer
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: callTimer.elapsed
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 17; weight: Font.Light }
            }
        }

        // Call controls: Mute | END | Speaker
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 20

            // Mute
            Column {
                spacing: 8
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 68; height: 68; radius: 34
                    color: muteArea.pressed ? "#2C2C2E" : "#1C1C1E"
                    border { color: "rgba(255,255,255,0.15)"; width: 1.5 }
                    Text { anchors.centerIn: parent; text: "🎤"; font.pixelSize: 26 }
                    MouseArea { id: muteArea; anchors.fill: parent; onClicked: {} }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Mute"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11 }
                }
            }

            // End call — 68px red circle
            Column {
                spacing: 8
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 68; height: 68; radius: 34
                    color: endArea.pressed ? "#CC1A1A" : "#FF453A"
                    Behavior on color { ColorAnimation { duration: 100 } }

                    Text {
                        anchors.centerIn: parent; text: "✆"
                        color: "#FFFFFF"; font { pixelSize: 28 }
                        rotation: 135
                    }
                    MouseArea {
                        id: endArea; anchors.fill: parent
                        onClicked: {}
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "End"
                    color: "#FF453A"
                    font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold }
                }
            }

            // Speaker
            Column {
                spacing: 8
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 68; height: 68; radius: 34
                    color: spkArea.pressed ? "#2C2C2E" : "#1C1C1E"
                    border { color: "rgba(255,255,255,0.15)"; width: 1.5 }
                    Text { anchors.centerIn: parent; text: "🔊"; font.pixelSize: 26 }
                    MouseArea { id: spkArea; anchors.fill: parent; onClicked: {} }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Speaker"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11 }
                }
            }
        }

        // Keypad toggle
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: keypadVisible ? "▲ Hide Keypad" : "▼ Keypad"
            color: "#0A84FF"
            font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }

            MouseArea {
                anchors.fill: parent
                onClicked: keypadVisible = !keypadVisible
            }
        }
    }

    // ── DTMF keypad — bottom sheet ──────────────────────────────────────────
    property bool keypadVisible: false

    Rectangle {
        id: dtmfSheet
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: keypadVisible ? 220 : 0
        color: "#1C1C1E"
        radius: 16
        clip: true
        visible: keypadVisible

        Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        // Top border
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1
            color: "rgba(255,255,255,0.15)"
        }

        Grid {
            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 12 }
            columns: 3; rows: 4
            spacing: 10

            Repeater {
                model: ["1","2","3","4","5","6","7","8","9","*","0","#"]
                delegate: Rectangle {
                    width: 72; height: 44; radius: 10
                    color: dtmfBtn.pressed ? "#2C2C2E" : "#3A3A3C"
                    Text {
                        anchors.centerIn: parent; text: modelData
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 20; weight: Font.Light }
                    }
                    MouseArea { id: dtmfBtn; anchors.fill: parent; onClicked: {} }
                }
            }
        }
    }

    // ── Call timer ──────────────────────────────────────────────────────────
    QtObject {
        id: callTimer
        property int seconds: 0
        property string elapsed: {
            var m = Math.floor(seconds / 60)
            var s = seconds % 60
            return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
        }
        Timer {
            interval: 1000; repeat: true
            running: StatusBridge.callActive
            onTriggered: callTimer.seconds++
        }
    }

    Connections {
        target: StatusBridge
        function onCallActiveChanged(active) {
            if (!active) {
                callTimer.seconds = 0
                keypadVisible = false
            }
        }
    }
}
