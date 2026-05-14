// ControlHubView — Lower 7" screen
// Apple CarPlay aesthetic redesign
// 5-tab bottom nav: Home(0) Audio(1) Phone(2) Climate(3) Vehicle(4)
// Tab 7 = reverse camera (auto-switch only, not in nav bar)
// Auto-switches on call / reverse — all StatusBridge signals preserved exactly.
import QtQuick
import QtQuick.Controls
import "../components"

Item {
    id: root
    anchors.fill: parent

    property int activeTab: 0   // 0=home 1=audio 2=phone 3=climate 4=vehicle
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
            if (rev) { previousTab = activeTab; activeTab = 7 }
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

        NavCompanionView  { anchors.fill: parent; visible: activeTab === 0; keyboard: lowerKb }
        AudioView         { anchors.fill: parent; visible: activeTab === 1 }
        PhoneView         { anchors.fill: parent; visible: activeTab === 2 }
        ClimateView       { anchors.fill: parent; visible: activeTab === 3 }
        VehicleStatusView { anchors.fill: parent; visible: activeTab === 4 }

        // Reverse / camera placeholder (tab 7 — auto only, not in nav bar)
        Rectangle {
            anchors.fill: parent
            visible: activeTab === 7
            color: "#000000"

            Column {
                anchors.centerIn: parent
                spacing: 12

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "R"
                    color: "#0A84FF"
                    font { pixelSize: 80; weight: 900 }
                    opacity: 0.9
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "REVERSE"
                    color: "#0A84FF"
                    font { family: "Roboto"; pixelSize: 13; weight: 600; capitalization: Font.AllUppercase; letterSpacing: 5 }
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

    // ── Global on-screen keyboard (lower screen) ─────────────────────────────
    // Owned at ControlHubView level so it overlays the entire lower display
    // including the bottom nav. Sub-views receive a reference via the `keyboard`
    // property and call .show(textField) / .hide() to drive it.
    QmlKeyboard {
        id: lowerKb
        z: 250   // above bottom nav (z:0) and incoming call overlay (z:100)
    }

    // ── Bottom navigation bar — 60px ────────────────────────────────────────
    // 5 content tabs at 160px each = 800px.
    Rectangle {
        id: bottomNav
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 60
        color: "#0A0A0A"

        // Top separator
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1
            color: Qt.rgba(1, 1, 1, 0.12)
        }

        Row {
            anchors.fill: parent

            // ── 5 content tabs ───────────────────────────────────────────────
            Repeater {
                model: [
                    { label: "Home",    icon: "⌂", tab: 0 },
                    { label: "Audio",   icon: "♪", tab: 1 },
                    { label: "Phone",   icon: "✆", tab: 2 },
                    { label: "Climate", icon: "❄", tab: 3 },
                    { label: "Vehicle", icon: "◈", tab: 4 }
                ]

                delegate: Item {
                    // 5 tabs on 800px = 160px each
                    width: 160
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
                            font { family: "Roboto"; pixelSize: 10; weight: 500 }
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }
                    }

                    // Phone call pulse dot
                    Rectangle {
                        anchors { top: parent.top; right: parent.right; topMargin: 8; rightMargin: 10 }
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
                            if (activeTab !== 7)  // don't allow manual switch during reverse
                                activeTab = modelData.tab
                        }
                    }
                }
            }
        }
    }
}
