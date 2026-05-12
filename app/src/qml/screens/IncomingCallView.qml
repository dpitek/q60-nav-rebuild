// IncomingCallView.qml — Full-screen incoming call modal overlay
// Shown over upper or lower screen when an incoming call arrives
import QtQuick 6.6

Item {
    id: root
    anchors.fill: parent

    property string callerName:   ""
    property string callerNumber: ""

    signal answered()
    signal declined()

    // ── Dark scrim ──────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: 0.92
    }

    // ── Content ─────────────────────────────────────────────────────────────
    Column {
        anchors {
            horizontalCenter: parent.horizontalCenter
            verticalCenter: parent.verticalCenter
            verticalCenterOffset: -30
        }
        spacing: 16

        // Avatar circle with caller initials
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 80; height: 80; radius: 40
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1.5 }

            Text {
                anchors.centerIn: parent
                text: root.callerName.length > 0
                      ? root.callerName.charAt(0).toUpperCase()
                      : "?"
                color: "#0A84FF"
                font { family: "Roboto"; pixelSize: 32; weight: Font.Bold }
            }
        }

        // Pulsing "Incoming Call" label
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Incoming Call"
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }

            SequentialAnimation on opacity {
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 700 }
                NumberAnimation { to: 1.0; duration: 700 }
            }
        }

        // Caller name
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.callerName.length > 0 ? root.callerName : root.callerNumber
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 28; weight: Font.Bold }
            width: 320
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
        }

        // Caller number (only if we have a name)
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.callerNumber
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 17 }
            visible: root.callerName.length > 0 && root.callerNumber.length > 0
        }
    }

    // ── Action Buttons ───────────────────────────────────────────────────────
    Row {
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 44
        }
        spacing: 48

        // Decline
        Rectangle {
            width: 160; height: 56; radius: 28
            color: declineArea.pressed ? "#CC1A1A" : "#FF453A"

            Behavior on color { ColorAnimation { duration: 100 } }

            Row {
                anchors.centerIn: parent
                spacing: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✆"
                    color: "#FFFFFF"
                    font { pixelSize: 18; }
                    rotation: 135
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Decline"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 17; weight: Font.SemiBold }
                }
            }

            MouseArea {
                id: declineArea
                anchors.fill: parent
                onClicked: root.declined()
            }
        }

        // Answer
        Rectangle {
            width: 160; height: 56; radius: 28
            color: answerArea.pressed ? "#1E9E45" : "#30D158"

            Behavior on color { ColorAnimation { duration: 100 } }

            Row {
                anchors.centerIn: parent
                spacing: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✆"
                    color: "#FFFFFF"
                    font { pixelSize: 18 }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Answer"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 17; weight: Font.SemiBold }
                }
            }

            MouseArea {
                id: answerArea
                anchors.fill: parent
                onClicked: root.answered()
            }
        }
    }
}
