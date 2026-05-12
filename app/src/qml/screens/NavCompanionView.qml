// NavCompanionView — Lower screen nav companion
// Shows turn-by-turn summary, ETA, remaining distance, speed vs limit
// Mirrors upper screen nav state via StatusBridge
import QtQuick 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#080d12" }

    // ── No active route ───────────────────────────────────────────────────
    Column {
        anchors.centerIn: parent
        spacing: 16
        visible: !StatusBridge.navActive

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "⬆"
            color: "#1a2535"
            font { pixelSize: 64; weight: Font.Light }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "No active route"
            color: "#333"
            font.pixelSize: 16
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: StatusBridge.gpsLock ? "GPS ready" : "Acquiring GPS…"
            color: StatusBridge.gpsLock ? "#3adf8a" : "#555"
            font.pixelSize: 12
        }
    }

    // ── Active route layout ───────────────────────────────────────────────
    Column {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 0
        visible: StatusBridge.navActive

        // Turn banner
        Rectangle {
            width: parent.width
            height: 90
            color: "#0d1a27"
            radius: 10
            border { color: "#1a2a3a"; width: 1 }

            Row {
                anchors { fill: parent; margins: 12 }
                spacing: 16

                TurnArrow {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 64; height: 64
                    direction: {
                        var m = StatusBridge.nextManeuver.toLowerCase()
                        if (m.indexOf("right") >= 0 && m.indexOf("sharp") >= 0) return 5
                        if (m.indexOf("left")  >= 0 && m.indexOf("sharp") >= 0) return 6
                        if (m.indexOf("right") >= 0 && m.indexOf("slight") >= 0) return 3
                        if (m.indexOf("left")  >= 0 && m.indexOf("slight") >= 0) return 4
                        if (m.indexOf("right") >= 0) return 1
                        if (m.indexOf("left")  >= 0) return 2
                        if (m.indexOf("u-turn") >= 0) return 7
                        if (m.indexOf("arriv") >= 0) return 8
                        return 0
                    }
                    arrowColor: "#00d4ff"
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    width: parent.width - 80

                    Text {
                        text: StatusBridge.nextDistance < 0.1
                              ? "Now"
                              : (StatusBridge.nextDistance < 1.0
                                 ? Math.round(StatusBridge.nextDistance * 5280) + " ft"
                                 : StatusBridge.nextDistance.toFixed(1) + " mi")
                        color: StatusBridge.approachingTurn ? "#ff8c00" : "#00d4ff"
                        font { pixelSize: 22; weight: Font.Bold }
                    }
                    Text {
                        text: StatusBridge.nextStreet
                        color: "#c0c0c0"
                        font { pixelSize: 15; weight: Font.Medium }
                        width: parent.width
                        elide: Text.ElideRight
                    }
                    Text {
                        text: StatusBridge.nextManeuver
                        color: "#666"
                        font.pixelSize: 11
                        width: parent.width
                        elide: Text.ElideRight
                    }
                }
            }
        }

        // Approaching turn pulse
        Rectangle {
            width: parent.width; height: 2
            color: StatusBridge.approachingTurn ? "#ff8c00" : "transparent"
            Behavior on color { ColorAnimation { duration: 300 } }

            SequentialAnimation on opacity {
                running: StatusBridge.approachingTurn
                loops: Animation.Infinite
                NumberAnimation { to: 0.2; duration: 600 }
                NumberAnimation { to: 1.0; duration: 600 }
            }
            opacity: StatusBridge.approachingTurn ? 1.0 : 0.0
        }

        Item { height: 12; width: 1 }

        // Trip summary row
        Row {
            width: parent.width
            spacing: 0

            // ETA
            Column {
                width: parent.width / 3
                spacing: 4
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: StatusBridge.eta
                    color: "#f0f0f0"
                    font { pixelSize: 22; weight: Font.Light }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "ARRIVE"
                    color: "#444"
                    font { pixelSize: 9; capitalization: Font.AllUppercase }
                }
            }

            // Divider
            Rectangle { width: 1; height: 44; color: "#1a2535"; anchors.verticalCenter: parent.verticalCenter }

            // Remaining
            Column {
                width: parent.width / 3
                spacing: 4
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: NavigationService.remaining.toFixed(1)
                    color: "#f0f0f0"
                    font { pixelSize: 22; weight: Font.Light }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "MI LEFT"
                    color: "#444"
                    font { pixelSize: 9; capitalization: Font.AllUppercase }
                }
            }

            // Divider
            Rectangle { width: 1; height: 44; color: "#1a2535"; anchors.verticalCenter: parent.verticalCenter }

            // Speed / limit
            Column {
                width: parent.width / 3
                spacing: 4
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6
                    Text {
                        text: StatusBridge.speed.toFixed(0)
                        color: StatusBridge.speed > StatusBridge.speedLimit + 5
                               ? "#e84040" : "#f0f0f0"
                        font { pixelSize: 22; weight: Font.Light }
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "/" + StatusBridge.speedLimit.toFixed(0)
                        color: "#555"
                        font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "MPH"
                    color: "#444"
                    font { pixelSize: 9; capitalization: Font.AllUppercase }
                }
            }
        }

        Item { height: 12; width: 1 }

        // Rerouting banner
        Rectangle {
            width: parent.width; height: 32; radius: 6
            visible: StatusBridge.navActive && NavigationService.rerouting
            color: "#1a1500"
            border { color: "#4a3800"; width: 1 }
            Text {
                anchors.centerIn: parent
                text: "⟳  Recalculating route…"
                color: "#ff8c00"
                font.pixelSize: 12
            }
        }
    }
}
