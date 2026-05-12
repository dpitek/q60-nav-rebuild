// ClimateView — Full HVAC control for lower screen (7")
// Driver/passenger temp zones, fan, AC, recirc, mode, seat heat
import QtQuick 6.6
import QtQuick.Controls 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    // Dark background
    Rectangle { anchors.fill: parent; color: "#080d12" }

    // ── Temperature Zones ────────────────────────────────────────────────
    Row {
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: 16
        }
        spacing: 40

        TempZone {
            label: "Driver"
            temperature: VehicleService.driverTemp
            isDriver: true
            onTempChanged: function(t) { VehicleService.setDriverTemp(t) }
        }

        // Center controls
        Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 12
            width: 160

            // Mode buttons
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                Repeater {
                    model: [{ icon: "☁", mode: 0, tip: "Face" },
                            { icon: "↓", mode: 1, tip: "Feet" },
                            { icon: "◈", mode: 2, tip: "Blend" },
                            { icon: "❄", mode: 3, tip: "Defrost" }]
                    delegate: Rectangle {
                        width: 34; height: 34; radius: 6
                        color: VehicleService.climateMode === modelData.mode
                               ? "#0d2a4a" : "#0e1520"
                        border {
                            color: VehicleService.climateMode === modelData.mode
                                   ? "#00d4ff" : "#1e2a3a"
                            width: 1
                        }
                        Text {
                            anchors.centerIn: parent
                            text: modelData.icon
                            color: VehicleService.climateMode === modelData.mode
                                   ? "#00d4ff" : "#445"
                            font.pixelSize: 16
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: VehicleService.setClimateMode(modelData.mode)
                        }
                    }
                }
            }

            // Fan speed
            FanControl {
                anchors.horizontalCenter: parent.horizontalCenter
                fanSpeed: VehicleService.fanSpeed
                onSpeedChanged: function(s) { VehicleService.setFanSpeed(s) }
            }

            // AC + Recirc toggles
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12

                Rectangle {
                    width: 66; height: 36; radius: 8
                    color: VehicleService.acOn ? "#0d2a4a" : "#0e1520"
                    border { color: VehicleService.acOn ? "#00d4ff" : "#1e2a3a"; width: 1 }
                    Text {
                        anchors.centerIn: parent
                        text: "A/C"
                        color: VehicleService.acOn ? "#00d4ff" : "#445"
                        font { pixelSize: 14; weight: Font.Bold }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: VehicleService.setAcOn(!VehicleService.acOn)
                    }
                }

                Rectangle {
                    width: 66; height: 36; radius: 8
                    color: VehicleService.recircOn ? "#0d2a4a" : "#0e1520"
                    border { color: VehicleService.recircOn ? "#00d4ff" : "#1e2a3a"; width: 1 }
                    Text {
                        anchors.centerIn: parent
                        text: "⟳"
                        color: VehicleService.recircOn ? "#00d4ff" : "#445"
                        font.pixelSize: 18
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: VehicleService.setRecircOn(!VehicleService.recircOn)
                    }
                }
            }
        }

        TempZone {
            label: "Passenger"
            temperature: VehicleService.passengerTemp
            isDriver: false
            onTempChanged: function(t) { VehicleService.setPassengerTemp(t) }
        }
    }

    // ── Seat Heat Row ────────────────────────────────────────────────────
    Row {
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 12
        }
        spacing: 30

        // Driver seat heat
        Column {
            spacing: 6
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "DRIVER SEAT"
                color: "#555"
                font { pixelSize: 10; capitalization: Font.AllUppercase }
            }
            Row {
                spacing: 4
                Repeater {
                    model: 4
                    delegate: Rectangle {
                        width: 28; height: 28; radius: 4
                        color: VehicleService.driverSeat > index ? "#2a1500" : "#0e1520"
                        border {
                            color: VehicleService.driverSeat > index ? "#ff6600" : "#1e2a3a"
                            width: 1
                        }
                        Text {
                            anchors.centerIn: parent
                            text: index === 0 ? "OFF" : String(index)
                            color: VehicleService.driverSeat > index ? "#ff6600" : "#445"
                            font.pixelSize: 11
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: VehicleService.setDriverSeatHeat(index)
                        }
                    }
                }
            }
        }

        // Outside temp display
        Column {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: VehicleService.outsideTemp.toFixed(0) + "°F"
                color: "#f0f0f0"
                font { pixelSize: 28; weight: Font.Light }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "OUTSIDE"
                color: "#444"
                font { pixelSize: 9; capitalization: Font.AllUppercase }
            }
        }

        // Passenger seat heat
        Column {
            spacing: 6
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "PASS SEAT"
                color: "#555"
                font { pixelSize: 10; capitalization: Font.AllUppercase }
            }
            Row {
                spacing: 4
                Repeater {
                    model: 4
                    delegate: Rectangle {
                        width: 28; height: 28; radius: 4
                        color: VehicleService.passSeat > index ? "#2a1500" : "#0e1520"
                        border {
                            color: VehicleService.passSeat > index ? "#ff6600" : "#1e2a3a"
                            width: 1
                        }
                        Text {
                            anchors.centerIn: parent
                            text: index === 0 ? "OFF" : String(index)
                            color: VehicleService.passSeat > index ? "#ff6600" : "#445"
                            font.pixelSize: 11
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: VehicleService.setPassSeatHeat(index)
                        }
                    }
                }
            }
        }
    }
}
