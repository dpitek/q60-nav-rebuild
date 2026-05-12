// NavCompanionView — Lower screen nav companion
// Apple CarPlay aesthetic redesign
// All StatusBridge / NavigationService bindings preserved exactly.
import QtQuick 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── No active route ─────────────────────────────────────────────────────
    Column {
        anchors.centerIn: parent
        spacing: 14
        visible: !StatusBridge.navActive

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "⬆"
            color: "#2C2C2E"
            font { pixelSize: 56 }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "No active route"
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 17 }
        }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 6

            Rectangle {
                width: 7; height: 7; radius: 3.5
                anchors.verticalCenter: parent.verticalCenter
                color: StatusBridge.gpsLock ? "#30D158" : "#3A3A3C"
            }
            Text {
                text: StatusBridge.gpsLock ? "GPS Ready" : "Acquiring GPS…"
                color: StatusBridge.gpsLock ? "#30D158" : "#8E8E93"
                font { family: "Roboto"; pixelSize: 13 }
            }
        }
    }

    // ── Active route: info card strip ────────────────────────────────────────
    Column {
        anchors { fill: parent; margins: 12 }
        spacing: 10
        visible: StatusBridge.navActive

        // Turn card — full width
        Rectangle {
            id: turnCard
            width: parent.width; height: 96
            radius: 16
            color: "#1C1C1E"
            border { color: "rgba(255,255,255,0.15)"; width: 1 }

            Row {
                anchors { fill: parent; margins: 12 }
                spacing: 14

                TurnArrow {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 60; height: 60
                    direction: {
                        var m = StatusBridge.nextManeuver.toLowerCase()
                        if (m.indexOf("right") >= 0 && m.indexOf("sharp") >= 0) return 5
                        if (m.indexOf("left")  >= 0 && m.indexOf("sharp") >= 0) return 6
                        if (m.indexOf("right") >= 0 && m.indexOf("slight") >= 0) return 3
                        if (m.indexOf("left")  >= 0 && m.indexOf("slight") >= 0) return 4
                        if (m.indexOf("right") >= 0) return 1
                        if (m.indexOf("left")  >= 0) return 2
                        if (m.indexOf("u-turn") >= 0) return 7
                        if (m.indexOf("arriv")  >= 0) return 8
                        return 0
                    }
                    arrowColor: StatusBridge.approachingTurn ? "#FF9F0A" : "#0A84FF"
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    width: parent.width - 74

                    Text {
                        text: StatusBridge.nextDistance < 0.1
                              ? "Now"
                              : (StatusBridge.nextDistance < 1.0
                                 ? Math.round(StatusBridge.nextDistance * 5280) + " ft"
                                 : StatusBridge.nextDistance.toFixed(1) + " mi")
                        color: StatusBridge.approachingTurn ? "#FF9F0A" : "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 26; weight: Font.Bold }
                    }
                    Text {
                        text: StatusBridge.nextStreet
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 15; weight: Font.Medium }
                        width: parent.width; elide: Text.ElideRight
                    }
                    Text {
                        text: StatusBridge.nextManeuver
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 12 }
                        width: parent.width; elide: Text.ElideRight
                    }
                }
            }
        }

        // Approaching turn pulse accent
        Rectangle {
            width: parent.width; height: 3; radius: 1.5
            color: "#FF9F0A"
            opacity: StatusBridge.approachingTurn ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 200 } }

            SequentialAnimation on opacity {
                running: StatusBridge.approachingTurn
                loops: Animation.Infinite
                NumberAnimation { to: 0.2; duration: 600 }
                NumberAnimation { to: 1.0; duration: 600 }
            }
        }

        // ── Speed | ETA | Distance — three-cell row ─────────────────────────
        Rectangle {
            width: parent.width; height: 72
            radius: 16
            color: "#1C1C1E"
            border { color: "rgba(255,255,255,0.15)"; width: 1 }

            Row {
                anchors.fill: parent

                // Speed large left
                Item {
                    width: parent.width / 3; height: parent.height

                    Column {
                        anchors.centerIn: parent
                        spacing: 2

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 5

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: StatusBridge.speed.toFixed(0)
                                color: StatusBridge.speed > StatusBridge.speedLimit + 5
                                       ? "#FF453A" : "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 26; weight: Font.Bold }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "/" + (StatusBridge.speedLimit > 0
                                             ? StatusBridge.speedLimit.toFixed(0) : "--")
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 14 }
                            }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "MPH"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }
                    }
                }

                // Separator
                Rectangle { width: 1; height: 40; color: "rgba(255,255,255,0.12)"; anchors.verticalCenter: parent.verticalCenter }

                // ETA center
                Item {
                    width: parent.width / 3; height: parent.height

                    Column {
                        anchors.centerIn: parent
                        spacing: 2

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: StatusBridge.eta.length > 0 ? StatusBridge.eta : "--:--"
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 22; weight: Font.SemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Arrive"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 10 }
                        }
                    }
                }

                // Separator
                Rectangle { width: 1; height: 40; color: "rgba(255,255,255,0.12)"; anchors.verticalCenter: parent.verticalCenter }

                // Distance right
                Item {
                    width: parent.width / 3; height: parent.height

                    Column {
                        anchors.centerIn: parent
                        spacing: 2

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: NavigationService.remaining.toFixed(1)
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 22; weight: Font.SemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "mi left"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 10 }
                        }
                    }
                }
            }
        }

        // ── Rerouting banner — orange full-width ────────────────────────────
        Rectangle {
            width: parent.width; height: 40; radius: 12
            visible: NavigationService.rerouting
            color: "#FF9F0A"

            Row {
                anchors.centerIn: parent
                spacing: 8
                Text { anchors.verticalCenter: parent.verticalCenter; text: "⟳"; color: "#000000"; font { pixelSize: 18 } }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Recalculating route…"
                    color: "#000000"
                    font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                }
            }
        }
    }
}
