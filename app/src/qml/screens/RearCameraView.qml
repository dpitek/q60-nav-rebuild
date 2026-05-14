// RearCameraView — Upper 8" screen (800×480)
// Activated when vehicle is in reverse gear.
// Camera feed via QtMultimedia VideoOutput (Loader-guarded fallback for Mesa softpipe).
// Parking guidelines drawn on Canvas overlay; all UI chrome sits above via z-index.
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    width: 800
    height: 480

    // ── Background ──────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#000000"
    }

    // ── Camera feed (Loader-guarded — silently falls back if QtMultimedia absent) ──
    Loader {
        id: cameraLoader
        anchors.fill: parent
        z: 0

        // Try to load QtMultimedia dynamically; if the module or device is
        // unavailable the Loader will set status to Loader.Error and the
        // placeholder below will become visible automatically.
        source: "../components/CameraFeed.qml"

        // Fallback: show placeholder whenever the Loader is not in Ready state
        // (covers: module missing, /dev/video0 absent, permission denied, etc.)
        onStatusChanged: {
            if (status === Loader.Error)
                console.log("[RearCameraView] QtMultimedia unavailable — falling back to placeholder")
        }
    }

    // ── Camera placeholder (shown when Loader is not Ready) ────────────────
    Rectangle {
        id: cameraPlaceholder
        anchors.fill: parent
        color: "#0A0A0A"
        z: 1
        visible: cameraLoader.status !== Loader.Ready

        // Subtle grid — matches NavigationView map placeholder style
        Canvas {
            anchors.fill: parent
            opacity: 0.04
            onPaint: {
                var ctx = getContext("2d")
                ctx.strokeStyle = "#FFFFFF"
                ctx.lineWidth   = 1
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
            text: "REAR CAMERA"
            color: "#1C1C1E"
            font {
                family:       "Roboto"
                pixelSize:    48
                weight:       900
                capitalization: Font.AllUppercase
                letterSpacing:  8
            }
        }
    }

    // ── Parking guideline overlay ────────────────────────────────────────────
    // Trapezoid arcs (perspective): narrow at top (far), wide at bottom (close).
    // Three colour zones:
    //   Green  > 6 ft  — y-range: guideFarY   (top band)
    //   Yellow 3–6 ft  — y-range: guideMidY
    //   Red    < 3 ft  — y-range: guideCloseY (bottom band)
    //
    // Each zone is represented by a filled (semi-transparent) trapezoid region
    // plus a bold boundary arc along its far edge.
    Canvas {
        id: guideCanvas
        anchors.fill: parent
        z: 5

        // Layout constants — tweak to match real car geometry
        readonly property real cx:          width  / 2      // horizontal centre
        readonly property real baseY:       height          // bottom edge (bumper)
        readonly property real baseHalfW:   width * 0.44    // half-width at bumper (≈352px)
        readonly property real farY:        height * 0.30   // top of green zone (≈144px)
        readonly property real farHalfW:    width * 0.08    // half-width at far line (≈64px)
        readonly property real midY:        height * 0.55   // green/yellow boundary (≈264px)
        readonly property real midHalfW:    width * 0.24    // half-width at mid line (≈192px)
        readonly property real closeY:      height * 0.74   // yellow/red boundary  (≈355px)
        readonly property real closeHalfW:  width * 0.36    // half-width at close line (≈288px)

        // Interpolate half-width linearly between two zone boundary rows
        function hwAt(y, y0, hw0, y1, hw1) {
            var t = (y - y0) / (y1 - y0)
            return hw0 + t * (hw1 - hw0)
        }

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            // Helper: draw a filled trapezoid between two horizontal rows
            function trapFill(yTop, hwTop, yBot, hwBot, color, alpha) {
                ctx.beginPath()
                ctx.moveTo(cx - hwTop, yTop)
                ctx.lineTo(cx + hwTop, yTop)
                ctx.lineTo(cx + hwBot, yBot)
                ctx.lineTo(cx - hwBot, yBot)
                ctx.closePath()
                ctx.fillStyle = color
                ctx.globalAlpha = alpha
                ctx.fill()
                ctx.globalAlpha = 1.0
            }

            // Helper: draw a horizontal boundary line (top edge of each zone)
            function boundaryLine(y, hw, color, lineW) {
                ctx.beginPath()
                ctx.moveTo(cx - hw, y)
                ctx.lineTo(cx + hw, y)
                ctx.strokeStyle = color
                ctx.lineWidth   = lineW
                ctx.globalAlpha = 0.90
                ctx.stroke()
                ctx.globalAlpha = 1.0
            }

            // Helper: draw dashed side rails for a zone (left and right)
            function sideRails(yTop, hwTop, yBot, hwBot, color) {
                ctx.setLineDash([8, 6])
                ctx.lineWidth   = 2
                ctx.strokeStyle = color
                ctx.globalAlpha = 0.55

                ctx.beginPath()
                ctx.moveTo(cx - hwTop, yTop)
                ctx.lineTo(cx - hwBot, yBot)
                ctx.stroke()

                ctx.beginPath()
                ctx.moveTo(cx + hwTop, yTop)
                ctx.lineTo(cx + hwBot, yBot)
                ctx.stroke()

                ctx.setLineDash([])
                ctx.globalAlpha = 1.0
            }

            // ── Green zone (far > 6 ft) ─────────────────────────────────────
            trapFill(farY,   farHalfW,
                     midY,   midHalfW,
                     "#30D158", 0.12)
            sideRails(farY,  farHalfW,  midY, midHalfW,  "#30D158")
            boundaryLine(farY,  farHalfW,  "#30D158", 2.5)  // far boundary
            boundaryLine(midY,  midHalfW,  "#30D158", 2.0)  // zone floor

            // ── Yellow zone (3–6 ft) ───────────────────────────────────────
            trapFill(midY,   midHalfW,
                     closeY, closeHalfW,
                     "#FF9F0A", 0.13)
            sideRails(midY,  midHalfW,  closeY, closeHalfW, "#FF9F0A")
            boundaryLine(closeY, closeHalfW, "#FF9F0A", 2.0)  // zone floor

            // ── Red zone (< 3 ft) ──────────────────────────────────────────
            trapFill(closeY, closeHalfW,
                     baseY,  baseHalfW,
                     "#FF453A", 0.18)
            sideRails(closeY, closeHalfW, baseY, baseHalfW, "#FF453A")
            // No bottom boundary — extends to screen edge (bumper)

            // ── Centre dashed line (vanishing-point guide) ─────────────────
            ctx.setLineDash([10, 8])
            ctx.lineWidth   = 1.5
            ctx.strokeStyle = "#FFFFFF"
            ctx.globalAlpha = 0.25
            ctx.beginPath()
            ctx.moveTo(cx, farY)
            ctx.lineTo(cx, baseY)
            ctx.stroke()
            ctx.setLineDash([])
            ctx.globalAlpha = 1.0
        }
    }

    // ── Distance text markers (right edge, aligned to each guideline) ────────
    // 6 ft marker
    Text {
        x:      guideCanvas.cx + guideCanvas.midHalfW + 10
        y:      guideCanvas.midY - 9
        z:      6
        text:   "6 ft"
        color:  "#30D158"
        font {
            family:         "Roboto"
            pixelSize:      11
            weight:         500
            capitalization: Font.AllUppercase
            letterSpacing:  0.5
        }
    }

    // 3 ft marker
    Text {
        x:      guideCanvas.cx + guideCanvas.closeHalfW + 10
        y:      guideCanvas.closeY - 9
        z:      6
        text:   "3 ft"
        color:  "#FF9F0A"
        font {
            family:         "Roboto"
            pixelSize:      11
            weight:         500
            capitalization: Font.AllUppercase
            letterSpacing:  0.5
        }
    }

    // 1 ft marker — positioned 70% of the way between closeY and bottom
    Text {
        x:      guideCanvas.cx + guideCanvas.hwAt(guideCanvas.height * 0.905,
                    guideCanvas.closeY,  guideCanvas.closeHalfW,
                    guideCanvas.baseY,   guideCanvas.baseHalfW) + 10
        y:      guideCanvas.height * 0.905 - 9
        z:      6
        text:   "1 ft"
        color:  "#FF453A"
        font {
            family:         "Roboto"
            pixelSize:      11
            weight:         500
            capitalization: Font.AllUppercase
            letterSpacing:  0.5
        }
    }

    // ── "REVERSE" label — top centre ─────────────────────────────────────────
    Text {
        anchors {
            top:              parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin:        14
        }
        z:    10
        text: "REVERSE"
        color: Qt.rgba(1, 1, 1, 0.55)
        font {
            family:         "Roboto"
            pixelSize:      11
            weight:         500
            capitalization: Font.AllUppercase
            letterSpacing:  4
        }
    }

    // ── "R" badge — top-left ──────────────────────────────────────────────────
    Rectangle {
        id: rBadge
        anchors { top: parent.top; left: parent.left; topMargin: 10; leftMargin: 14 }
        width: 44; height: 44; radius: 12
        color:   Qt.rgba(0.0392, 0.5176, 1, 0.18)
        z:       10

        // Pulsing blue border
        border.color: "#0A84FF"
        border.width: 2

        SequentialAnimation on border.width {
            loops: Animation.Infinite
            NumberAnimation { to: 3;   duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.5; duration: 900; easing.type: Easing.InOutSine }
        }

        Text {
            anchors.centerIn: parent
            text:  "R"
            color: "#0A84FF"
            font {
                family:  "Roboto"
                pixelSize: 22
                weight:    700
            }
        }
    }

    // ── Reverse speed readout — driven by VehicleService.speed (CAN frame 0x280) ──
    // Active whenever reverse is engaged. Loader keeps this dormant when the
    // camera isn't shown.
    Loader {
        id: speedLoader
        anchors { top: rBadge.bottom; left: parent.left; topMargin: 8; leftMargin: 14 }
        z:    10
        active: typeof VehicleService !== "undefined"

        sourceComponent: Component {
            Column {
                spacing: 2

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:  VehicleService.speed.toFixed(1)
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 20; weight: 600 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:  "mph"
                    color: "#8E8E93"
                    font {
                        family:         "Roboto"
                        pixelSize:      10
                        capitalization: Font.AllUppercase
                        letterSpacing:  1
                    }
                }
            }
        }
    }

    // ── Pulsing blue border frame (full screen) ──────────────────────────────
    Rectangle {
        anchors.fill: parent
        color:        "transparent"
        border.color: "#0A84FF"
        border.width: 2
        z:            9

        SequentialAnimation on border.width {
            loops: Animation.Infinite
            NumberAnimation { to: 3;   duration: 1100; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.5; duration: 1100; easing.type: Easing.InOutSine }
        }

        SequentialAnimation on opacity {
            loops: Animation.Infinite
            NumberAnimation { to: 0.55; duration: 1100; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.90; duration: 1100; easing.type: Easing.InOutSine }
        }
    }
}
