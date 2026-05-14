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
            font { pixelSize: 96; weight: 900 }
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
                    font { family: "Roboto"; pixelSize: 30; weight: 700 }
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
                font { family: "Roboto"; pixelSize: 26; weight: 700 }
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
        font { pixelSize: 28; weight: 300; letterSpacing: 6 }
    }

    // ── Top-right speed badge + over-limit alert pill ───────────────────────
    // Threshold defaults to 5 mph over posted limit (configurable via
    // SettingsService.speedAlertThreshold). The badge itself already turns
    // red at any value over the limit (SpeedWidget logic) — the pill is the
    // additional escalation when the driver is clearly speeding.
    Row {
        id: speedRow
        anchors { top: parent.top; right: parent.right; topMargin: 40; rightMargin: 16 }
        spacing: 10

        // Warning pill — animates in from the right of the speed widget.
        // Sits left of SpeedWidget so the speed numerals always anchor to the
        // top-right corner regardless of pill visibility.
        Rectangle {
            id: speedAlertPill

            property int threshold: (typeof SettingsService !== "undefined")
                                        ? SettingsService.speedAlertThreshold
                                        : 5
            property bool over: StatusBridge.speedLimit > 0
                                && StatusBridge.speed > (StatusBridge.speedLimit + threshold)

            width: over ? alertText.implicitWidth + 24 : 0
            height: 36
            radius: 18
            color: "#FF3B30"
            border { color: Qt.rgba(1, 1, 1, 0.20); width: 1 }
            visible: width > 0
            clip: true

            Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

            // Subtle pulse while the alert is active
            SequentialAnimation on opacity {
                running: speedAlertPill.over
                loops: Animation.Infinite
                NumberAnimation { to: 0.65; duration: 600; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.00; duration: 600; easing.type: Easing.InOutSine }
            }

            Row {
                anchors.centerIn: parent
                spacing: 6
                Text {
                    text: "⚠"
                    color: "#FFFFFF"
                    font { pixelSize: 16 }
                }
                Text {
                    id: alertText
                    text: "SPEED"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 12; weight: 700; letterSpacing: 2 }
                }
            }
        }

        SpeedWidget {
            id: speedBadge
            speed: StatusBridge.speed
            limit: StatusBridge.speedLimit > 0 ? StatusBridge.speedLimit : 45
        }
    }

    // ── Lane guidance — appears above bottom strip when within 0.5mi of turn
    //    Lane data comes from NavigationService.laneInfo (currently stubbed by
    //    maneuver direction; Phase 3 wires Valhalla maneuver["lanes"] JSON).
    LaneGuidance {
        id: laneGuidance
        anchors {
            bottom: bottomStrip.top; bottomMargin: 10
            horizontalCenter: parent.horizontalCenter
        }
        // Width is driven by the inner pill; give it a generous canvas so the
        // pill auto-sizes against the visible row of lane arrows.
        width: 600
        lanes: NavigationService.laneInfo
        show: StatusBridge.navActive && StatusBridge.approachingTurn
    }

    // ── Junction view — slides in from right edge for complex interchanges
    //    Heuristic: maneuver text mentions ramp / fork / exit / highway.
    //    Visible during the approach window; auto-clears after the turn.
    JunctionView {
        id: junctionView
        anchors { top: parent.top; topMargin: 56 }
        // Active when approaching, route is live, and the maneuver looks
        // interchange-y. The maneuver text is lower-cased once and reused.
        property string mLower: StatusBridge.nextManeuver.toLowerCase()
        property bool   complex: mLower.indexOf("ramp") >= 0
                              || mLower.indexOf("fork") >= 0
                              || mLower.indexOf("exit") >= 0
                              || mLower.indexOf("highway") >= 0
        show: StatusBridge.navActive && StatusBridge.approachingTurn && complex
        preferredArm: mLower.indexOf("left") >= 0 ? "left" : "right"
        label: mLower.indexOf("exit") >= 0 ? "EXIT"
             : mLower.indexOf("ramp") >= 0 ? "RAMP"
             : mLower.indexOf("fork") >= 0 ? "FORK"
             :                                "JUNCTION"
    }

    // ── Corner AVM badge — manual activation tap target ─────────────────────
    // The production system arms AVM when gear=R AND the AVM steering-wheel
    // button is held. Until that CAN wiring lands, this badge lets the
    // mockup driver toggle the overlay so the scaffold can be reviewed.
    Rectangle {
        id: avmBadge
        anchors { bottom: bottomStrip.top; left: parent.left; bottomMargin: 10; leftMargin: 16 }
        width: 56; height: 36; radius: 12
        color: StatusBridge.avmActive ? "#0A84FF"
                                       : Qt.rgba(0.0667, 0.0667, 0.0706, 0.88)
        border { color: Qt.rgba(1, 1, 1, 0.18); width: 1 }
        visible: !StatusBridge.avmActive   // hide once active — overlay has its own close
        opacity: avmBadgeMouse.pressed ? 0.7 : 1.0
        Behavior on color { ColorAnimation { duration: 180 } }

        Text {
            anchors.centerIn: parent
            text: "AVM"
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 12; weight: 700; letterSpacing: 2 }
        }

        MouseArea {
            id: avmBadgeMouse
            anchors.fill: parent
            onClicked: StatusBridge.setAvmActive(true)
        }
    }

    // ── Reverse-gear sonar strip ────────────────────────────────────────────
    // Thin overlay at the bottom of the nav map when the car is in reverse
    // and the full AVM overlay is NOT taking over. Gives the driver an
    // at-a-glance parking-sensor read without occluding the map.
    Rectangle {
        id: reverseSonar
        anchors {
            bottom: bottomStrip.top; left: parent.left; right: parent.right
            bottomMargin: 0
        }
        height: 14
        color: Qt.rgba(0, 0, 0, 0.65)
        visible: StatusBridge.reverseActive && !StatusBridge.avmActive
        opacity: visible ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 200 } }

        // Mock distance — animated so the colour ramp is visible in the demo.
        // Real sensor data wires from VehicleService (parking-sensor CAN PID).
        property real mockDist: 0.30
        Timer {
            running: reverseSonar.visible
            interval: 700
            repeat: true
            onTriggered: {
                const jitter = (Math.random() - 0.5) * 0.18
                reverseSonar.mockDist = Math.max(0.05, Math.min(0.95,
                                          reverseSonar.mockDist + jitter))
            }
        }

        Rectangle {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 12 }
            width: parent.width - 24
            height: 6; radius: 3
            color: Qt.rgba(1, 1, 1, 0.10)

            Rectangle {
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                width: parent.width * reverseSonar.mockDist
                height: parent.height; radius: parent.radius
                color: reverseSonar.mockDist > 0.70 ? "#FF3B30"
                     : reverseSonar.mockDist > 0.40 ? "#FFCC00"
                     :                                "#34C759"
                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            }
        }
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
                    font { family: "Roboto"; pixelSize: 22; weight: 600 }
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
                    font { family: "Roboto"; pixelSize: 22; weight: 600 }
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
                    font { family: "Roboto"; pixelSize: 15; weight: 500 }
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
                font { family: "Roboto"; pixelSize: 15; weight: 600 }
            }
        }
    }

    // ── AVM overlay — full-screen 4-camera composite ───────────────────────
    //    z:90 sits above the map, turn card, lane row, and junction view but
    //    below the incoming-call overlay (z:100, defined in Main.qml). Per
    //    the system contract this and RearCameraView (z:80, also in Main.qml)
    //    are mutually exclusive — the rear-cam Loader is keyed off
    //    StatusBridge.reverseActive while the AVM is keyed off
    //    StatusBridge.avmActive, so the lower-screen Vehicle tab and the
    //    corner badge above are the only paths that arm this scaffold.
    AvmOverlay {
        id: avmOverlay
        anchors.fill: parent
        z: 90
        visible: StatusBridge.avmActive
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

    // ── Sub-view stack: DestinationSearch + RoutePreview ────────────────────
    // 0 = none (idle map). 1 = DestinationSearch. 2 = RoutePreview.
    property int subView: 0
    property string pendingDestName: ""
    property string pendingDestAddr: ""
    property real   pendingDestLat: 0.0
    property real   pendingDestLon: 0.0

    // Open destination search — called by external triggers (back-button long-hold,
    // upper-screen tap on idle, voice command "Find …", etc.)
    function openDestinationSearch() { subView = 1 }

    DestinationSearch {
        anchors.fill: parent
        z: 60
        visible: subView === 1
        onClosed: subView = 0
        onDestinationChosen: function(name, addr, lat, lon) {
            pendingDestName = name
            pendingDestAddr = addr
            pendingDestLat  = lat
            pendingDestLon  = lon
            subView = 2
            if (typeof NavigationService !== "undefined" && NavigationService.previewRoute)
                NavigationService.previewRoute(lat, lon)
        }
    }

    RoutePreview {
        anchors.fill: parent
        z: 60
        visible: subView === 2
        destName: pendingDestName
        destAddr: pendingDestAddr
        destLat:  pendingDestLat
        destLon:  pendingDestLon
        onCancelled: subView = 1
        onRouteStarted: subView = 0
    }

    function handleBack() {
        if (subView === 2)      subView = 1
        else if (subView === 1) subView = 0
        else                    openDestinationSearch()
    }
    function handleHome() {
        subView = 0
    }

    // Reverse camera handled by RearCameraView loaded from Main.qml (z:80).
    // No overlay needed here — the camera Loader covers the full upper screen.
}
