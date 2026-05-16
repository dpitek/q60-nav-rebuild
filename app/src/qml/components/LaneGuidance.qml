// LaneGuidance — row of lane arrows shown above the bottom strip when within
// 0.5 mi of an upcoming turn. Inactive lanes render grey; active/preferred
// lanes render in the brand blue (#0A84FF). The lane set is fed by
// NavigationService.laneInfo (currently stubbed — Phase 3 will wire to
// Valhalla maneuver["lanes"] JSON).
//
// Caller is expected to bind `lanes` to NavigationService.laneInfo and `show`
// to a NavigationView-level proximity condition. The component fades in/out
// on `show`; no internal visibility logic.
import QtQuick 2.15

Item {
    id: root

    property var  lanes: []          // QVariantList from NavigationService
    property bool show:  false

    // Always sized for layout; opacity hides it when not shown
    height: 56
    opacity: show && lanes.length > 0 ? 1.0 : 0.0
    visible: opacity > 0.0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutSine } }

    // Pill background — translucent dark, matches turn-card / cruise-bubble palette
    Rectangle {
        id: pill
        anchors.centerIn: parent
        width: laneRow.width + 24
        height: 48
        radius: 14
        color: Qt.rgba(0.0667, 0.0667, 0.0706, 0.92)
        border { color: Qt.rgba(1, 1, 1, 0.10); width: 1 }

        Row {
            id: laneRow
            anchors.centerIn: parent
            spacing: 8

            Repeater {
                model: root.lanes
                delegate: Item {
                    width: 40; height: 40

                    property bool active: modelData.active === true
                    property string dir:  modelData.direction || "straight"

                    // Lane tile background — subtle highlight when active
                    Rectangle {
                        anchors.fill: parent
                        radius: 8
                        color: active ? Qt.rgba(0.0392, 0.5176, 1.0, 0.18)
                                      : Qt.rgba(1, 1, 1, 0.04)
                        border {
                            color: active ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.12)
                            width: active ? 1.5 : 1
                        }
                    }

                    // Stylized arrow glyph rendered as Canvas — keeps the
                    // component self-contained, no SVG dep, and dirt-cheap
                    // on Mesa swrast.
                    Canvas {
                        anchors.fill: parent
                        anchors.margins: 6

                        property color strokeColor: active ? "#0A84FF" : "#6E6E72"

                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.reset()
                            ctx.strokeStyle = strokeColor
                            ctx.fillStyle   = strokeColor
                            ctx.lineWidth   = 3
                            ctx.lineCap     = "round"
                            ctx.lineJoin    = "round"

                            const w = width, h = height
                            const cx = w / 2, cy = h / 2

                            // Shaft start point (bottom center) → tip varies by dir
                            let tipX = cx, tipY = 2
                            let bendX = cx, bendY = cy

                            if (dir.indexOf("slight_left") >= 0) {
                                tipX = 4;       tipY = 6;  bendX = cx; bendY = cy
                            } else if (dir.indexOf("slight_right") >= 0) {
                                tipX = w - 4;   tipY = 6;  bendX = cx; bendY = cy
                            } else if (dir.indexOf("left") >= 0) {
                                tipX = 2;       tipY = cy; bendX = cx; bendY = cy
                            } else if (dir.indexOf("right") >= 0) {
                                tipX = w - 2;   tipY = cy; bendX = cx; bendY = cy
                            } else {
                                tipX = cx;      tipY = 2;  bendX = cx; bendY = cy
                            }

                            // Shaft
                            ctx.beginPath()
                            ctx.moveTo(cx, h - 2)
                            ctx.lineTo(bendX, bendY)
                            ctx.lineTo(tipX, tipY)
                            ctx.stroke()

                            // Arrowhead (small triangle at tip)
                            const ah = 6
                            ctx.beginPath()
                            if (tipY < bendY) {
                                ctx.moveTo(tipX, tipY)
                                ctx.lineTo(tipX - ah/2, tipY + ah)
                                ctx.lineTo(tipX + ah/2, tipY + ah)
                            } else if (tipX < bendX) {
                                ctx.moveTo(tipX, tipY)
                                ctx.lineTo(tipX + ah, tipY - ah/2)
                                ctx.lineTo(tipX + ah, tipY + ah/2)
                            } else {
                                ctx.moveTo(tipX, tipY)
                                ctx.lineTo(tipX - ah, tipY - ah/2)
                                ctx.lineTo(tipX - ah, tipY + ah/2)
                            }
                            ctx.closePath()
                            ctx.fill()
                        }

                        Component.onCompleted: requestPaint()
                        onStrokeColorChanged: requestPaint()
                    }
                }
            }
        }
    }
}
