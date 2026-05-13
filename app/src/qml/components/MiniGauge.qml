// MiniGauge.qml — small Canvas-based arc + needle + numeric readout.
// Designed for the VR30 Track sub-tab tile grid (7 cells, ~190×88 each).
// No fancy shaders — Mesa swrast renders plain 2D paths cleanly.
import QtQuick 6.6

Item {
    id: root

    property string label: ""
    property double value: 0.0
    property double minValue: 0.0
    property double maxValue: 100.0
    property string units: ""
    property int    decimals: 0
    property color  arcColor: "#0A84FF"
    property color  needleColor: "#FFFFFF"
    property color  trackColor: "#2C2C2E"
    property bool   warning: false   // tint red when out of safe band

    implicitWidth: 92
    implicitHeight: 86

    Canvas {
        id: arcCanvas
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 4 }
        height: 46

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            var cx = width / 2
            var cy = height - 4
            var r  = Math.min(width / 2 - 4, height - 8)
            // Sweep from 135° to 405° (270° span across top half)
            var startA = Math.PI * 0.75
            var endA   = Math.PI * 2.25

            // Background track
            ctx.beginPath()
            ctx.arc(cx, cy, r, startA, endA, false)
            ctx.strokeStyle = root.trackColor
            ctx.lineWidth = 4
            ctx.lineCap = "round"
            ctx.stroke()

            // Foreground value arc
            var pct = (root.value - root.minValue) / (root.maxValue - root.minValue)
            pct = Math.max(0, Math.min(1, pct))
            var valA = startA + pct * (endA - startA)
            ctx.beginPath()
            ctx.arc(cx, cy, r, startA, valA, false)
            ctx.strokeStyle = root.warning ? "#FF453A" : root.arcColor
            ctx.lineWidth = 4
            ctx.lineCap = "round"
            ctx.stroke()

            // Needle
            ctx.beginPath()
            ctx.moveTo(cx, cy)
            ctx.lineTo(cx + Math.cos(valA) * (r - 2),
                       cy + Math.sin(valA) * (r - 2))
            ctx.strokeStyle = root.needleColor
            ctx.lineWidth = 1.5
            ctx.stroke()

            // Center hub
            ctx.beginPath()
            ctx.arc(cx, cy, 2, 0, Math.PI * 2)
            ctx.fillStyle = root.needleColor
            ctx.fill()
        }

        Connections {
            target: root
            function onValueChanged() { arcCanvas.requestPaint() }
            function onArcColorChanged() { arcCanvas.requestPaint() }
            function onWarningChanged() { arcCanvas.requestPaint() }
        }
        Component.onCompleted: requestPaint()
    }

    Text {
        id: valueText
        anchors { top: arcCanvas.bottom; horizontalCenter: parent.horizontalCenter; topMargin: 2 }
        text: root.value.toFixed(root.decimals) + (root.units.length > 0 ? " " + root.units : "")
        color: root.warning ? "#FF453A" : "#FFFFFF"
        font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
    }

    Text {
        anchors { top: valueText.bottom; horizontalCenter: parent.horizontalCenter; topMargin: 1 }
        text: root.label
        color: "#8E8E93"
        font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
    }
}
