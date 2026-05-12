// VehicleStatusView.qml — Vehicle info screen
// Door diagram, fuel arc, drive mode, coolant, gear/RPM
import QtQuick 6.6

Item {
    id: root
    anchors.fill: parent

    // ── Background ──────────────────────────────────────────────────────────
    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Layout: 3 rows ──────────────────────────────────────────────────────

    // Row 1: Door diagram + Fuel gauge
    Row {
        id: topRow
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: 16
        }
        spacing: 32

        // ── Door diagram ────────────────────────────────────────────────────
        Item {
            id: doorDiagram
            width: 200; height: 160

            // Car body outline
            Rectangle {
                anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 20 }
                width: 100; height: 120; radius: 12
                color: "#1C1C1E"
                border { color: "rgba(255,255,255,0.15)"; width: 1.5 }

                // Windshield (front)
                Rectangle {
                    anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 8 }
                    width: 70; height: 24; radius: 4
                    color: "#2C2C2E"
                }

                // Rear window
                Rectangle {
                    anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 8 }
                    width: 70; height: 20; radius: 4
                    color: "#2C2C2E"
                }
            }

            // Door states — bound to VehicleService (parsed from CAN_DOOR_STATUS 0x358)
            property bool driverDoorOpen:    VehicleService.doorDriver
            property bool passDoorOpen:      VehicleService.doorPassenger
            property bool driverRearOpen:    VehicleService.doorRearLeft
            property bool passRearOpen:      VehicleService.doorRearRight
            property bool trunkIsOpen:       VehicleService.trunkOpen

            // Left-front door
            Rectangle {
                x: 8; y: 30
                width: 28; height: 40; radius: 4
                color: doorDiagram.driverDoorOpen    ? "#FF453A" : "#1C1C1E"
                border { color: doorDiagram.driverDoorOpen ? "#FF453A" : "#0A84FF"; width: 1.5 }

                Text {
                    anchors.centerIn: parent
                    text: "FL"
                    color: doorDiagram.driverDoorOpen ? "#FFFFFF" : "#8E8E93"
                    font { pixelSize: 9; weight: Font.Bold }
                }
            }

            // Right-front door
            Rectangle {
                x: 164; y: 30
                width: 28; height: 40; radius: 4
                color: doorDiagram.passDoorOpen    ? "#FF453A" : "#1C1C1E"
                border { color: doorDiagram.passDoorOpen ? "#FF453A" : "#0A84FF"; width: 1.5 }

                Text {
                    anchors.centerIn: parent
                    text: "FR"
                    color: doorDiagram.passDoorOpen ? "#FFFFFF" : "#8E8E93"
                    font { pixelSize: 9; weight: Font.Bold }
                }
            }

            // Left-rear door
            Rectangle {
                x: 8; y: 84
                width: 28; height: 40; radius: 4
                color: doorDiagram.driverRearOpen  ? "#FF453A" : "#1C1C1E"
                border { color: doorDiagram.driverRearOpen ? "#FF453A" : "#0A84FF"; width: 1.5 }

                Text {
                    anchors.centerIn: parent
                    text: "RL"
                    color: doorDiagram.driverRearOpen ? "#FFFFFF" : "#8E8E93"
                    font { pixelSize: 9; weight: Font.Bold }
                }
            }

            // Right-rear door
            Rectangle {
                x: 164; y: 84
                width: 28; height: 40; radius: 4
                color: doorDiagram.passRearOpen    ? "#FF453A" : "#1C1C1E"
                border { color: doorDiagram.passRearOpen ? "#FF453A" : "#0A84FF"; width: 1.5 }

                Text {
                    anchors.centerIn: parent
                    text: "RR"
                    color: doorDiagram.passRearOpen ? "#FFFFFF" : "#8E8E93"
                    font { pixelSize: 9; weight: Font.Bold }
                }
            }

            // Trunk indicator (below rear of car)
            Rectangle {
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 16 }
                width: 60; height: 14; radius: 3
                color: doorDiagram.trunkIsOpen ? "#FF453A" : "#1C1C1E"
                border { color: doorDiagram.trunkIsOpen ? "#FF453A" : "#2C2C2E"; width: 1 }

                Text {
                    anchors.centerIn: parent
                    text: "TRUNK"
                    color: doorDiagram.trunkIsOpen ? "#FFFFFF" : "#3A3A3C"
                    font { pixelSize: 8; weight: Font.Bold }
                }
            }

            Text {
                anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
                text: "DOORS"
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
            }
        }

        // ── Fuel gauge arc ──────────────────────────────────────────────────
        Item {
            width: 160; height: 160

            // Arc via Canvas
            Canvas {
                id: fuelArc
                anchors.fill: parent

                // Fuel level 0.0–1.0 — VehicleService doesn't expose fuel yet;
                // binding as constant 0.75 placeholder until the property is added.
                property real fuelLevel: 0.75

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)

                    var cx = width / 2
                    var cy = height / 2 + 10
                    var r  = 58

                    // Track (background arc)
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, Math.PI * 0.75, Math.PI * 2.25, false)
                    ctx.strokeStyle = "#2C2C2E"
                    ctx.lineWidth = 10
                    ctx.lineCap = "round"
                    ctx.stroke()

                    // Fill arc — color based on level
                    var sweep = fuelLevel * Math.PI * 1.5  // 270° total sweep
                    if (sweep > 0.01) {
                        ctx.beginPath()
                        ctx.arc(cx, cy, r, Math.PI * 0.75, Math.PI * 0.75 + sweep, false)
                        var arcColor = fuelLevel > 0.25 ? "#30D158"
                                     : fuelLevel > 0.1  ? "#FF9F0A"
                                                         : "#FF453A"
                        ctx.strokeStyle = arcColor
                        ctx.lineWidth = 10
                        ctx.lineCap = "round"
                        ctx.stroke()
                    }
                }

                onFuelLevelChanged: requestPaint()
                Component.onCompleted: requestPaint()
            }

            // Center text
            Column {
                anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter; verticalCenterOffset: 10 }
                spacing: 2

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Math.round(fuelArc.fuelLevel * 100) + "%"
                    color: fuelArc.fuelLevel > 0.25 ? "#FFFFFF"
                          : fuelArc.fuelLevel > 0.1  ? "#FF9F0A"
                                                      : "#FF453A"
                    font { family: "Roboto"; pixelSize: 26; weight: Font.Bold }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "FUEL"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                }
            }

            // E / F labels
            Text {
                anchors { left: parent.left; bottom: parent.bottom; leftMargin: 14; bottomMargin: 8 }
                text: "E"
                color: "#3A3A3C"
                font { family: "Roboto"; pixelSize: 11; weight: Font.Bold }
            }
            Text {
                anchors { right: parent.right; bottom: parent.bottom; rightMargin: 14; bottomMargin: 8 }
                text: "F"
                color: "#3A3A3C"
                font { family: "Roboto"; pixelSize: 11; weight: Font.Bold }
            }
        }
    }

    // Row 2: Drive Mode pill + Parking brake
    Row {
        anchors {
            top: topRow.bottom
            horizontalCenter: parent.horizontalCenter
            topMargin: 12
        }
        spacing: 16

        // Drive mode pill — VehicleService doesn't expose driveMode yet;
        // derive from gear/RPM context as best-effort placeholder.
        // Hardcoded to STANDARD until service exposes the property.
        Rectangle {
            height: 36; radius: 18
            width: driveModeLabel.width + 48
            color: "#1C1C1E"
            border { color: "#0A84FF"; width: 1.5 }

            Text {
                id: driveModeLabel
                anchors.centerIn: parent
                text: "STANDARD"
                color: "#0A84FF"
                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold; capitalization: Font.AllUppercase; letterSpacing: 1.5 }
            }
        }

        // Parking brake indicator
        Rectangle {
            height: 36; radius: 18
            width: pbLabel.width + 32
            color: VehicleService.parkingBrake ? "#3A0000" : "#1C1C1E"
            border { color: VehicleService.parkingBrake ? "#FF453A" : "#2C2C2E"; width: 1.5 }
            visible: VehicleService.parkingBrake

            Text {
                id: pbLabel
                anchors.centerIn: parent
                text: "P  PARK BRAKE"
                color: "#FF453A"
                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
            }
        }
    }

    // Row 3: Coolant temp bar + RPM
    Row {
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 16
        }
        spacing: 32

        // Coolant temp bar
        Column {
            spacing: 8

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6
                Text {
                    text: "ENGINE TEMP"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                }
                Text {
                    text: VehicleService.coolantTemp > 32 ? Math.round(VehicleService.coolantTemp) + "°F" : "—"
                    color: VehicleService.coolantTemp > 230 ? "#FF453A"
                          : VehicleService.coolantTemp > 210 ? "#FF9F0A"
                                                             : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 10; weight: Font.SemiBold }
                }
            }

            Item {
                width: 180; height: 12

                Rectangle {
                    anchors.fill: parent; radius: 6
                    color: "#2C2C2E"
                }

                // Coolant temp from VehicleService.coolantTemp (°F, parsed from CAN 0x551)
                // Scale: 100°F = cold (0.0), 210°F = normal (0.69), 260°F = danger (1.0)
                property real coolantNorm: Math.min(1.0, Math.max(0.0, (VehicleService.coolantTemp - 100.0) / 160.0))

                Rectangle {
                    width: parent.parent.children[1].coolantNorm * 180
                    height: 12; radius: 6

                    Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

                    color: parent.parent.children[1].coolantNorm > 0.9 ? "#FF453A"
                          : parent.parent.children[1].coolantNorm > 0.75 ? "#FF9F0A"
                                                                          : "#0A84FF"
                }
            }

            Row {
                spacing: 0
                width: 180
                Text {
                    text: "COLD"
                    color: "#3A3A3C"
                    font { family: "Roboto"; pixelSize: 10 }
                }
                Item { width: parent.width - 70; height: 1 }
                Text {
                    text: "HOT"
                    color: "#3A3A3C"
                    font { family: "Roboto"; pixelSize: 10 }
                }
            }
        }

        // RPM display
        Column {
            spacing: 4

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: VehicleService.rpm.toFixed(0)
                color: VehicleService.rpm > 5500 ? "#FF453A" : "#FFFFFF"
                font { family: "Roboto"; pixelSize: 34; weight: Font.Bold }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "RPM"
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
            }
        }
    }
}
