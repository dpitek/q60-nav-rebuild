// TurnArrow.qml — directional maneuver icon
// Rendered as Canvas path; no image assets required
import QtQuick 6.6

Item {
    id: root
    width: 64; height: 64

    // 0=straight 1=right 2=left 3=slight-right 4=slight-left
    // 5=sharp-right 6=sharp-left 7=u-turn 8=arrive
    property int direction: 0
    property color arrowColor: "#00d4ff"

    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.strokeStyle = root.arrowColor
            ctx.fillStyle   = root.arrowColor
            ctx.lineWidth   = 4
            ctx.lineCap     = "round"
            ctx.lineJoin    = "round"

            var cx = width / 2
            var cy = height / 2

            ctx.beginPath()
            switch (root.direction) {
            case 0: // Straight up
                ctx.moveTo(cx, height - 10)
                ctx.lineTo(cx, 10)
                ctx.moveTo(cx, 10)
                ctx.lineTo(cx - 12, 28)
                ctx.moveTo(cx, 10)
                ctx.lineTo(cx + 12, 28)
                break
            case 1: // Turn right
                ctx.moveTo(10, cy)
                ctx.lineTo(width - 10, cy)
                ctx.moveTo(width - 10, cy)
                ctx.lineTo(width - 28, cy - 12)
                ctx.moveTo(width - 10, cy)
                ctx.lineTo(width - 28, cy + 12)
                break
            case 2: // Turn left
                ctx.moveTo(width - 10, cy)
                ctx.lineTo(10, cy)
                ctx.moveTo(10, cy)
                ctx.lineTo(28, cy - 12)
                ctx.moveTo(10, cy)
                ctx.lineTo(28, cy + 12)
                break
            case 7: // U-turn
                ctx.arc(cx, cy, 20, Math.PI * 0.5, Math.PI * 1.5, false)
                ctx.moveTo(cx, cy - 20)
                ctx.lineTo(cx + 10, cy - 8)
                ctx.moveTo(cx, cy - 20)
                ctx.lineTo(cx - 2, cy - 8)
                break
            case 8: // Arrive (circle)
                ctx.arc(cx, cy, 18, 0, Math.PI * 2)
                ctx.stroke()
                ctx.beginPath()
                ctx.arc(cx, cy, 8, 0, Math.PI * 2)
                ctx.fill()
                return
            default:
                ctx.moveTo(cx, height - 10)
                ctx.lineTo(cx, 10)
                break
            }
            ctx.stroke()
        }
    }

    onDirectionChanged: canvas.requestPaint()
    onArrowColorChanged: canvas.requestPaint()
}
