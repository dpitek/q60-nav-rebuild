// DestinationSearch — upper-screen destination entry
// Full-screen sub-view pushed on top of NavigationView's map.
// Search box + categories + recents. Results from SearchService when available,
// otherwise mock-derived for demo. Joystick navigable; back-button pops.
import QtQuick
import QtQuick.Controls

Item {
    id: root
    anchors.fill: parent

    signal closed()                            // back button or X
    signal destinationChosen(string name, string address, real lat, real lon)

    property string query: ""

    Rectangle { anchors.fill: parent; color: "#0A0A0A"; opacity: 0.96 }

    // ── Top bar ─────────────────────────────────────────────────────────────
    Rectangle {
        id: topBar
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 56
        color: "#000000"

        Row {
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            spacing: 10

            // Back arrow
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 40; height: 40; radius: 20
                color: "#1C1C1E"
                Text { anchors.centerIn: parent; text: "‹"; color: "#FFFFFF"; font { pixelSize: 24 } }
                MouseArea { anchors.fill: parent; onClicked: root.closed() }
            }

            // Search input
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 60; height: 40
                radius: 20
                color: "#1C1C1E"
                border { color: searchField.activeFocus ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.1); width: 1 }
                Behavior on border.color { ColorAnimation { duration: 150 } }

                Row {
                    anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                    spacing: 8
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "⌕"; color: "#8E8E93"; font { pixelSize: 18 }
                    }
                    TextField {
                        id: searchField
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 40
                        color: "#FFFFFF"
                        selectionColor: "#0A84FF"
                        font { family: "Roboto"; pixelSize: 15 }
                        placeholderText: "Search address, place, or category…"
                        placeholderTextColor: "#8E8E93"
                        background: Item {}
                        focus: true
                        onTextChanged: {
                            root.query = text
                            if (text.length >= 2 && typeof SearchService !== "undefined")
                                SearchService.search(text)
                        }
                    }
                }
            }
        }
    }

    // ── Body ────────────────────────────────────────────────────────────────
    Flickable {
        anchors { top: topBar.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        contentHeight: bodyCol.implicitHeight + 24
        clip: true

        Column {
            id: bodyCol
            width: parent.width
            anchors.margins: 12
            spacing: 12

            // ── Category chips (idle / query empty) ─────────────────────────
            Item {
                visible: root.query.length === 0
                width: parent.width; height: chipCol.implicitHeight

                Column {
                    id: chipCol
                    width: parent.width
                    spacing: 10

                    Text {
                        text: "CATEGORIES"; leftPadding: 16
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 11; weight: 500; letterSpacing: 1.2 }
                    }

                    Grid {
                        anchors.horizontalCenter: parent.horizontalCenter
                        columns: 4; spacing: 10

                        Repeater {
                            model: [
                                { label: "Gas",    icon: "⛽", q: "gas station" },
                                { label: "Food",   icon: "🍴", q: "restaurant" },
                                { label: "Coffee", icon: "☕", q: "coffee" },
                                { label: "Park",   icon: "🅿",  q: "parking" },
                                { label: "Charge", icon: "⚡", q: "charging station" },
                                { label: "Hotel",  icon: "🏨", q: "hotel" },
                                { label: "Shop",   icon: "🛒", q: "shopping" },
                                { label: "ATM",    icon: "💳", q: "atm" }
                            ]
                            delegate: Rectangle {
                                width: 180; height: 70; radius: 12
                                color: "#1C1C1E"
                                border { color: Qt.rgba(1, 1, 1, 0.07); width: 1 }
                                Column {
                                    anchors.centerIn: parent; spacing: 4
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.icon; font { pixelSize: 22 } }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.label; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 13; weight: 500 } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: searchField.text = modelData.q
                                }
                            }
                        }
                    }

                    Text {
                        text: "RECENT"; leftPadding: 16
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 11; weight: 500; letterSpacing: 1.2 }
                    }

                    Repeater {
                        model: [
                            { name: "Home",   addr: "123 Kildaire Farm Rd, Cary",       lat: 35.788, lon: -78.781 },
                            { name: "Work",   addr: "4001 E Chapel Hill Nelson, Durham", lat: 35.973, lon: -78.918 },
                            { name: "Target", addr: "1205 Walnut St, Cary",             lat: 35.769, lon: -78.798 }
                        ]
                        delegate: Rectangle {
                            width: parent.width - 24
                            anchors.horizontalCenter: parent.horizontalCenter
                            height: 56; radius: 12
                            color: "#1C1C1E"
                            border { color: Qt.rgba(1, 1, 1, 0.07); width: 1 }
                            Row {
                                anchors { fill: parent; margins: 12 }
                                spacing: 12
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "📍"; font { pixelSize: 18 } }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 40
                                    Text { text: modelData.name; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 14; weight: 500 } }
                                    Text {
                                        text: modelData.addr; color: "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 11 }
                                        width: parent.width; elide: Text.ElideRight
                                    }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.destinationChosen(modelData.name, modelData.addr, modelData.lat, modelData.lon)
                            }
                        }
                    }
                }
            }

            // ── Results (query length >= 2) ─────────────────────────────────
            Column {
                visible: root.query.length >= 2
                width: parent.width
                spacing: 8

                Text {
                    text: "RESULTS"; leftPadding: 16
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11; weight: 500; letterSpacing: 1.2 }
                }

                Repeater {
                    // When SearchService is wired, model is SearchService.results
                    // For now: derive mock results from query so the UI is exercised.
                    model: typeof SearchService !== "undefined" && SearchService.results
                            ? SearchService.results
                            : [
                                { name: root.query + " — Cary, NC",         addr: "1 Main St, Cary, NC",       lat: 35.79, lon: -78.78 },
                                { name: root.query + " Center",             addr: "500 Crossroads Blvd, Cary", lat: 35.77, lon: -78.78 },
                                { name: root.query + " Park",               addr: "200 Evans Rd, Cary",        lat: 35.76, lon: -78.79 },
                                { name: root.query + " Plaza",              addr: "100 Chatham St, Cary",      lat: 35.78, lon: -78.78 }
                            ]
                    delegate: Rectangle {
                        width: parent.width - 24
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: 60; radius: 12
                        color: "#1C1C1E"
                        border { color: Qt.rgba(1, 1, 1, 0.07); width: 1 }
                        Row {
                            anchors { fill: parent; margins: 12 }
                            spacing: 12
                            Text { anchors.verticalCenter: parent.verticalCenter; text: "🔍"; font { pixelSize: 18 } }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 40
                                Text {
                                    text: modelData.name; color: "#FFFFFF"
                                    font { family: "Roboto"; pixelSize: 14; weight: 500 }
                                    width: parent.width; elide: Text.ElideRight
                                }
                                Text {
                                    text: modelData.addr; color: "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 11 }
                                    width: parent.width; elide: Text.ElideRight
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.destinationChosen(modelData.name, modelData.addr,
                                                              modelData.lat || 0, modelData.lon || 0)
                        }
                    }
                }
            }
        }
    }
}
