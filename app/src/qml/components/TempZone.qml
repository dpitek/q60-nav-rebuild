// TempZone.qml — Driver or passenger temperature zone control
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    width: 140; height: 200

    property string label: "Driver"
    property real   temperature: 72.0
    property real   minTemp: 60.0
    property real   maxTemp: 85.0
    property bool   isDriver: true

    signal tempChanged(real newTemp)

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 8

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.label
            color: "#666"
            font { pixelSize: 12; weight: Font.Medium; capitalization: Font.AllUppercase }
        }

        // Up arrow
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 48; height: 48
            radius: 8
            color: upArea.pressed ? "#2a4a6a" : "#1a2a3a"
            border { color: "#00d4ff"; width: 1 }

            Text {
                anchors.centerIn: parent
                text: "▲"
                color: "#00d4ff"
                font.pixelSize: 20
            }
            MouseArea {
                id: upArea
                anchors.fill: parent
                onClicked: {
                    var next = Math.min(root.maxTemp, root.temperature + 1)
                    root.tempChanged(next)
                }
            }
        }

        // Temperature display
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.temperature.toFixed(0) + "°"
            color: "#f0f0f0"
            font { pixelSize: 38; weight: Font.Light }
        }

        // Down arrow
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 48; height: 48
            radius: 8
            color: downArea.pressed ? "#2a4a6a" : "#1a2a3a"
            border { color: "#00d4ff"; width: 1 }

            Text {
                anchors.centerIn: parent
                text: "▼"
                color: "#00d4ff"
                font.pixelSize: 20
            }
            MouseArea {
                id: downArea
                anchors.fill: parent
                onClicked: {
                    var next = Math.max(root.minTemp, root.temperature - 1)
                    root.tempChanged(next)
                }
            }
        }
    }
}
