// PhoneView — Bluetooth phone call UI
// Active call: mute, end, hold, keypad
// No call: contact search shortcut + recent calls placeholder
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#080d12" }

    // ── No active call ────────────────────────────────────────────────────
    Column {
        anchors.centerIn: parent
        spacing: 20
        visible: !StatusBridge.callActive

        // BT connection status
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 80; height: 80; radius: 40
            color: StatusBridge.btConnected ? "#0d2040" : "#0e1520"
            border { color: StatusBridge.btConnected ? "#00d4ff" : "#1e2a3a"; width: 2 }
            Text {
                anchors.centerIn: parent
                text: "✆"
                color: StatusBridge.btConnected ? "#00d4ff" : "#333"
                font.pixelSize: 36
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: StatusBridge.btConnected ? "Phone connected" : "No phone connected"
            color: StatusBridge.btConnected ? "#888" : "#444"
            font.pixelSize: 14
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: StatusBridge.btConnected ? "Calls will appear here" : "Pair via phone Bluetooth settings"
            color: "#333"
            font.pixelSize: 11
        }
    }

    // ── Active call UI ────────────────────────────────────────────────────
    Column {
        anchors {
            horizontalCenter: parent.horizontalCenter
            verticalCenter: parent.verticalCenter
        }
        spacing: 24
        visible: StatusBridge.callActive

        // Caller info
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "ACTIVE CALL"
                color: "#3adf8a"
                font { pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 2 }
            }

            // Caller name placeholder — BlueZ PBAP would provide this
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Incoming"
                color: "#f0f0f0"
                font { pixelSize: 28; weight: Font.Light }
            }

            // Call timer
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: callTimer.elapsed
                color: "#888"
                font.pixelSize: 14
            }
        }

        // Call controls
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 24

            // Mute
            Column {
                spacing: 8
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 64; height: 64; radius: 32
                    color: muteArea.pressed ? "#1a3a5a" : "#0e1520"
                    border { color: "#1e2a3a"; width: 2 }
                    Text { anchors.centerIn: parent; text: "🎤"; font.pixelSize: 26 }
                    MouseArea { id: muteArea; anchors.fill: parent; onClicked: {} }
                }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "MUTE"; color: "#444"; font { pixelSize: 10; capitalization: Font.AllUppercase } }
            }

            // End call
            Column {
                spacing: 8
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 80; height: 80; radius: 40
                    color: endArea.pressed ? "#5a1a1a" : "#2a0d0d"
                    border { color: "#ff4444"; width: 2 }
                    Text { anchors.centerIn: parent; text: "✆"; font.pixelSize: 34; color: "#ff4444"; rotation: 135 }
                    MouseArea {
                        id: endArea; anchors.fill: parent
                        // BlueZ HFP hangup via D-Bus — wired in AudioService
                        onClicked: {}
                    }
                }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "END"; color: "#ff4444"; font { pixelSize: 10; weight: Font.Bold; capitalization: Font.AllUppercase } }
            }

            // Keypad / hold
            Column {
                spacing: 8
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 64; height: 64; radius: 32
                    color: kpArea.pressed ? "#1a3a5a" : "#0e1520"
                    border { color: "#1e2a3a"; width: 2 }
                    Text { anchors.centerIn: parent; text: "⌨"; font.pixelSize: 26; color: "#888" }
                    MouseArea { id: kpArea; anchors.fill: parent; onClicked: keypadVisible = !keypadVisible }
                }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "KEYPAD"; color: "#444"; font { pixelSize: 10; capitalization: Font.AllUppercase } }
            }
        }
    }

    // ── DTMF keypad overlay ───────────────────────────────────────────────
    property bool keypadVisible: false

    Rectangle {
        anchors.fill: parent
        color: "#e0080d12"
        visible: keypadVisible

        Grid {
            anchors.centerIn: parent
            columns: 3; rows: 4
            spacing: 12

            Repeater {
                model: ["1","2","3","4","5","6","7","8","9","*","0","#"]
                delegate: Rectangle {
                    width: 70; height: 52; radius: 8
                    color: kpBtn.pressed ? "#1a3a5a" : "#0e1520"
                    border { color: "#1e2a3a"; width: 1 }
                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: "#c0c0c0"
                        font { pixelSize: 22; weight: Font.Light }
                    }
                    MouseArea { id: kpBtn; anchors.fill: parent; onClicked: {} }
                }
            }
        }

        Rectangle {
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 20 }
            width: 120; height: 40; radius: 8
            color: "#1a2535"
            Text { anchors.centerIn: parent; text: "Close"; color: "#888"; font.pixelSize: 14 }
            MouseArea { anchors.fill: parent; onClicked: keypadVisible = false }
        }
    }

    // ── Call timer ────────────────────────────────────────────────────────
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
            if (!active) callTimer.seconds = 0
        }
    }
}
