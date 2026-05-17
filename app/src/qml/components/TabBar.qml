// TabBar.qml — Bottom tab bar for lower screen
import QtQuick 2.15

Item {
    id: root
    height: 64

    property int  currentTab: 0
    property var  tabs: ["NAV", "CLIMATE", "AUDIO", "PHONE"]
    property var  icons: ["⬆", "❄", "♪", "✆"]
    signal tabSelected(int index)

    Rectangle {
        anchors.fill: parent
        color: "#0a0f14"
        border { color: "#1a2535"; width: 1 }

        Row {
            anchors.fill: parent

            Repeater {
                model: root.tabs
                delegate: Item {
                    width: root.width / root.tabs.length
                    height: root.height

                    Rectangle {
                        anchors.fill: parent
                        color: (index === root.currentTab) ? "#0d1f30" : "transparent"
                        Rectangle {
                            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                            height: 2
                            color: (index === root.currentTab) ? "#00d4ff" : "transparent"
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 3
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.icons[index]
                            color: (index === root.currentTab) ? "#00d4ff" : "#555"
                            font.pixelSize: 18
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.tabs[index]
                            color: (index === root.currentTab) ? "#00d4ff" : "#444"
                            font { pixelSize: 10; weight: 500;
                                   capitalization: Font.AllUppercase }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.tabSelected(index)
                    }
                }
            }
        }
    }
}
