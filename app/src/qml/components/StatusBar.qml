// StatusBar.qml — 32px top status bar
// Time left, center speed/gear, right: GPS/BT/phone indicators
import QtQuick 6.6

Item {
    id: root
    height: 32

    // ── Background ──────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#000000"

        // Bottom separator line
        Rectangle {
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: 1
            color: Qt.rgba(1, 1, 1, 0.15)
        }
    }

    // ── Left: Time ──────────────────────────────────────────────────────────
    Text {
        anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 16 }
        text: StatusBridge.timeString
        color: "#FFFFFF"
        font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
    }

    // ── Center: Speed + Gear ────────────────────────────────────────────────
    Row {
        anchors.centerIn: parent
        spacing: 8

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: StatusBridge.speed.toFixed(0)
            color: StatusBridge.speed > StatusBridge.speedLimit + 5
                   ? "#FF453A" : "#FFFFFF"
            font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
            visible: StatusBridge.speed > 1
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: StatusBridge.speed > 1 ? "mph" : ""
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 11 }
        }

        Rectangle {
            width: 1; height: 14
            color: Qt.rgba(1, 1, 1, 0.2)
            anchors.verticalCenter: parent.verticalCenter
            visible: StatusBridge.speed > 1
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: {
                var g = VehicleService.gear
                if (VehicleService.reverse) return "R"
                if (g === 0) return "P"
                if (g === 1) return "N"
                if (g >= 2) return "D"
                return ""
            }
            color: VehicleService.reverse ? "#FF9F0A" : "#8E8E93"
            font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
        }
    }

    // ── Right: Status Indicators ────────────────────────────────────────────
    Row {
        anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 16 }
        spacing: 12

        // GPS dot
        Row {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                width: 6; height: 6; radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: StatusBridge.gpsLock ? "#30D158" : "#3A3A3C"

                SequentialAnimation on opacity {
                    running: !StatusBridge.gpsLock
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 800 }
                    NumberAnimation { to: 1.0; duration: 800 }
                }
            }
            Text {
                text: "GPS"
                color: StatusBridge.gpsLock ? "#30D158" : "#3A3A3C"
                font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
            }
        }

        // BT dot
        Row {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                width: 6; height: 6; radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: StatusBridge.btConnected ? "#0A84FF" : "#3A3A3C"
            }
            Text {
                text: "BT"
                color: StatusBridge.btConnected ? "#0A84FF" : "#3A3A3C"
                font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
            }
        }

        // Phone dot (only visible when call active)
        Row {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter
            visible: StatusBridge.callActive

            Rectangle {
                width: 6; height: 6; radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: "#30D158"

                SequentialAnimation on opacity {
                    running: StatusBridge.callActive
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.4; duration: 600 }
                    NumberAnimation { to: 1.0; duration: 600 }
                }
            }
            Text {
                text: "CALL"
                color: "#30D158"
                font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
            }
        }
    }
}
