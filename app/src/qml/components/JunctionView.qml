// JunctionView — modal-style overlay that slides in from the right edge when
// approaching a complex interchange (ramp / fork / highway exit). The visual
// is a stylized Y-fork with one arm highlighted in blue, matching the chosen
// direction. Phase 3 will replace the Canvas drawing with photo-real junction
// imagery decoded from Valhalla's sign/junction data.
//
// Caller binds `show` (true → slide in) and `preferredArm` ("left" / "right").
import QtQuick 2.15

Item {
    id: root

    property bool show: false
    property string preferredArm: "right"   // "left" or "right"
    property string label: "EXIT"           // Small banner text (e.g. "EXIT 12B")

    width: 280
    height: 360

    // Slide animation: hidden = parked off-screen to the right
    x: show ? (parent ? parent.width - width - 16 : 0)
            : (parent ? parent.width + 8 : 0)
    Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    opacity: show ? 1.0 : 0.0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 200 } }

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: Qt.rgba(0.0667, 0.0667, 0.0706, 0.96)
        border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }

        // Small label banner at the top
        Rectangle {
            id: banner
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 28
            radius: 18
            color: Qt.rgba(0.0392, 0.5176, 1.0, 0.20)

            // Mask the bottom corners to keep only the top rounded
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: parent.height / 2
                color: parent.color
            }

            Text {
                anchors.centerIn: parent
                text: root.label
                color: "#0A84FF"
                font { family: "Roboto"; pixelSize: 12; weight: 700; letterSpacing: 2; capitalization: Font.AllUppercase }
            }
        }

        // Y-fork canvas
        Canvas {
            id: forkCanvas
            anchors {
                top: banner.bottom; topMargin: 8
                left: parent.left; right: parent.right
                bottom: footnote.top
            }

            property string arm: root.preferredArm

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()

                const w = width, h = height
                const cx = w / 2

                // ── Road outline (grey) ────────────────────────────────────
                ctx.lineCap  = "round"
                ctx.lineJoin = "round"

                // Trunk
                ctx.strokeStyle = "#3A3A3C"
                ctx.lineWidth = 56

                ctx.beginPath()
                ctx.moveTo(cx, h - 8)
                ctx.lineTo(cx, h * 0.55)
                ctx.stroke()

                // Left arm
                ctx.beginPath()
                ctx.moveTo(cx, h * 0.55)
                ctx.lineTo(cx - w * 0.32, 24)
                ctx.stroke()

                // Right arm
                ctx.beginPath()
                ctx.moveTo(cx, h * 0.55)
                ctx.lineTo(cx + w * 0.32, 24)
                ctx.stroke()

                // ── Centerline dashes (white) ──────────────────────────────
                ctx.strokeStyle = "#FFFFFF"
                ctx.lineWidth = 2
                ctx.setLineDash([8, 10])

                ctx.beginPath()
                ctx.moveTo(cx, h - 8)
                ctx.lineTo(cx, h * 0.55)
                ctx.stroke()

                ctx.beginPath()
                ctx.moveTo(cx, h * 0.55)
                ctx.lineTo(cx - w * 0.32, 24)
                ctx.stroke()

                ctx.beginPath()
                ctx.moveTo(cx, h * 0.55)
                ctx.lineTo(cx + w * 0.32, 24)
                ctx.stroke()

                ctx.setLineDash([])

                // ── Preferred arm highlight (blue overlay) ─────────────────
                ctx.strokeStyle = "#0A84FF"
                ctx.lineWidth   = 14

                if (arm === "left") {
                    ctx.beginPath()
                    ctx.moveTo(cx - 4, h * 0.55)
                    ctx.lineTo(cx - w * 0.32, 24)
                    ctx.stroke()
                } else {
                    ctx.beginPath()
                    ctx.moveTo(cx + 4, h * 0.55)
                    ctx.lineTo(cx + w * 0.32, 24)
                    ctx.stroke()
                }

                // Arrow tip on the highlighted arm
                ctx.fillStyle = "#0A84FF"
                const tipX = (arm === "left") ? cx - w * 0.32 : cx + w * 0.32
                const tipY = 24
                const dx = (arm === "left") ? 1 : -1
                ctx.beginPath()
                ctx.moveTo(tipX, tipY - 10)
                ctx.lineTo(tipX + dx * 14, tipY + 6)
                ctx.lineTo(tipX, tipY + 14)
                ctx.closePath()
                ctx.fill()
            }

            Component.onCompleted: requestPaint()
            onArmChanged: requestPaint()
        }

        // Footnote — small directional hint text
        Text {
            id: footnote
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 14 }
            text: root.preferredArm === "left" ? "KEEP LEFT" : "KEEP RIGHT"
            color: "#0A84FF"
            font { family: "Roboto"; pixelSize: 17; weight: 700; letterSpacing: 2 }
        }
    }
}
