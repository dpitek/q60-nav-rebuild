// GPad.qml — circular G-meter with live dot, trail, and peak-hold rings.
// Reads VehicleService.lateralG / longitudinalG directly; caller sizes via width/height.
// Trail is rebuilt from a rolling 30-sample (~3s @ 10Hz) ring buffer.
import QtQuick

Item {
    id: root

    property double maxG: 1.5     // outer ring = 1.5g — covers spirited street driving
    property color  dotColor: "#0A84FF"
    property color  trailColor: "#0A84FF"
    property color  latPeakColor: "#FF9F0A"
    property color  lonPeakColor: "#30D158"

    implicitWidth: 76
    implicitHeight: 76

    property var _trail: []   // array of [lat, lon] pairs, most recent at end

    Timer {
        interval: 100   // 10Hz trail sample
        running: true
        repeat: true
        onTriggered: {
            var t = root._trail.slice()
            t.push([VehicleService.lateralG, VehicleService.longitudinalG])
            if (t.length > 30) t.shift()
            root._trail = t
            canvas.requestPaint()
        }
    }

    Connections {
        target: VehicleService
        function onGMeterChanged() { canvas.requestPaint() }
    }

    Canvas {
        id: canvas
        anchors.fill: parent

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var cx = width / 2
            var cy = height / 2
            var r  = Math.min(width, height) / 2 - 2

            // Background ring
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, Math.PI * 2)
            ctx.fillStyle = "#1C1C1E"
            ctx.fill()
            ctx.strokeStyle = "#2C2C2E"
            ctx.lineWidth = 1
            ctx.stroke()

            // Inner ring at 0.5g
            ctx.beginPath()
            ctx.arc(cx, cy, r * (0.5 / root.maxG), 0, Math.PI * 2)
            ctx.strokeStyle = "#2C2C2E"
            ctx.lineWidth = 0.5
            ctx.stroke()

            // Crosshairs
            ctx.beginPath()
            ctx.moveTo(cx - r, cy); ctx.lineTo(cx + r, cy)
            ctx.moveTo(cx, cy - r); ctx.lineTo(cx, cy + r)
            ctx.strokeStyle = "#2C2C2E"
            ctx.lineWidth = 0.5
            ctx.stroke()

            // Helper: g-value → canvas coordinate
            function gToPx(latG, lonG) {
                var px = cx + (latG / root.maxG) * r
                // longitudinal: positive = accel forward → dot moves UP (canvas Y- )
                var py = cy - (lonG / root.maxG) * r
                return [px, py]
            }

            // Trail (oldest fade → newest solid)
            var trail = root._trail
            for (var i = 0; i < trail.length; i++) {
                var p = gToPx(trail[i][0], trail[i][1])
                var alpha = (i + 1) / trail.length * 0.6
                ctx.beginPath()
                ctx.arc(p[0], p[1], 1.5, 0, Math.PI * 2)
                ctx.fillStyle = Qt.rgba(0.04, 0.52, 1, alpha)
                ctx.fill()
            }

            // Peak rings (one for lat max, one for lon max)
            var latPeak = Math.abs(VehicleService.peakLateralG)
            if (latPeak > 0.05) {
                var lr = (latPeak / root.maxG) * r
                ctx.beginPath()
                ctx.arc(cx, cy, lr, 0, Math.PI * 2)
                ctx.strokeStyle = root.latPeakColor
                ctx.lineWidth = 1
                ctx.stroke()
            }
            var lonPeak = Math.abs(VehicleService.peakLongitudinalG)
            if (lonPeak > 0.05) {
                var pr = (lonPeak / root.maxG) * r
                ctx.beginPath()
                ctx.arc(cx, cy, pr, 0, Math.PI * 2)
                ctx.strokeStyle = root.lonPeakColor
                ctx.lineWidth = 1
                ctx.setLineDash ? ctx.setLineDash([2, 2]) : null
                ctx.stroke()
                ctx.setLineDash ? ctx.setLineDash([]) : null
            }

            // Current G dot
            var cur = gToPx(VehicleService.lateralG, VehicleService.longitudinalG)
            ctx.beginPath()
            ctx.arc(cur[0], cur[1], 3.5, 0, Math.PI * 2)
            ctx.fillStyle = root.dotColor
            ctx.fill()
            ctx.strokeStyle = "#FFFFFF"
            ctx.lineWidth = 1
            ctx.stroke()
        }
        Component.onCompleted: requestPaint()
    }
}
