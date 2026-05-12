// FanControl.qml — Fan speed slider (0–7 levels) with bar visualization
import QtQuick 6.6

Item {
    id: root
    width: 280; height: 72

    property int fanSpeed: 4   // 0–7
    property int maxSpeed: 7
    signal speedChanged(int newSpeed)

    Row {
        anchors.fill: parent
        spacing: 0

        // Fan icon
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "❄"
            color: root.fanSpeed > 0 ? "#00d4ff" : "#333"
            font.pixelSize: 26
            width: 40
        }

        // Bar segments
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Repeater {
                model: root.maxSpeed
                delegate: Rectangle {
                    width: 24
                    height: 20 + index * 6   // Progressive height
                    anchors.bottom: parent ? parent.bottom : undefined
                    radius: 3
                    color: (index < root.fanSpeed) ? "#00d4ff" : "#1e2a3a"
                    border { color: "#0a1520"; width: 1 }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.speedChanged(index + 1)
                    }
                }
            }
        }

        // OFF button
        Text {
            anchors.verticalCenter: parent.verticalCenter
            leftPadding: 10
            text: root.fanSpeed === 0 ? "OFF" : "  "
            color: root.fanSpeed === 0 ? "#ff4444" : "#333"
            font { pixelSize: 13; weight: Font.Bold }
            MouseArea {
                anchors.fill: parent
                onClicked: root.speedChanged(0)
            }
        }
    }
}
