// RoutePreview — upper-screen route summary before start
// Full-screen sub-view shown after a destination is picked. Summarises
// total time/distance, route options (Fastest/Shortest/Eco), avoid toggles,
// and offers Start / Cancel. Joystick navigable; back-button pops.
import QtQuick
import QtQuick.Controls

Item {
    id: root
    anchors.fill: parent

    signal cancelled()
    signal routeStarted()

    property string destName: ""
    property string destAddr: ""
    property real destLat: 0.0
    property real destLon: 0.0

    // Route summary props — populated by NavigationService when available
    property real distMi: typeof NavigationService !== "undefined" && NavigationService.previewDistance
                          ? NavigationService.previewDistance : 18.4
    property int  durMin: typeof NavigationService !== "undefined" && NavigationService.previewDuration
                          ? NavigationService.previewDuration : 27
    property string etaStr: typeof NavigationService !== "undefined" && NavigationService.previewEta
                            ? NavigationService.previewEta : "—"

    property int routeType: 0   // 0=Fastest 1=Shortest 2=Eco
    property bool avoidTolls: false
    property bool avoidHighways: false

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

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 40; height: 40; radius: 20
                color: "#1C1C1E"
                Text { anchors.centerIn: parent; text: "‹"; color: "#FFFFFF"; font { pixelSize: 24 } }
                MouseArea { anchors.fill: parent; onClicked: root.cancelled() }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Text { text: root.destName; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 17; weight: 600 } }
                Text { text: root.destAddr; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 12 } }
            }
        }
    }

    // ── Body ────────────────────────────────────────────────────────────────
    Column {
        anchors { top: topBar.bottom; left: parent.left; right: parent.right; topMargin: 16; leftMargin: 24; rightMargin: 24 }
        spacing: 16

        // ── Summary card ────────────────────────────────────────────────────
        Rectangle {
            width: parent.width; height: 110
            radius: 16
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.1); width: 1 }

            Row {
                anchors.fill: parent

                Item {
                    width: parent.width / 3; height: parent.height
                    Column {
                        anchors.centerIn: parent; spacing: 4
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: Math.floor(root.durMin / 60) > 0
                                  ? Math.floor(root.durMin / 60) + "h " + (root.durMin % 60) + "m"
                                  : root.durMin + "m"
                            color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 28; weight: 700 }
                        }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Travel"; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 11 } }
                    }
                }
                Rectangle { width: 1; height: 60; color: Qt.rgba(1, 1, 1, 0.12); anchors.verticalCenter: parent.verticalCenter }
                Item {
                    width: parent.width / 3; height: parent.height
                    Column {
                        anchors.centerIn: parent; spacing: 4
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.distMi.toFixed(1); color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 28; weight: 700 } }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "mi"; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 11 } }
                    }
                }
                Rectangle { width: 1; height: 60; color: Qt.rgba(1, 1, 1, 0.12); anchors.verticalCenter: parent.verticalCenter }
                Item {
                    width: parent.width / 3; height: parent.height
                    Column {
                        anchors.centerIn: parent; spacing: 4
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.etaStr; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 24; weight: 600 } }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Arrive"; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 11 } }
                    }
                }
            }
        }

        // ── Route type pills ────────────────────────────────────────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 10

            Repeater {
                model: ["Fastest", "Shortest", "Eco"]
                delegate: Rectangle {
                    height: 40; width: pillLabel.implicitWidth + 28
                    radius: 20
                    color: root.routeType === index ? "#0A84FF" : "#2C2C2E"
                    Text {
                        id: pillLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: root.routeType === index ? "#FFFFFF" : "#8E8E93"
                        font { family: "Roboto"; pixelSize: 14; weight: 500 }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.routeType = index
                            if (typeof NavigationService !== "undefined" && NavigationService.requestReroute)
                                NavigationService.requestReroute(index)
                        }
                    }
                }
            }
        }

        // ── Avoid toggles ───────────────────────────────────────────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 28

            Repeater {
                model: [
                    { label: "Avoid Tolls",    prop: "avoidTolls" },
                    { label: "Avoid Highways", prop: "avoidHighways" }
                ]
                delegate: Row {
                    spacing: 10
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label; color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 14 }
                    }
                    Rectangle {
                        width: 44; height: 26; radius: 13
                        color: (index === 0 ? root.avoidTolls : root.avoidHighways) ? "#0A84FF" : "#3A3A3C"
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Rectangle {
                            width: 22; height: 22; radius: 11
                            anchors.verticalCenter: parent.verticalCenter
                            x: (index === 0 ? root.avoidTolls : root.avoidHighways) ? 20 : 2
                            color: "#FFFFFF"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (index === 0) root.avoidTolls = !root.avoidTolls
                                else             root.avoidHighways = !root.avoidHighways
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Bottom action bar ───────────────────────────────────────────────────
    Row {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right; bottomMargin: 20; leftMargin: 24; rightMargin: 24 }
        spacing: 16

        Rectangle {
            width: (parent.width - 16) / 3
            height: 56
            radius: 28
            color: "transparent"
            border { color: "#8E8E93"; width: 1 }
            Text { anchors.centerIn: parent; text: "Cancel"; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 15; weight: 500 } }
            MouseArea { anchors.fill: parent; onClicked: root.cancelled() }
        }

        Rectangle {
            width: (parent.width - 16) * 2 / 3
            height: 56
            radius: 28
            color: "#0A84FF"
            Row {
                anchors.centerIn: parent
                spacing: 10
                Text { anchors.verticalCenter: parent.verticalCenter; text: "▶"; color: "#FFFFFF"; font { pixelSize: 16 } }
                Text { anchors.verticalCenter: parent.verticalCenter; text: "Start Navigation"; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 17; weight: 600 } }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (typeof NavigationService !== "undefined" && NavigationService.startRoute)
                        NavigationService.startRoute(root.destName)
                    root.routeStarted()
                }
            }
        }
    }
}
