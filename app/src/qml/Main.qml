// Q60 Nav Rebuild — Main QML root
// Two Windows: upper 8" nav, lower 7" hub
// Screen assignment is done in main.cpp via QGuiApplication::screens()
import QtQuick 6.6
import QtQuick.Window 6.6
import "screens"

Window {
    id: upperScreen
    objectName: "upperScreen"
    width: 800; height: 480
    title: "Q60 Nav — Upper"
    color: "#080d12"
    flags: Qt.FramelessWindowHint

    NavigationView {
        anchors.fill: parent
    }
}

Window {
    id: lowerScreen
    objectName: "lowerScreen"
    width: 800; height: 420
    title: "Q60 Nav — Lower"
    color: "#080d12"
    flags: Qt.FramelessWindowHint

    ControlHubView {
        anchors.fill: parent
    }
}
