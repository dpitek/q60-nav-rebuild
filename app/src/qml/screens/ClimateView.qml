// ClimateView — Full HVAC control for lower screen
// Redesigned: top action row + dual-zone cards + extras row + outside temp footer
import QtQuick 6.6
import QtQuick.Controls 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Top action row — AUTO / MAX A/C / MAX DEF / SYNC ─────────────────────
    Row {
        id: actionRow
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
            topMargin: 8
            leftMargin: 8
            rightMargin: 8
        }
        height: 44
        spacing: 8

        // Distribute evenly: each button = (width - 3*spacing) / 4
        property real btnW: (parent.width - 3 * spacing - anchors.leftMargin - anchors.rightMargin) / 4

        // AUTO
        Rectangle {
            width: actionRow.btnW; height: 44; radius: 22
            color: VehicleService.autoClimateOn ? "#0A84FF" : "#1C1C1E"
            border.color: "#0A84FF"; border.width: 1.5

            Behavior on color { ColorAnimation { duration: 150 } }

            Text {
                anchors.centerIn: parent
                text: "AUTO"
                color: VehicleService.autoClimateOn ? "#FFFFFF" : "#0A84FF"
                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: VehicleService.setAutoClimate(!VehicleService.autoClimateOn)
            }
        }

        // MAX A/C — flash only, no persistent toggle
        Rectangle {
            id: maxAcBtn
            width: actionRow.btnW; height: 44; radius: 22
            color: maxAcFlash ? "#0A84FF" : "#1C1C1E"
            border.color: "#0A84FF"; border.width: 1.5

            property bool maxAcFlash: false

            Behavior on color { ColorAnimation { duration: 150 } }

            Text {
                anchors.centerIn: parent
                text: "MAX A/C"
                color: maxAcBtn.maxAcFlash ? "#FFFFFF" : "#0A84FF"
                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    VehicleService.setMaxAC()
                    maxAcBtn.maxAcFlash = true
                    maxAcFlashTimer.restart()
                }
            }
            Timer {
                id: maxAcFlashTimer
                interval: 300
                onTriggered: maxAcBtn.maxAcFlash = false
            }
        }

        // MAX DEF — flash only, no persistent toggle
        Rectangle {
            id: maxDefBtn
            width: actionRow.btnW; height: 44; radius: 22
            color: maxDefFlash ? "#0A84FF" : "#1C1C1E"
            border.color: "#0A84FF"; border.width: 1.5

            property bool maxDefFlash: false

            Behavior on color { ColorAnimation { duration: 150 } }

            Text {
                anchors.centerIn: parent
                text: "MAX DEF"
                color: maxDefBtn.maxDefFlash ? "#FFFFFF" : "#0A84FF"
                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    VehicleService.setMaxDefrost()
                    maxDefBtn.maxDefFlash = true
                    maxDefFlashTimer.restart()
                }
            }
            Timer {
                id: maxDefFlashTimer
                interval: 300
                onTriggered: maxDefBtn.maxDefFlash = false
            }
        }

        // SYNC
        Rectangle {
            id: syncBtn
            width: actionRow.btnW; height: 44; radius: 22
            color: syncFlash ? "#0A84FF" : "#1C1C1E"
            border.color: "#0A84FF"; border.width: 1.5

            property bool syncFlash: false

            Behavior on color { ColorAnimation { duration: 150 } }

            Text {
                anchors.centerIn: parent
                text: "SYNC"
                color: syncBtn.syncFlash ? "#FFFFFF" : "#0A84FF"
                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    VehicleService.syncZones()
                    syncBtn.syncFlash = true
                    syncFlashTimer.restart()
                }
            }
            Timer {
                id: syncFlashTimer
                interval: 300
                onTriggered: syncBtn.syncFlash = false
            }
        }
    }

    // ── Main zone row ─────────────────────────────────────────────────────────
    Row {
        id: zoneRow
        anchors {
            top: actionRow.bottom
            horizontalCenter: parent.horizontalCenter
            topMargin: 8
        }
        spacing: 12

        // ── Driver zone card ──────────────────────────────────────────────────
        Rectangle {
            width: 180; height: 218; radius: 16
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 }
                spacing: 6

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "DRIVER"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1.5 }
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 56; height: 56; radius: 28
                    color: drvUp.pressed ? "#2C2C2E" : "transparent"
                    border { color: "#0A84FF"; width: 1.5 }
                    Text { anchors.centerIn: parent; text: "▲"; color: "#0A84FF"; font { pixelSize: 20 } }
                    MouseArea {
                        id: drvUp; anchors.fill: parent
                        onClicked: VehicleService.setDriverTemp(Math.min(85, VehicleService.driverTemp + 1))
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: VehicleService.driverTemp.toFixed(0) + "°"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 36; weight: Font.Bold }
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 56; height: 56; radius: 28
                    color: drvDn.pressed ? "#2C2C2E" : "transparent"
                    border { color: "#0A84FF"; width: 1.5 }
                    Text { anchors.centerIn: parent; text: "▼"; color: "#0A84FF"; font { pixelSize: 20 } }
                    MouseArea {
                        id: drvDn; anchors.fill: parent
                        onClicked: VehicleService.setDriverTemp(Math.max(60, VehicleService.driverTemp - 1))
                    }
                }

                // Seat heat dots
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6
                    Repeater {
                        model: 3
                        delegate: Rectangle {
                            width: 26; height: 26; radius: 13
                            color: VehicleService.driverSeat > index ? Qt.rgba(1, 0.6235, 0.0392, 0.25) : "#2C2C2E"
                            border { color: VehicleService.driverSeat > index ? "#FF9F0A" : "#3A3A3C"; width: 1.5 }
                            Text {
                                anchors.centerIn: parent; text: "●"
                                color: VehicleService.driverSeat > index ? "#FF9F0A" : "#3A3A3C"
                                font { pixelSize: 10 }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: VehicleService.setDriverSeatHeat(
                                    VehicleService.driverSeat === index + 1 ? 0 : index + 1)
                            }
                        }
                    }
                }
            }
        }

        // ── Center controls card ──────────────────────────────────────────────
        Rectangle {
            width: 168; height: 164; radius: 16
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 14 }
                spacing: 10

                // Airflow modes — 5 tiles including Feet+Def
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 5

                    Repeater {
                        model: [
                            { icon: "☁",  mode: 0, tip: "Face" },
                            { icon: "↓",  mode: 1, tip: "Feet" },
                            { icon: "◈",  mode: 2, tip: "Blend" },
                            { icon: "❄",  mode: 3, tip: "Defrost" },
                            { icon: "↓❄", mode: 4, tip: "Feet+Def" }
                        ]
                        delegate: Rectangle {
                            width: 28; height: 28; radius: 8
                            color: VehicleService.climateMode === modelData.mode ? "#0A84FF" : "#2C2C2E"
                            border {
                                color: VehicleService.climateMode === modelData.mode
                                       ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.1)
                                width: 1
                            }
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text {
                                anchors.centerIn: parent
                                text: modelData.icon
                                color: VehicleService.climateMode === modelData.mode ? "#FFFFFF" : "#8E8E93"
                                font { pixelSize: 11 }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: VehicleService.setClimateMode(modelData.mode)
                            }
                        }
                    }
                }

                // A/C + Recirc
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    Rectangle {
                        width: 72; height: 40; radius: 12
                        color: VehicleService.acOn ? Qt.rgba(0.0392, 0.5176, 1, 0.2) : "#2C2C2E"
                        border { color: VehicleService.acOn ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.1); width: 1.5 }
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text {
                            anchors.centerIn: parent; text: "A/C"
                            color: VehicleService.acOn ? "#0A84FF" : "#8E8E93"
                            font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: VehicleService.setAcOn(!VehicleService.acOn)
                        }
                    }

                    Rectangle {
                        width: 72; height: 40; radius: 12
                        color: VehicleService.recircOn ? Qt.rgba(0.0392, 0.5176, 1, 0.2) : "#2C2C2E"
                        border { color: VehicleService.recircOn ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.1); width: 1.5 }
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text {
                            anchors.centerIn: parent; text: "⟳ RECIRC"
                            color: VehicleService.recircOn ? "#0A84FF" : "#8E8E93"
                            font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: VehicleService.setRecircOn(!VehicleService.recircOn)
                        }
                    }
                }

                // Outside temp
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: VehicleService.outsideTemp.toFixed(0) + "°F outside"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 12 }
                }
            }
        }

        // ── Passenger zone card ───────────────────────────────────────────────
        Rectangle {
            width: 180; height: 218; radius: 16
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 }
                spacing: 6

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "PASSENGER"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1.5 }
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 56; height: 56; radius: 28
                    color: paxUp.pressed ? "#2C2C2E" : "transparent"
                    border { color: "#0A84FF"; width: 1.5 }
                    Text { anchors.centerIn: parent; text: "▲"; color: "#0A84FF"; font { pixelSize: 20 } }
                    MouseArea {
                        id: paxUp; anchors.fill: parent
                        onClicked: VehicleService.setPassengerTemp(Math.min(85, VehicleService.passengerTemp + 1))
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: VehicleService.passengerTemp.toFixed(0) + "°"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 36; weight: Font.Bold }
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 56; height: 56; radius: 28
                    color: paxDn.pressed ? "#2C2C2E" : "transparent"
                    border { color: "#0A84FF"; width: 1.5 }
                    Text { anchors.centerIn: parent; text: "▼"; color: "#0A84FF"; font { pixelSize: 20 } }
                    MouseArea {
                        id: paxDn; anchors.fill: parent
                        onClicked: VehicleService.setPassengerTemp(Math.max(60, VehicleService.passengerTemp - 1))
                    }
                }

                // Seat heat dots
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6
                    Repeater {
                        model: 3
                        delegate: Rectangle {
                            width: 26; height: 26; radius: 13
                            color: VehicleService.passSeat > index ? Qt.rgba(1, 0.6235, 0.0392, 0.25) : "#2C2C2E"
                            border { color: VehicleService.passSeat > index ? "#FF9F0A" : "#3A3A3C"; width: 1.5 }
                            Text {
                                anchors.centerIn: parent; text: "●"
                                color: VehicleService.passSeat > index ? "#FF9F0A" : "#3A3A3C"
                                font { pixelSize: 10 }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: VehicleService.setPassSeatHeat(
                                    VehicleService.passSeat === index + 1 ? 0 : index + 1)
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Full-width fan speed row ──────────────────────────────────────────────
    // 6 large buttons (OFF + 1–5) spread across the full screen width.
    Row {
        id: fanSpeedRow
        anchors {
            top: zoneRow.bottom
            left: parent.left; right: parent.right
            topMargin: 8; leftMargin: 8; rightMargin: 8
        }
        height: 52
        spacing: 6

        // Computed width per button: fill row evenly across 6 slots
        property real btnW: (parent.width - anchors.leftMargin - anchors.rightMargin - 5 * spacing) / 6

        // OFF
        Rectangle {
            width: fanSpeedRow.btnW; height: 46; radius: 12
            anchors.verticalCenter: parent.verticalCenter
            color: VehicleService.fanSpeed === 0 ? "#FF453A" : "#1C1C1E"
            border { color: VehicleService.fanSpeed === 0 ? "#FF453A" : "#3A3A3C"; width: 1.5 }
            Behavior on color { ColorAnimation { duration: 150 } }
            Text {
                anchors.centerIn: parent; text: "OFF"
                color: VehicleService.fanSpeed === 0 ? "#FFFFFF" : "#8E8E93"
                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
            }
            MouseArea { anchors.fill: parent; onClicked: VehicleService.setFanSpeed(0) }
        }

        // Speeds 1–5
        Repeater {
            model: 5
            delegate: Rectangle {
                width: fanSpeedRow.btnW; height: 46; radius: 12
                anchors.verticalCenter: parent.verticalCenter
                color: VehicleService.fanSpeed === index + 1 ? "#0A84FF"
                     : VehicleService.fanSpeed > index      ? Qt.rgba(0.0392, 0.5176, 1, 0.25)
                     : "#1C1C1E"
                border {
                    color: VehicleService.fanSpeed >= index + 1 ? "#0A84FF" : "#3A3A3C"
                    width: 1.5
                }
                Behavior on color { ColorAnimation { duration: 150 } }
                Text {
                    anchors.centerIn: parent
                    text: (index + 1).toString()
                    color: VehicleService.fanSpeed >= index + 1 ? "#FFFFFF" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 16; weight: Font.Bold }
                }
                MouseArea { anchors.fill: parent; onClicked: VehicleService.setFanSpeed(index + 1) }
            }
        }
    }

    // ── Bottom extras row ─────────────────────────────────────────────────────
    Row {
        id: extrasRow
        anchors {
            top: fanSpeedRow.bottom
            horizontalCenter: parent.horizontalCenter
            topMargin: 8
        }
        spacing: 12
        height: 56

        // 1. Heated Steering Wheel
        Rectangle {
            width: 68; height: 48; radius: 16
            color: VehicleService.heatedSteeringWheel ? Qt.rgba(1, 0.6235, 0.0392, 0.2) : "#1C1C1E"
            border {
                color: VehicleService.heatedSteeringWheel ? "#FF9F0A" : "#2C2C2E"
                width: 1.5
            }
            Behavior on color { ColorAnimation { duration: 150 } }

            Column {
                anchors.centerIn: parent
                spacing: 2
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "⊙"
                    color: VehicleService.heatedSteeringWheel ? "#FF9F0A" : "#8E8E93"
                    font { pixelSize: 18 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "ST. WHEEL"
                    color: VehicleService.heatedSteeringWheel ? "#FF9F0A" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 8; capitalization: Font.AllUppercase; letterSpacing: 0.8 }
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: VehicleService.setHeatedSteeringWheel(!VehicleService.heatedSteeringWheel)
            }
        }

        // 2. Plasmacluster — 4-level cycle (0–3)
        Rectangle {
            id: plasmaCard
            width: 68; height: 48; radius: 16
            color: VehicleService.plasmaclusterLevel > 0 ? Qt.rgba(0.0392, 0.5176, 1, 0.18) : "#1C1C1E"
            border {
                color: VehicleService.plasmaclusterLevel > 0 ? "#0A84FF" : "#2C2C2E"
                width: 1.5
            }
            Behavior on color { ColorAnimation { duration: 150 } }

            Column {
                anchors.centerIn: parent
                spacing: 2
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "◉"
                    color: VehicleService.plasmaclusterLevel > 0 ? "#0A84FF" : "#8E8E93"
                    font { pixelSize: 18 }
                }
                // Level dots
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 2
                    Repeater {
                        model: 3
                        delegate: Text {
                            text: VehicleService.plasmaclusterLevel > index ? "●" : "○"
                            color: VehicleService.plasmaclusterLevel > 0 ? "#0A84FF" : "#3A3A3C"
                            font { pixelSize: 7 }
                        }
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "PLASMA"
                    color: VehicleService.plasmaclusterLevel > 0 ? "#0A84FF" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 8; capitalization: Font.AllUppercase; letterSpacing: 0.8 }
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: VehicleService.setPlasmacluster((VehicleService.plasmaclusterLevel + 1) % 4)
            }
        }

        // 3. Rain Sensor
        Rectangle {
            width: 68; height: 48; radius: 16
            color: VehicleService.rainSensorEnabled ? Qt.rgba(0.0392, 0.5176, 1, 0.18) : "#1C1C1E"
            border {
                color: VehicleService.rainSensorEnabled ? "#0A84FF" : "#2C2C2E"
                width: 1.5
            }
            Behavior on color { ColorAnimation { duration: 150 } }

            Column {
                anchors.centerIn: parent
                spacing: 2
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "⛆"
                    color: VehicleService.rainSensorEnabled ? "#0A84FF" : "#8E8E93"
                    font { pixelSize: 18 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "RAIN SENS"
                    color: VehicleService.rainSensorEnabled ? "#0A84FF" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 8; capitalization: Font.AllUppercase; letterSpacing: 0.8 }
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: VehicleService.setRainSensor(!VehicleService.rainSensorEnabled)
            }
        }

        // 4. Rear Defrost
        Rectangle {
            width: 68; height: 48; radius: 16
            color: VehicleService.rearDefrostOn ? Qt.rgba(1, 0.6235, 0.0392, 0.2) : "#1C1C1E"
            border {
                color: VehicleService.rearDefrostOn ? "#FF9F0A" : "#2C2C2E"
                width: 1.5
            }
            Behavior on color { ColorAnimation { duration: 150 } }

            Column {
                anchors.centerIn: parent
                spacing: 2
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "▦"
                    color: VehicleService.rearDefrostOn ? "#FF9F0A" : "#8E8E93"
                    font { pixelSize: 18 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "REAR DEF"
                    color: VehicleService.rearDefrostOn ? "#FF9F0A" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 8; capitalization: Font.AllUppercase; letterSpacing: 0.8 }
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: VehicleService.setRearDefrost(!VehicleService.rearDefrostOn)
            }
        }
    }

    // ── Outside temp footer ───────────────────────────────────────────────────
    Text {
        anchors {
            top: extrasRow.bottom
            horizontalCenter: parent.horizontalCenter
            topMargin: 4
        }
        text: VehicleService.outsideTemp.toFixed(0) + "°F outside"
        color: "#8E8E93"
        font { family: "Roboto"; pixelSize: 12 }
    }
}
