// ControlHubView — Lower 7" screen
// Apple CarPlay aesthetic redesign
// 5-tab bottom nav: Nav | Audio | Phone | Climate | Vehicle
// Auto-switches on call / reverse — all StatusBridge signals preserved exactly.
import QtQuick 6.6
import QtQuick.Controls 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    property int activeTab: 0   // 0=nav 1=audio 2=phone 3=climate 4=vehicle
    property int previousTab: 0

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Auto-switch triggers ────────────────────────────────────────────────
    Connections {
        target: StatusBridge
        function onSwitchLowerToPhone()  { previousTab = activeTab; activeTab = 2 }
        function onRestoreLowerScreen()  { activeTab = previousTab }
    }

    Connections {
        target: StatusBridge
        function onReverseActiveChanged(rev) {
            if (rev) { previousTab = activeTab; activeTab = 5 }
            else      { activeTab = previousTab }
        }
    }

    // ── Content area ────────────────────────────────────────────────────────
    Item {
        id: contentArea
        anchors {
            top: parent.top
            bottom: bottomNav.top
            left: parent.left; right: parent.right
        }

        NavCompanionView  { anchors.fill: parent; visible: activeTab === 0 }
        AudioView         { anchors.fill: parent; visible: activeTab === 1 }
        PhoneView         { anchors.fill: parent; visible: activeTab === 2 }
        ClimateView       { anchors.fill: parent; visible: activeTab === 3 }
        VehicleStatusView { anchors.fill: parent; visible: activeTab === 4 }

        // Reverse / camera placeholder (tab 5 — auto only, not in nav bar)
        Rectangle {
            anchors.fill: parent
            visible: activeTab === 5
            color: "#000000"

            Column {
                anchors.centerIn: parent
                spacing: 12

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "R"
                    color: "#0A84FF"
                    font { pixelSize: 80; weight: Font.Black }
                    opacity: 0.9
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "REVERSE"
                    color: "#0A84FF"
                    font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold; capitalization: Font.AllUppercase; letterSpacing: 5 }
                }
            }

            Rectangle {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                height: 4
                color: "#0A84FF"
                opacity: 0.6
            }
        }
    }

    // ── Bottom navigation bar — 60px ────────────────────────────────────────
    Rectangle {
        id: bottomNav
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 60
        color: "#0A0A0A"

        // Top separator
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1
            color: "rgba(255,255,255,0.12)"
        }

        Row {
            anchors.fill: parent

            Repeater {
                model: [
                    { label: "Nav",     icon: "⬆",  tab: 0 },
                    { label: "Audio",   icon: "♪",  tab: 1 },
                    { label: "Phone",   icon: "✆",  tab: 2 },
                    { label: "Climate", icon: "❄",  tab: 3 },
                    { label: "Vehicle", icon: "◈",  tab: 4 }
                ]

                delegate: Item {
                    width: bottomNav.width / 5
                    height: bottomNav.height

                    // Active indicator bar at top
                    Rectangle {
                        anchors { top: parent.top; left: parent.left; right: parent.right }
                        height: 2; radius: 1
                        color: activeTab === modelData.tab ? "#0A84FF" : "transparent"
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 3

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.icon
                            color: activeTab === modelData.tab ? "#0A84FF" : "#8E8E93"
                            font { pixelSize: 20 }

                            Behavior on color { ColorAnimation { duration: 150 } }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.label
                            color: activeTab === modelData.tab ? "#0A84FF" : "#8E8E93"
                            font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }

                            Behavior on color { ColorAnimation { duration: 150 } }
                        }
                    }

                    // Phone call pulse dot
                    Rectangle {
                        anchors { top: parent.top; right: parent.right; topMargin: 8; rightMargin: 12 }
                        width: 6; height: 6; radius: 3
                        color: "#30D158"
                        visible: modelData.tab === 2 && StatusBridge.callActive

                        SequentialAnimation on opacity {
                            running: StatusBridge.callActive
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.3; duration: 600 }
                            NumberAnimation { to: 1.0; duration: 600 }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (activeTab !== 5)  // Don't allow manual switch during reverse
                                activeTab = modelData.tab
                        }
                    }
                }
            }
        }
    }
}
