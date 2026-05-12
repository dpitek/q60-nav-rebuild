import QtQuick 6.6
Row {
    id: root
    property double speed: 0
    property double limit: 45
    spacing: 10
    Rectangle {
        width: 80; height: 68; radius: 12
        color: Qt.rgba(0.05,0.05,0.05,0.92)
        border { color: "#2a2a2a"; width: 1.5 }
        Column { anchors.centerIn: parent; spacing: 2
            Text { text: speed.toFixed(0); color: speed > limit ? "#e84040" : "#3adf8a"
                   font { pixelSize: 36; weight: Font.ExtraBold }; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: "MPH"; color: "#555"; font { pixelSize: 10; letterSpacing: 1.2 }; anchors.horizontalCenter: parent.horizontalCenter }
        }
    }
    Rectangle {
        width: 46; height: 46; radius: 23
        color: "white"
        border { color: "#e84040"; width: 5 }
        anchors.verticalCenter: parent.verticalCenter
        Column { anchors.centerIn: parent; spacing: 0
            Text { text: "SPEED\nLIMIT"; color: "#222"; font { pixelSize: 7; weight: Font.Bold }; horizontalAlignment: Text.AlignHCenter; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: limit.toFixed(0); color: "#111"; font { pixelSize: 16; weight: Font.Black }; anchors.horizontalCenter: parent.horizontalCenter }
        }
    }
}
