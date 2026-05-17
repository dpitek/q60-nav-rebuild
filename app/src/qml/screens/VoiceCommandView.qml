// VoiceCommandView.qml — Bottom sheet overlay for voice command UI
// 240px from bottom, semi-transparent, auto-dismisses after 8s
import QtQuick 2.15

Item {
    id: root
    anchors.fill: parent

    signal dismissed()

    // ── Auto-dismiss timer ──────────────────────────────────────────────────
    Timer {
        id: autoDismiss
        interval: 8000
        repeat: false
        running: true
        onTriggered: root.dismissed()
    }

    // ── Tap outside to dismiss ──────────────────────────────────────────────
    MouseArea {
        anchors { top: parent.top; bottom: sheet.top; left: parent.left; right: parent.right }
        onClicked: root.dismissed()
    }

    // ── Bottom sheet ─────────────────────────────────────────────────────────
    Rectangle {
        id: sheet
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 240
        color: Qt.rgba(0, 0, 0, 0.88)
        radius: 20

        // Top border only (flat bottom flush to screen edge)
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1
            color: Qt.rgba(1, 1, 1, 0.15)
        }

        // Drag handle
        Rectangle {
            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 10 }
            width: 36; height: 4; radius: 2
            color: Qt.rgba(1, 1, 1, 0.3)
        }

        Column {
            anchors {
                horizontalCenter: parent.horizontalCenter
                verticalCenter: parent.verticalCenter
                verticalCenterOffset: 10
            }
            spacing: 24

            // Microphone icon
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 56; height: 56; radius: 28
                color: "#0A84FF"

                Text {
                    anchors.centerIn: parent
                    text: "🎤"
                    font.pixelSize: 24
                }
            }

            // "Listening..." label
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Listening…"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 22; weight: 300 }
            }

            // 3 pulsing bars
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8

                Repeater {
                    model: 3

                    Rectangle {
                        id: bar
                        width: 6
                        height: 32
                        radius: 3
                        color: "#0A84FF"
                        anchors.verticalCenter: parent ? parent.verticalCenter : undefined

                        property real phase: index * 0.33

                        SequentialAnimation on height {
                            loops: Animation.Infinite
                            running: true
                            PauseAnimation { duration: bar.phase * 400 }
                            NumberAnimation { to: 8;  duration: 250; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 36; duration: 250; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 20; duration: 200; easing.type: Easing.InOutSine }
                        }
                    }
                }
            }
        }

        // Swipe-down to dismiss
        MouseArea {
            anchors.fill: parent
            property real startY: 0
            onPressed: startY = mouseY
            onReleased: {
                if (mouseY - startY > 40)
                    root.dismissed()
            }
        }
    }

    // Slide-in entrance animation
    NumberAnimation {
        target: sheet
        property: "anchors.bottomMargin"
        from: -240
        to: 0
        duration: 200
        easing.type: Easing.OutCubic
        running: true
    }
}
