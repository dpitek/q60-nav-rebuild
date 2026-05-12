// InfoView — Lower screen Info tab
// Cards: Weather · Fuel Prices · Parking Location · Trip History
// All data is STATIC MOCK — API wiring noted per card.
import QtQuick 6.6

Item {
    id: root
    anchors.fill: parent

    property bool hasParkingLocation: true  // show mock parked-location card

    Rectangle { anchors.fill: parent; color: "#000000" }

    Flickable {
        anchors { fill: parent; margins: 12 }
        contentHeight: cardCol.implicitHeight
        clip: true

        Column {
            id: cardCol
            width: parent.width
            spacing: 12

            // ── Weather Card ─────────────────────────────────────────────────
            // TODO: wire to OpenWeatherMap API once network is available
            Rectangle {
                width: parent.width; height: 120
                radius: 16
                color: "#1C1C1E"
                border { color: "rgba(255,255,255,0.08)"; width: 1 }

                Row {
                    anchors { fill: parent; margins: 14 }
                    spacing: 0

                    // Left: current conditions
                    Column {
                        width: parent.width * 0.45
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Row {
                            spacing: 8
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "⛅"
                                font { pixelSize: 32 }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                // Color coding: blue <50°F, white 50-80°F, amber >80°F
                                text: "72°F"
                                color: "#FFFFFF"   // 72 is in 50-80 range
                                font { family: "Roboto"; pixelSize: 36; weight: Font.Bold }
                            }
                        }

                        Text {
                            text: "Partly Cloudy"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 13 }
                        }
                        Text {
                            text: "Cary, NC  •  Updated 9:41 AM"
                            color: "#3A3A3C"
                            font { family: "Roboto"; pixelSize: 10 }
                        }
                    }

                    // Right: 4-day forecast
                    Row {
                        width: parent.width * 0.55
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0

                        Repeater {
                            model: [
                                { day: "MON", hi: "75°", lo: "58°", icon: "⛅" },
                                { day: "TUE", hi: "68°", lo: "52°", icon: "🌧" },
                                { day: "WED", hi: "71°", lo: "55°", icon: "⛅" },
                                { day: "THU", hi: "80°", lo: "62°", icon: "☀" }
                            ]

                            delegate: Column {
                                width: parent.width / 4
                                spacing: 3
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.day
                                    color: "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 9; weight: Font.Medium; letterSpacing: 0.5 }
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.icon
                                    font { pixelSize: 16 }
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.hi
                                    // hi color: amber if >80, else white
                                    color: parseInt(modelData.hi) > 80 ? "#FF9F0A" : "#FFFFFF"
                                    font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.lo
                                    color: "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 11 }
                                }
                            }
                        }
                    }
                }
            }

            // ── Fuel Prices Card ─────────────────────────────────────────────
            // TODO: wire to GasBuddy API
            Rectangle {
                width: parent.width; height: 110
                radius: 16
                color: "#1C1C1E"
                border { color: "rgba(255,255,255,0.08)"; width: 1 }

                Column {
                    anchors { fill: parent; margins: 12 }
                    spacing: 6

                    // Header
                    Text {
                        text: "⛽  Nearby Fuel"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                    }

                    // Station rows
                    // Cheapest regular = BP at $3.25 — highlighted green
                    Repeater {
                        model: [
                            { name: "Shell",  dist: "0.4 mi", reg: "$3.29", prem: "$3.79", diesel: "$3.99", cheapest: false },
                            { name: "BP",     dist: "1.1 mi", reg: "$3.25", prem: "$3.75", diesel: "$3.95", cheapest: true  },
                            { name: "Exxon",  dist: "1.8 mi", reg: "$3.31", prem: "$3.81", diesel: "$4.01", cheapest: false }
                        ]

                        delegate: Row {
                            width: parent.width
                            spacing: 0

                            Text {
                                width: parent.width * 0.22
                                text: modelData.name
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 12 }
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width * 0.18
                                text: modelData.dist
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 11 }
                            }
                            Text {
                                width: parent.width * 0.20
                                text: modelData.reg
                                color: modelData.cheapest ? "#30D158" : "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 12; weight: modelData.cheapest ? Font.SemiBold : Font.Normal }
                            }
                            Text {
                                width: parent.width * 0.20
                                text: modelData.prem
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 11 }
                            }
                            Text {
                                width: parent.width * 0.20
                                text: modelData.diesel
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 11 }
                            }
                        }
                    }
                }
            }

            // ── Parking Location Card ─────────────────────────────────────────
            // Saved automatically on ignition-off
            Rectangle {
                width: parent.width; height: 100
                radius: 16
                color: "#1C1C1E"
                border { color: "rgba(255,255,255,0.08)"; width: 1 }

                Column {
                    anchors { fill: parent; margins: 12 }
                    spacing: 8

                    // Header
                    Text {
                        text: "🅿  Last Parked"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                    }

                    // Location row
                    Row {
                        width: parent.width
                        spacing: 10
                        visible: hasParkingLocation

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "📍"
                            font { pixelSize: 20 }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 110
                            spacing: 2

                            Text {
                                text: "Cary Towne Center  —  2½ hrs ago"
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
                                width: parent.width; elide: Text.ElideRight
                            }
                            Text {
                                text: "1105 Walnut St, Cary, NC"
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 11 }
                                width: parent.width; elide: Text.ElideRight
                            }
                        }

                        // Navigate Back pill
                        Rectangle {
                            height: 30; width: navBackLabel.implicitWidth + 18
                            radius: 15
                            color: "#0A84FF"
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                id: navBackLabel
                                anchors.centerIn: parent
                                text: "Navigate Back"
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
                            }

                            MouseArea { anchors.fill: parent; onClicked: { /* no-op */ } }
                        }
                    }

                    Text {
                        text: "Saved automatically on ignition-off"
                        color: "#3A3A3C"
                        font { family: "Roboto"; pixelSize: 10 }
                        visible: hasParkingLocation
                    }
                }
            }

            // ── Trip History Card ─────────────────────────────────────────────
            // GPX logs saved on ignition-off — TODO: wire to trip logger
            Rectangle {
                width: parent.width; height: 162
                radius: 16
                color: "#1C1C1E"
                border { color: "rgba(255,255,255,0.08)"; width: 1 }

                Column {
                    anchors { fill: parent; margins: 12 }
                    spacing: 6

                    // Header
                    Text {
                        text: "🗺  Recent Trips"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                    }

                    // Trip rows
                    Repeater {
                        model: [
                            { when: "Today 7:42 AM",       route: "Home → Work",             dist: "18.4 mi", mpg: "28.6 MPG", dur: "32 min" },
                            { when: "Yesterday 5:18 PM",   route: "Work → Target",            dist: "4.2 mi",  mpg: "30.1 MPG", dur: "9 min"  },
                            { when: "2026-05-11",          route: "Home → Topsail Island",    dist: "123.7 mi",mpg: "31.2 MPG", dur: "2h 14m" },
                            { when: "2026-05-10",          route: "Durham → Home",            dist: "27.1 mi", mpg: "27.8 MPG", dur: "41 min" }
                        ]

                        delegate: Row {
                            width: parent.width
                            spacing: 0

                            Column {
                                width: parent.width - 16
                                spacing: 1

                                Text {
                                    text: modelData.when + "  ·  " + modelData.route
                                    color: "#FFFFFF"
                                    font { family: "Roboto"; pixelSize: 12; weight: Font.Medium }
                                    width: parent.width; elide: Text.ElideRight
                                }
                                Text {
                                    text: modelData.dist + "  ·  " + modelData.mpg + "  ·  " + modelData.dur
                                    color: "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 11 }
                                }
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "›"
                                color: "#3A3A3C"
                                font { pixelSize: 18 }
                            }
                        }
                    }

                    Text {
                        text: "GPX logs saved on ignition-off  —  TODO: wire to trip logger"
                        color: "#3A3A3C"
                        font { family: "Roboto"; pixelSize: 9 }
                    }
                }
            }

        } // cardCol Column
    } // Flickable
}
