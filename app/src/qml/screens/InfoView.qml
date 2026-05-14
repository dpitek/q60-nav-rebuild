// InfoView — Lower screen Info tab
// Cards: Weather · Fuel Prices · Parking Location · Trip History
// Weather bound to WeatherService (OWM). Fuel bound to FuelService (EIA).
import QtQuick

Item {
    id: root
    anchors.fill: parent

    property bool hasParkingLocation: ParkingService.hasParkingRecord

    // ── Friendly "time ago" formatter for parking timestamp ─────────────────
    function timeAgo(epochMs) {
        if (!epochMs) return ""
        var diffSec = Math.floor((Date.now() - epochMs) / 1000)
        if (diffSec < 60)        return "just now"
        if (diffSec < 3600)      return Math.floor(diffSec / 60)   + " min ago"
        if (diffSec < 86400)     return Math.floor(diffSec / 3600) + " hr ago"
        return Math.floor(diffSec / 86400) + " d ago"
    }

    // ── Compact ISO → "Today 7:42 AM" / "MM/DD" formatter ───────────────────
    function tripWhen(iso) {
        if (!iso) return ""
        var d = new Date(iso)
        if (isNaN(d.getTime())) return iso
        var now = new Date()
        var sameDay = d.toDateString() === now.toDateString()
        var hh = d.getHours() % 12 || 12
        var mm = d.getMinutes().toString().padStart(2, "0")
        var ap = d.getHours() < 12 ? "AM" : "PM"
        if (sameDay) return "Today " + hh + ":" + mm + " " + ap
        return (d.getMonth() + 1) + "/" + d.getDate() + " " + hh + ":" + mm + " " + ap
    }

    // ── OWM icon code → emoji helper ─────────────────────────────────────────
    function owmEmoji(code) {
        if (!code) return "🌡"
        var c = code.substring(0, 2)
        if (c === "01") return code.endsWith("d") ? "☀" : "🌙"
        if (c === "02") return "⛅"
        if (c === "03" || c === "04") return "☁"
        if (c === "09") return "🌧"
        if (c === "10") return "🌦"
        if (c === "11") return "⛈"
        if (c === "13") return "🌨"
        if (c === "50") return "🌫"
        return "🌡"
    }

    // ── Temperature color helper ──────────────────────────────────────────────
    function tempColor(temp) {
        if (temp < 50) return "#5AC8FA"   // cold = blue
        if (temp > 80) return "#FF9F0A"   // hot = amber
        return "#FFFFFF"                   // comfortable = white
    }

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
            Rectangle {
                width: parent.width; height: 120
                radius: 16
                color: "#1C1C1E"
                border { color: Qt.rgba(1, 1, 1, 0.08); width: 1 }

                // Loading / no-data state
                Item {
                    anchors.fill: parent
                    visible: !WeatherService.available

                    Text {
                        anchors.centerIn: parent
                        text: "Weather unavailable — add OWM API key to config.json"
                        color: "#3A3A3C"
                        font { family: "Roboto"; pixelSize: 11 }
                        wrapMode: Text.WordWrap
                        width: parent.width - 24
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                Row {
                    anchors { fill: parent; margins: 14 }
                    spacing: 0
                    visible: WeatherService.available

                    // Left: current conditions
                    Column {
                        width: parent.width * 0.45
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Row {
                            spacing: 8

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: owmEmoji(WeatherService.iconCode)
                                font { pixelSize: 32 }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Math.round(WeatherService.temperature) + "°F"
                                color: tempColor(WeatherService.temperature)
                                font { family: "Roboto"; pixelSize: 36; weight: 700 }
                            }
                        }

                        Text {
                            text: WeatherService.condition
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 13 }
                            elide: Text.ElideRight
                            width: parent.width
                        }
                        Text {
                            text: WeatherService.city + "  •  " + WeatherService.lastUpdated
                            color: "#3A3A3C"
                            font { family: "Roboto"; pixelSize: 10 }
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }

                    // Right: forecast strip (up to 4 days from WeatherService.forecast)
                    Row {
                        width: parent.width * 0.55
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0

                        Repeater {
                            model: WeatherService.forecast.slice(0, 4)

                            delegate: Column {
                                width: parent.width / 4
                                spacing: 3
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    // modelData.day is "YYYY-MM-DD"; show 3-letter day name
                                    text: {
                                        var d = new Date(modelData.day + "T12:00:00")
                                        return d.toLocaleDateString(Qt.locale(), "ddd").toUpperCase().substring(0, 3)
                                    }
                                    color: "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 9; weight: 500; letterSpacing: 0.5 }
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: owmEmoji(modelData.icon)
                                    font { pixelSize: 16 }
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: Math.round(modelData.hi) + "°"
                                    color: modelData.hi > 80 ? "#FF9F0A" : "#FFFFFF"
                                    font { family: "Roboto"; pixelSize: 12; weight: 600 }
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: Math.round(modelData.lo) + "°"
                                    color: "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 11 }
                                }
                            }
                        }
                    }
                }
            }

            // ── Fuel Prices Card ─────────────────────────────────────────────
            // EIA weekly regional averages — not per-station
            Rectangle {
                width: parent.width; height: 110
                radius: 16
                color: "#1C1C1E"
                border { color: Qt.rgba(1, 1, 1, 0.08); width: 1 }

                Column {
                    anchors { fill: parent; margins: 12 }
                    spacing: 6

                    // Header row
                    Row {
                        width: parent.width
                        spacing: 0
                        Text {
                            text: "⛽  Regional Prices"
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 13; weight: 600 }
                        }
                        Item { width: parent.width - headerLeft.implicitWidth - regionLabel.implicitWidth; height: 1 }
                        Text {
                            id: headerLeft
                            width: 0  // hidden spacer trick — use anchors instead
                        }
                        Text {
                            id: regionLabel
                            text: FuelService.available ? FuelService.region + "  •  " + FuelService.lastUpdated : "EIA data"
                            color: "#3A3A3C"
                            font { family: "Roboto"; pixelSize: 9 }
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.children[0].verticalCenter
                        }
                    }

                    // Price rows
                    Repeater {
                        model: [
                            { label: "Regular",  price: FuelService.regularPrice,  grade: "reg" },
                            { label: "Premium",  price: FuelService.premiumPrice,  grade: "prem" },
                            { label: "Diesel",   price: FuelService.dieselPrice,   grade: "dsl" }
                        ]

                        delegate: Row {
                            width: parent.width
                            spacing: 0

                            Text {
                                width: parent.width * 0.30
                                text: modelData.label
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 12 }
                            }
                            Text {
                                width: parent.width * 0.35
                                text: FuelService.available
                                      ? "$" + modelData.price.toFixed(2) + " / gal"
                                      : "—"
                                color: modelData.grade === "reg" ? "#30D158" : "#8E8E93"
                                font { family: "Roboto"; pixelSize: 12;
                                       weight: modelData.grade === "reg" ? 600 : 400 }
                            }
                            // Trend arrow (only for regular)
                            Text {
                                visible: modelData.grade === "reg" && FuelService.available
                                text: FuelService.trend === "up"   ? "▲" :
                                      FuelService.trend === "down" ? "▼" : "—"
                                color: FuelService.trend === "up"   ? "#FF453A" :
                                       FuelService.trend === "down" ? "#30D158" : "#3A3A3C"
                                font { family: "Roboto"; pixelSize: 10 }
                                anchors.verticalCenter: parent.verticalCenter
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
                border { color: Qt.rgba(1, 1, 1, 0.08); width: 1 }

                Column {
                    anchors { fill: parent; margins: 12 }
                    spacing: 8

                    Text {
                        text: "🅿  Last Parked"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13; weight: 600 }
                    }

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
                                text: ParkingService.hasParkingRecord
                                      ? "Last parked  —  " + timeAgo(ParkingService.lastParkingTimestamp)
                                      : "No parking record"
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 13; weight: 500 }
                                width: parent.width; elide: Text.ElideRight
                            }
                            Text {
                                text: ParkingService.hasParkingRecord
                                      ? ParkingService.lastParkingLat.toFixed(5) + ", "
                                        + ParkingService.lastParkingLon.toFixed(5)
                                      : ""
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 11 }
                                width: parent.width; elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            height: 30; width: navBackLabel.implicitWidth + 18
                            radius: 15
                            color: "#0A84FF"
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                id: navBackLabel
                                anchors.centerIn: parent
                                text: "Navigate"
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 11; weight: 500 }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: ParkingService.navigateToCar()
                            }
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
                border { color: Qt.rgba(1, 1, 1, 0.08); width: 1 }

                Column {
                    anchors { fill: parent; margins: 12 }
                    spacing: 6

                    Text {
                        text: "🗺  Recent Trips"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13; weight: 600 }
                    }

                    Repeater {
                        model: TripLoggerService.recentTrips.slice(0, 10)

                        delegate: Row {
                            width: parent.width
                            spacing: 0

                            Column {
                                width: parent.width - 16
                                spacing: 1

                                Text {
                                    text: tripWhen(modelData.startTime)
                                    color: "#FFFFFF"
                                    font { family: "Roboto"; pixelSize: 12; weight: 500 }
                                    width: parent.width; elide: Text.ElideRight
                                }
                                Text {
                                    text: (modelData.distanceMi || 0).toFixed(1) + " mi  ·  "
                                          + ((modelData.avgMpg || 0).toFixed(1)) + " MPG  ·  "
                                          + Math.round((modelData.durationSec || 0) / 60) + " min"
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
                        text: TripLoggerService.recentTrips.length === 0
                              ? "No trips logged yet — drive with ignition cycling on/off to record."
                              : "GPX logs saved on ignition-off — last 10 trips shown."
                        color: "#3A3A3C"
                        font { family: "Roboto"; pixelSize: 9 }
                    }
                }
            }

        } // cardCol Column
    } // Flickable
}
