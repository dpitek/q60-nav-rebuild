// NavigationView — Upper 8" screen
// Phase 3: MapLibre GL Native renders into mapCanvas via QQuickItem
// Until Phase 3 lands: vector-style placeholder with live HUD overlays
import QtQuick 6.6
import QtQuick.Controls 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    // ── Map canvas ────────────────────────────────────────────────────────
    // TODO Phase 3: replace with MapLibre QQuickItem
    // MapLibreMap { id: mapCanvas; anchors.fill: parent; ... }
    Rectangle {
        id: mapCanvas
        anchors.fill: parent
        color: "#0f1a12"   // Dark map green

        // Simulated road grid — placeholder until MapLibre
        Canvas {
            anchors.fill: parent
            opacity: 0.07
            onPaint: {
                var ctx = getContext("2d")
                ctx.strokeStyle = "#3adf8a"
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
            color: "#1a2a1a"
            font { pixelSize: 96; weight: Font.Black }
            opacity: 0.15
        }
    }

    // ── Top HUD strip ─────────────────────────────────────────────────────
    Rectangle {
        id: topHud
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 88

        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: "#f0080d12" }
            GradientStop { position: 1.0; color: "#00080d12" }
        }

        // Turn arrow + distance + street
        Row {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 16 }
            spacing: 14
            visible: StatusBridge.navActive

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
                arrowColor: StatusBridge.approachingTurn ? "#ff8c00" : "#00d4ff"
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                Text {
                    text: StatusBridge.nextDistance < 0.1
                          ? "Now"
                          : (StatusBridge.nextDistance < 1.0
                             ? Math.round(StatusBridge.nextDistance * 5280) + " ft"
                             : StatusBridge.nextDistance.toFixed(1) + " mi")
                    color: StatusBridge.approachingTurn ? "#ff8c00" : "#f0f0f0"
                    font { pixelSize: 30; weight: Font.Bold }
                }
                Text {
                    text: StatusBridge.nextStreet
                    color: "#aaa"
                    font { pixelSize: 14; weight: Font.Medium }
                    width: 340; elide: Text.ElideRight
                }
            }
        }

        // No route state
        Text {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 20 }
            visible: !StatusBridge.navActive
            text: "Q60 NAV"
            color: "#1e3a2a"
            font { pixelSize: 22; weight: Font.Light; letterSpacing: 4 }
        }

        // ETA block (top right)
        Column {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 20 }
            spacing: 2
            visible: StatusBridge.navActive

            Text {
                anchors.right: parent.right
                text: StatusBridge.eta
                color: "#f0f0f0"
                font { pixelSize: 24; weight: Font.Bold }
            }
            Text {
                anchors.right: parent.right
                text: "ARRIVE"
                color: "#555"
                font { pixelSize: 10; capitalization: Font.AllUppercase }
            }
        }

        // Clock (top right, no route)
        Text {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 20 }
            visible: !StatusBridge.navActive
            text: StatusBridge.timeString
            color: "#2a4a3a"
            font { pixelSize: 22; weight: Font.Light }
        }
    }

    // ── Approaching turn banner ───────────────────────────────────────────
    Rectangle {
        anchors { top: topHud.bottom; left: parent.left; right: parent.right }
        height: 3
        color: StatusBridge.approachingTurn ? "#ff8c00" : "transparent"
        Behavior on color { ColorAnimation { duration: 200 } }

        SequentialAnimation on opacity {
            running: StatusBridge.approachingTurn
            loops: Animation.Infinite
            NumberAnimation { to: 0.3; duration: 700 }
            NumberAnimation { to: 1.0; duration: 700 }
        }
        opacity: StatusBridge.approachingTurn ? 1.0 : 0.0
    }

    // ── Bottom HUD strip ──────────────────────────────────────────────────
    Rectangle {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 80

        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: "#00080d12" }
            GradientStop { position: 1.0; color: "#f0080d12" }
        }

        // Speed widget (bottom left)
        SpeedWidget {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 16 }
            speed: StatusBridge.speed
            limit: StatusBridge.speedLimit > 0 ? StatusBridge.speedLimit : 45
        }

        // GPS lock indicator
        Row {
            anchors.centerIn: parent
            spacing: 6
            visible: !StatusBridge.gpsLock

            Rectangle {
                width: 8; height: 8; radius: 4
                anchors.verticalCenter: parent.verticalCenter
                color: "#ff8c00"
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.2; duration: 800 }
                    NumberAnimation { to: 1.0; duration: 800 }
                }
            }
            Text { text: "Acquiring GPS"; color: "#888"; font.pixelSize: 12 }
        }

        // Outside temp + rerouting (bottom right)
        Column {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 16 }
            spacing: 4

            Text {
                anchors.right: parent.right
                text: VehicleService.outsideTemp.toFixed(0) + "°F"
                color: "#666"
                font.pixelSize: 13
            }

            Row {
                anchors.right: parent.right
                spacing: 6
                visible: NavigationService.rerouting

                Text { text: "⟳"; color: "#ff8c00"; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter }
                Text { text: "Recalculating"; color: "#ff8c00"; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
            }
        }
    }

    // ── Reverse camera overlay ────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        visible: StatusBridge.reverseActive
        color: "#cc000000"

        Column {
            anchors.centerIn: parent
            spacing: 16
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "R"
                color: "#ff4444"
                font { pixelSize: 96; weight: Font.Black }
                opacity: 0.8
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "REVERSE"
                color: "#ff4444"
                font { pixelSize: 14; capitalization: Font.AllUppercase; letterSpacing: 4 }
            }
        }
    }

    // ── Rerouting overlay ─────────────────────────────────────────────────
    Rectangle {
        anchors { horizontalCenter: parent.horizontalCenter; top: topHud.bottom; topMargin: 8 }
        width: 200; height: 36; radius: 18
        visible: NavigationService.rerouting
        color: "#cc1a1000"
        border { color: "#4a3800"; width: 1 }

        Row {
            anchors.centerIn: parent; spacing: 8
            Text { text: "⟳"; color: "#ff8c00"; font.pixelSize: 16; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Recalculating…"; color: "#ff8c00"; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
        }
    }
}
