// ClimateView — Full HVAC control for lower screen
// Apple CarPlay aesthetic redesign
// All VehicleService bindings preserved exactly.
import QtQuick 6.6
import QtQuick.Controls 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Two zone cards side-by-side ─────────────────────────────────────────
    Row {
        id: zoneRow
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: 16
        }
        spacing: 12

        // ── Driver zone card ─────────────────────────────────────────────────
        Rectangle {
            width: 180; height: 210; radius: 16
            color: "#1C1C1E"
            border { color: "rgba(255,255,255,0.15)"; width: 1 }

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 }
                spacing: 6

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "DRIVER"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1.5 }
                }

                // Up button
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 56; height: 56; radius: 28
                    color: drvUp.pressed ? "#2C2C2E" : "transparent"
                    border { color: "#0A84FF"; width: 1.5 }

                    Text { anchors.centerIn: parent; text: "▲"; color: "#0A84FF"; font { pixelSize: 20 } }

                    MouseArea {
                        id: drvUp; anchors.fill: parent
                        onClicked: VehicleService.setDriverTemp(
                            Math.min(85, VehicleService.driverTemp + 1))
                    }
                }

                // Temperature
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: VehicleService.driverTemp.toFixed(0) + "°"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 36; weight: Font.Bold }
                }

                // Down button
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 56; height: 56; radius: 28
                    color: drvDn.pressed ? "#2C2C2E" : "transparent"
                    border { color: "#0A84FF"; width: 1.5 }

                    Text { anchors.centerIn: parent; text: "▼"; color: "#0A84FF"; font { pixelSize: 20 } }

                    MouseArea {
                        id: drvDn; anchors.fill: parent
                        onClicked: VehicleService.setDriverTemp(
                            Math.max(60, VehicleService.driverTemp - 1))
                    }
                }

                // Seat heat dots (3 levels: ●●○ style)
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6

                    Repeater {
                        model: 3
                        delegate: Rectangle {
                            width: 26; height: 26; radius: 13
                            color: VehicleService.driverSeat > index
                                   ? "rgba(255,159,10,0.25)" : "#2C2C2E"
                            border {
                                color: VehicleService.driverSeat > index ? "#FF9F0A" : "#3A3A3C"
                                width: 1.5
                            }
                            Text {
                                anchors.centerIn: parent
                                text: index === 0 ? "●" : "●"
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

        // ── Center controls card ─────────────────────────────────────────────
        Rectangle {
            width: 168; height: 210; radius: 16
            color: "#1C1C1E"
            border { color: "rgba(255,255,255,0.15)"; width: 1 }

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 14 }
                spacing: 10

                // Mode buttons (4 modes)
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6

                    Repeater {
                        model: [
                            { icon: "☁", mode: 0, tip: "Face" },
                            { icon: "↓", mode: 1, tip: "Feet" },
                            { icon: "◈", mode: 2, tip: "Blend" },
                            { icon: "❄", mode: 3, tip: "Defrost" }
                        ]
                        delegate: Rectangle {
                            width: 36; height: 36; radius: 10
                            color: VehicleService.climateMode === modelData.mode
                                   ? "#0A84FF" : "#2C2C2E"
                            border {
                                color: VehicleService.climateMode === modelData.mode
                                       ? "#0A84FF" : "rgba(255,255,255,0.1)"
                                width: 1
                            }
                            Text {
                                anchors.centerIn: parent
                                text: modelData.icon
                                color: VehicleService.climateMode === modelData.mode
                                       ? "#FFFFFF" : "#8E8E93"
                                font { pixelSize: 16 }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: VehicleService.setClimateMode(modelData.mode)
                            }
                        }
                    }
                }

                // Fan speed — 5-dot row
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "FAN"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 5

                        // Off button
                        Rectangle {
                            width: 24; height: 24; radius: 12
                            color: VehicleService.fanSpeed === 0 ? "#FF453A" : "#2C2C2E"
                            border { color: VehicleService.fanSpeed === 0 ? "#FF453A" : "#3A3A3C"; width: 1 }
                            Text {
                                anchors.centerIn: parent; text: "0"
                                color: VehicleService.fanSpeed === 0 ? "#FFFFFF" : "#8E8E93"
                                font { pixelSize: 9; weight: Font.Bold }
                            }
                            MouseArea { anchors.fill: parent; onClicked: VehicleService.setFanSpeed(0) }
                        }

                        Repeater {
                            model: 5
                            delegate: Rectangle {
                                width: 22; height: 22 + index * 3; radius: 4
                                anchors.bottom: parent ? parent.bottom : undefined
                                color: VehicleService.fanSpeed > index
                                       ? "#0A84FF" : "#2C2C2E"
                                border { color: VehicleService.fanSpeed > index ? "#0A84FF" : "#3A3A3C"; width: 1 }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: VehicleService.setFanSpeed(index + 1)
                                }
                            }
                        }
                    }
                }

                // AC + Recirc
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    Rectangle {
                        width: 72; height: 40; radius: 12
                        color: VehicleService.acOn ? "rgba(10,132,255,0.2)" : "#2C2C2E"
                        border { color: VehicleService.acOn ? "#0A84FF" : "rgba(255,255,255,0.1)"; width: 1.5 }

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
                        color: VehicleService.recircOn ? "rgba(10,132,255,0.2)" : "#2C2C2E"
                        border { color: VehicleService.recircOn ? "#0A84FF" : "rgba(255,255,255,0.1)"; width: 1.5 }

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

        // ── Passenger zone card ──────────────────────────────────────────────
        Rectangle {
            width: 180; height: 210; radius: 16
            color: "#1C1C1E"
            border { color: "rgba(255,255,255,0.15)"; width: 1 }

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 }
                spacing: 6

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "PASSENGER"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1.5 }
                }

                // Up button
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 56; height: 56; radius: 28
                    color: paxUp.pressed ? "#2C2C2E" : "transparent"
                    border { color: "#0A84FF"; width: 1.5 }

                    Text { anchors.centerIn: parent; text: "▲"; color: "#0A84FF"; font { pixelSize: 20 } }

                    MouseArea {
                        id: paxUp; anchors.fill: parent
                        onClicked: VehicleService.setPassengerTemp(
                            Math.min(85, VehicleService.passengerTemp + 1))
                    }
                }

                // Temperature
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: VehicleService.passengerTemp.toFixed(0) + "°"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 36; weight: Font.Bold }
                }

                // Down button
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 56; height: 56; radius: 28
                    color: paxDn.pressed ? "#2C2C2E" : "transparent"
                    border { color: "#0A84FF"; width: 1.5 }

                    Text { anchors.centerIn: parent; text: "▼"; color: "#0A84FF"; font { pixelSize: 20 } }

                    MouseArea {
                        id: paxDn; anchors.fill: parent
                        onClicked: VehicleService.setPassengerTemp(
                            Math.max(60, VehicleService.passengerTemp - 1))
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
                            color: VehicleService.passSeat > index
                                   ? "rgba(255,159,10,0.25)" : "#2C2C2E"
                            border {
                                color: VehicleService.passSeat > index ? "#FF9F0A" : "#3A3A3C"
                                width: 1.5
                            }
                            Text {
                                anchors.centerIn: parent
                                text: "●"
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
}
