// NavigationView — Upper 8" screen
// Apple CarPlay aesthetic redesign
// All StatusBridge / NavigationService / VehicleService bindings preserved exactly.
import QtQuick 6.6
import QtQuick.Controls 6.6
import QtPositioning 6.6
import "../components"

import Q60Nav 1.0 as Q60Nav

Item {
    id: root
    anchors.fill: parent

    // ── Map canvas ─────────────────────────────────────────────────────────
    Loader {
        id: mapLoader
        anchors.fill: parent
        property bool mapReady: false
        sourceComponent: mapLibreComponent
    }

    Component {
        id: mapLibreComponent

        Q60Nav.MapLibreMap {
            id: mapLibreMap
            anchors.fill: parent
            center: QtPositioning.coordinate(35.5, -79.0)
            zoom:   12.0
            style:  "file:///opt/nav/style/q60-dark.json"

            onReadyChanged: {
                if (ready) {
                    mapLoader.mapReady = true
                    console.log("[NavView] MapLibre ready")
                }
            }

            Connections {
                target: StatusBridge
                function onPositionChanged() {
                    if (StatusBridge.navActive && ready)
                        mapLibreMap.flyTo(StatusBridge.latitude,
                                          StatusBridge.longitude)
                }
            }
        }
    }

    // ── Fallback placeholder ────────────────────────────────────────────────
    Rectangle {
        id: mapPlaceholder
        anchors.fill: parent
        color: "#0A0A0A"
        visible: mapLoader.status !== Loader.Ready || !mapLoader.mapReady

        Canvas {
            anchors.fill: parent
            opacity: 0.04
            onPaint: {
                var ctx = getContext("2d")
                ctx.strokeStyle = "#FFFFFF"
                ctx.lineWidth = 1
                for (var x = 0; x < width; x += 60) {
                    ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, height); ctx.stroke()
                }
                for (var y = 0; y < height; y += 60) {
                    ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke()
                }
            }
        }

        Text {
            anchors.centerIn: parent
            text: "MAP"
            color: "#1C1C1E"
            font { pixelSize: 96; weight: Font.Black }
        }
    }

    // ── Status bar (32px) ──────────────────────────────────────────────────
    StatusBar {
        anchors { top: parent.top; left: parent.left; right: parent.right }
    }

    // ── Top-left turn card ─────────────────────────────────────────────────
    Rectangle {
        id: turnCard
        anchors { top: parent.top; left: parent.left; topMargin: 40; leftMargin: 16 }
        width: 280; height: 88; radius: 16
        color: Qt.rgba(0.1098, 0.1098, 0.1176, 0.92)
        border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }
        visible: StatusBridge.navActive

        Behavior on opacity { NumberAnimation { duration: 200 } }

        Row {
            anchors { fill: parent; margins: 14 }
            spacing: 14

            TurnArrow {
                anchors.verticalCenter: parent.verticalCenter
                width: 48; height: 48
                direction: {
                    var m = StatusBridge.nextManeuver.toLowerCase()
                    if (m.indexOf("right") >= 0 && m.indexOf("sharp") >= 0) return 5
                    if (m.indexOf("left")  >= 0 && m.indexOf("sharp") >= 0) return 6
                    if (m.indexOf("right") >= 0 && m.indexOf("slight") >= 0) return 3
                    if (m.indexOf("left")  >= 0 && m.indexOf("slight") >= 0) return 4
                    if (m.indexOf("right") >= 0) return 1
                    if (m.indexOf("left")  >= 0) return 2
                    if (m.indexOf("u-turn") >= 0) return 7
                    if (m.indexOf("arriv") >= 0)  return 8
                    return 0
                }
                arrowColor: StatusBridge.approachingTurn ? "#FF9F0A" : "#0A84FF"
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                width: parent.width - 62

                Text {
                    text: StatusBridge.nextDistance < 0.1
                          ? "Now"
                          : (StatusBridge.nextDistance < 1.0
                             ? Math.round(StatusBridge.nextDistance * 5280) + " ft"
                             : StatusBridge.nextDistance.toFixed(1) + " mi")
                    color: StatusBridge.approachingTurn ? "#FF9F0A" : "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 30; weight: Font.Bold }
                }
                Text {
                    text: StatusBridge.nextStreet
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 13 }
                    width: parent.width
                    elide: Text.ElideRight
                }
            }
        }
    }

    // Approaching turn accent bar under turn card
    Rectangle {
        anchors { top: turnCard.bottom; left: turnCard.left; right: turnCard.right; topMargin: 2 }
        height: 3; radius: 1.5
        color: "#FF9F0A"
        opacity: StatusBridge.approachingTurn ? 1.0 : 0.0
        visible: StatusBridge.navActive

        Behavior on opacity { NumberAnimation { duration: 200 } }

        SequentialAnimation on opacity {
            running: StatusBridge.approachingTurn
            loops: Animation.Infinite
            NumberAnimation { to: 0.3; duration: 700 }
            NumberAnimation { to: 1.0; duration: 700 }
        }
    }

    // ── Cruise control bubble — left side, mirrors SpeedWidget on right ────────
    Rectangle {
        id: cruiseWidget
        anchors {
            top: turnCard.bottom; left: parent.left
            topMargin: 14; leftMargin: 16
        }
        width: 80; height: 68; radius: 16
        color: Qt.rgba(0.1098, 0.1098, 0.1176, 0.92)
        border { color: "#0A84FF"; width: 1 }
        visible: VehicleService.cruiseActive

        Behavior on opacity { NumberAnimation { duration: 200 } }

        Column {
            anchors.centerIn: parent
            spacing: 2

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: VehicleService.cruiseSpeed > 0 ? VehicleService.cruiseSpeed.toString() : "—"
                color: "#0A84FF"
                font { family: "Roboto"; pixelSize: 26; weight: Font.Bold }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "CRUISE"
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
            }
        }

        // Subtle blue pulse ring when active
        SequentialAnimation on border.width {
            running: VehicleService.cruiseActive
            loops: Animation.Infinite
            NumberAnimation { to: 2; duration: 1200; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 1200; easing.type: Easing.InOutSine }
        }
    }

    // Idle state label (no route)
    Text {
        anchors { top: parent.top; left: parent.left; topMargin: 48; leftMargin: 24 }
        visible: !StatusBridge.navActive
        text: "Q60"
        color: Qt.rgba(1, 1, 1, 0.06)
        font { pixelSize: 28; weight: Font.Light; letterSpacing: 6 }
    }

    // ── Top-right speed badge ───────────────────────────────────────────────
    SpeedWidget {
        anchors { top: parent.top; right: parent.right; topMargin: 40; rightMargin: 16 }
        speed: StatusBridge.speed
        limit: StatusBridge.speedLimit > 0 ? StatusBridge.speedLimit : 45
    }

    // ── Bottom info strip ───────────────────────────────────────────────────
    Rectangle {
        id: bottomStrip
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 72
        color: Qt.rgba(0, 0, 0, 0.88)
        visible: StatusBridge.navActive

        // Top separator
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1
            color: Qt.rgba(1, 1, 1, 0.12)
        }

        Row {
            anchors { fill: parent; leftMargin: 20; rightMargin: 20 }
            spacing: 0

            // ETA
            Column {
                width: parent.width / 3
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    text: StatusBridge.eta.length > 0 ? StatusBridge.eta : "--:--"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 22; weight: Font.SemiBold }
                }
                Text {
                    text: "ETA"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1 }
                }
            }

            // Separator
            Rectangle {
                width: 1; height: 36; color: Qt.rgba(1, 1, 1, 0.15)
                anchors.verticalCenter: parent.verticalCenter
            }

            // Distance remaining
            Column {
                width: parent.width / 3
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                leftPadding: 16

                Text {
                    text: NavigationService.remaining.toFixed(1) + " mi"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 22; weight: Font.SemiBold }
                }
                Text {
                    text: "Remaining"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11 }
                }
            }

            // Separator
            Rectangle {
                width: 1; height: 36; color: Qt.rgba(1, 1, 1, 0.15)
                anchors.verticalCenter: parent.verticalCenter
            }

            // Current street
            Column {
                width: parent.width / 3
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                leftPadding: 16

                Text {
                    text: StatusBridge.nextStreet.length > 0 ? StatusBridge.nextStreet : "On Route"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 15; weight: Font.Medium }
                    width: parent.width - 16
                    elide: Text.ElideRight
                }
                Text {
                    text: "Current Street"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11 }
                }
            }
        }
    }

    // ── GPS acquiring indicator ─────────────────────────────────────────────
    Row {
        anchors { bottom: bottomStrip.top; horizontalCenter: parent.horizontalCenter; bottomMargin: 12 }
        spacing: 8
        visible: !StatusBridge.gpsLock

        Rectangle {
            width: 8; height: 8; radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: "#FF9F0A"

            SequentialAnimation on opacity {
                loops: Animation.Infinite
                NumberAnimation { to: 0.2; duration: 800 }
                NumberAnimation { to: 1.0; duration: 800 }
            }
        }
        Text {
            text: "Acquiring GPS"
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }
        }
    }

    // ── Rerouting banner ────────────────────────────────────────────────────
    Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 32 }
        height: 40
        color: Qt.rgba(1, 0.6235, 0.0392, 0.92)
        visible: NavigationService.rerouting
        z: 10

        Row {
            anchors.centerIn: parent
            spacing: 8
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "⟳"
                color: "#000000"
                font { pixelSize: 18 }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Recalculating route…"
                color: "#000000"
                font { family: "Roboto"; pixelSize: 15; weight: Font.SemiBold }
            }
        }
    }

    // ── Commander joystick + button wiring ─────────────────────────────────
    // Signals from VehicleService (AV-CAN 0x3F6 / 0x4CE — UNVERIFIED IDs).
    // panMap() and joystickSelect() are stubs pending MapLibre EGL completion.
    // When MapLibre is live, replace mapLoader.item calls with mapLibreMap
    // directly once the Loader has promoted it to a reachable id.
    Connections {
        target: VehicleService

        function onJoystickMoved(x, y) {
            // Map joystick tick to map pan — 40px per tick
            // TODO: wire to mapLoader.item.panMap(x * panDelta, y * panDelta)
            //       once MapLibre EGL pan API is confirmed
            const panDelta = 40
            if (mapLoader.item && typeof mapLoader.item.panMap === "function")
                mapLoader.item.panMap(x * panDelta, y * panDelta)
            // else: silently drop — map not ready yet
        }

        function onJoystickClicked() {
            // Select / confirm on map
            // TODO: wire to mapLoader.item.joystickSelect() once API is confirmed
            if (mapLoader.item && typeof mapLoader.item.joystickSelect === "function")
                mapLoader.item.joystickSelect()
        }

        function onButtonPressed(button) {
            if (button === "back")
                Qt.callLater(() => root.handleBack())
            else if (button === "home")
                Qt.callLater(() => root.handleHome())
            else if (button === "map") {
                // TODO: toggle map/turn-by-turn view when secondary view exists
            }
        }
    }

    // ── Commander back / home stubs ─────────────────────────────────────────
    // Sub-view stack (destination search, route preview, etc.) is not yet
    // implemented. Replace these with push/pop logic when those views land.
    function handleBack() {
        console.log("[NavView] Back — no sub-view to dismiss")
    }
    function handleHome() {
        console.log("[NavView] Home — returning to idle map")
    }

    // Reverse camera handled by RearCameraView loaded from Main.qml (z:80).
    // No overlay needed here — the camera Loader covers the full upper screen.
}
