// AvmOverlay — Around View Monitor scaffold for the upper screen.
//
// Simulates the factory 4-camera composite: a center top-down view of the
// vehicle, flanked by front / rear / left / right perimeter feeds. Real V4L2
// streams wire later (see BACKLOG.md). For now each quadrant is a stylized
// grey placeholder with a label so the layout, sonar arcs, and activation
// path can be validated visually.
//
// Sonar arcs at the front and rear of the center pane animate against mock
// distance values (Timer-driven 1Hz) — gradient green → yellow → red. On the
// real car these will be driven by parking-sensor CAN frames.
//
// Activation is driven externally via StatusBridge.avmActive. The caller is
// expected to render this with `visible: StatusBridge.avmActive` and an
// appropriate z value (z:90 per Main.qml conventions).
import QtQuick 6.6

Item {
    id: root
    anchors.fill: parent

    // ── Mock sonar distances ────────────────────────────────────────────────
    // Each sensor: 0.0 (clear) … 1.0 (about to hit). The Timer below cycles
    // values so the demo shows the colour gradient. Real CAN wiring lives in
    // VehicleService and will publish these via a future signal.
    property real frontDist: 0.30
    property real rearDist:  0.45

    opacity: visible ? 1.0 : 0.0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutSine } }

    Timer {
        running: root.visible
        interval: 900
        repeat: true
        onTriggered: {
            // Random walk so the arc colours visibly change during demos
            const jitter = (Math.random() - 0.5) * 0.18
            root.frontDist = Math.max(0.05, Math.min(0.95, root.frontDist + jitter))
            root.rearDist  = Math.max(0.05, Math.min(0.95, root.rearDist  + (Math.random() - 0.5) * 0.18))
        }
    }

    // Distance → arc colour ramp
    function distColor(d) {
        if (d > 0.70) return "#FF3B30"   // red
        if (d > 0.40) return "#FFCC00"   // yellow
        return "#34C759"                 // green
    }

    // ── Background blackout ─────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#000000"
    }

    // ── Header bar ──────────────────────────────────────────────────────────
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 40
        color: Qt.rgba(0.0667, 0.0667, 0.0706, 0.92)

        Text {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 16 }
            text: "AROUND VIEW MONITOR"
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 13; weight: 700; letterSpacing: 3 }
        }

        // Close affordance — tapping it clears avmActive on the bridge
        Rectangle {
            id: closeBtn
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 12 }
            width: 64; height: 28; radius: 14
            color: closeArea.pressed ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.08)

            Text {
                anchors.centerIn: parent
                text: "CLOSE"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 11; weight: 700; letterSpacing: 2 }
            }

            MouseArea {
                id: closeArea
                anchors.fill: parent
                onClicked: StatusBridge.setAvmActive(false)
            }
        }
    }

    // ── 4-quadrant grid ─────────────────────────────────────────────────────
    // Center: top-down stylized car + sonar arcs
    // Cardinal cells: front / rear / left / right placeholder feeds
    Grid {
        id: grid
        anchors {
            top: header.bottom; bottom: parent.bottom
            left: parent.left; right: parent.right
            margins: 8
        }
        columns: 3
        rows: 3
        spacing: 6

        property real cellW: (width  - 2 * spacing) / 3
        property real cellH: (height - 2 * spacing) / 3

        // 1: top-left  (empty corner)
        Rectangle { width: grid.cellW; height: grid.cellH; color: "transparent" }

        // 2: front camera placeholder
        Rectangle {
            width: grid.cellW; height: grid.cellH; radius: 8
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.10); width: 1 }
            Column {
                anchors.centerIn: parent
                spacing: 4
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "FRONT"; color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 12; weight: 700; letterSpacing: 2 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "no feed"; color: "#6E6E72"
                    font { family: "Roboto"; pixelSize: 10 }
                }
            }
        }

        // 3: top-right (empty corner)
        Rectangle { width: grid.cellW; height: grid.cellH; color: "transparent" }

        // 4: left camera
        Rectangle {
            width: grid.cellW; height: grid.cellH; radius: 8
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.10); width: 1 }
            Column {
                anchors.centerIn: parent
                spacing: 4
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "LEFT"; color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 12; weight: 700; letterSpacing: 2 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "no feed"; color: "#6E6E72"
                    font { family: "Roboto"; pixelSize: 10 }
                }
            }
        }

        // 5: CENTER — top-down car + sonar arcs
        Rectangle {
            id: topDown
            width: grid.cellW; height: grid.cellH; radius: 8
            color: "#0A0A0A"
            border { color: "#0A84FF"; width: 1 }

            Canvas {
                id: carCanvas
                anchors.fill: parent
                anchors.margins: 8

                property real fd: root.frontDist
                property real rd: root.rearDist
                property color fc: root.distColor(fd)
                property color rc: root.distColor(rd)

                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    const w = width, h = height
                    const cx = w / 2, cy = h / 2

                    // ── Stylized top-down car body ────────────────────────
                    const cw = w * 0.34
                    const ch = h * 0.58
                    ctx.fillStyle   = "#2C2C2E"
                    ctx.strokeStyle = "#0A84FF"
                    ctx.lineWidth = 2
                    ctx.beginPath()
                    // Rounded rectangle
                    const r = 10
                    const x0 = cx - cw / 2, y0 = cy - ch / 2
                    const x1 = cx + cw / 2, y1 = cy + ch / 2
                    ctx.moveTo(x0 + r, y0)
                    ctx.lineTo(x1 - r, y0); ctx.quadraticCurveTo(x1, y0, x1, y0 + r)
                    ctx.lineTo(x1, y1 - r); ctx.quadraticCurveTo(x1, y1, x1 - r, y1)
                    ctx.lineTo(x0 + r, y1); ctx.quadraticCurveTo(x0, y1, x0, y1 - r)
                    ctx.lineTo(x0, y0 + r); ctx.quadraticCurveTo(x0, y0, x0 + r, y0)
                    ctx.closePath()
                    ctx.fill()
                    ctx.stroke()

                    // Windshield hint — small bar near front (top)
                    ctx.fillStyle = "#0A84FF"
                    ctx.globalAlpha = 0.4
                    ctx.fillRect(x0 + 6, y0 + 8, cw - 12, 6)
                    ctx.globalAlpha = 1.0

                    // ── Front sonar arcs (above car) ──────────────────────
                    ctx.strokeStyle = fc
                    ctx.lineWidth   = 3
                    for (let i = 0; i < 3; i++) {
                        const radius = ch / 2 + 10 + i * 9
                        ctx.globalAlpha = 1.0 - i * 0.25
                        ctx.beginPath()
                        ctx.arc(cx, cy, radius, Math.PI * 1.20, Math.PI * 1.80, false)
                        ctx.stroke()
                    }
                    ctx.globalAlpha = 1.0

                    // ── Rear sonar arcs (below car) ───────────────────────
                    ctx.strokeStyle = rc
                    for (let j = 0; j < 3; j++) {
                        const radius2 = ch / 2 + 10 + j * 9
                        ctx.globalAlpha = 1.0 - j * 0.25
                        ctx.beginPath()
                        ctx.arc(cx, cy, radius2, Math.PI * 0.20, Math.PI * 0.80, false)
                        ctx.stroke()
                    }
                    ctx.globalAlpha = 1.0
                }

                Component.onCompleted: requestPaint()
                onFdChanged: requestPaint()
                onRdChanged: requestPaint()
                onFcChanged: requestPaint()
                onRcChanged: requestPaint()
            }

            // Distance numeric readouts — corners of the top-down pane
            Text {
                anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 4 }
                text: (root.frontDist * 100).toFixed(0) + " cm"
                color: root.distColor(root.frontDist)
                font { family: "Roboto"; pixelSize: 10; weight: 700 }
            }
            Text {
                anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 4 }
                text: (root.rearDist * 100).toFixed(0) + " cm"
                color: root.distColor(root.rearDist)
                font { family: "Roboto"; pixelSize: 10; weight: 700 }
            }
        }

        // 6: right camera
        Rectangle {
            width: grid.cellW; height: grid.cellH; radius: 8
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.10); width: 1 }
            Column {
                anchors.centerIn: parent
                spacing: 4
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "RIGHT"; color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 12; weight: 700; letterSpacing: 2 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "no feed"; color: "#6E6E72"
                    font { family: "Roboto"; pixelSize: 10 }
                }
            }
        }

        // 7: bottom-left (empty corner)
        Rectangle { width: grid.cellW; height: grid.cellH; color: "transparent" }

        // 8: rear camera
        Rectangle {
            width: grid.cellW; height: grid.cellH; radius: 8
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.10); width: 1 }
            Column {
                anchors.centerIn: parent
                spacing: 4
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "REAR"; color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 12; weight: 700; letterSpacing: 2 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "no feed"; color: "#6E6E72"
                    font { family: "Roboto"; pixelSize: 10 }
                }
            }
        }

        // 9: bottom-right (empty corner)
        Rectangle { width: grid.cellW; height: grid.cellH; color: "transparent" }
    }
}
