// ControlHubView — Lower 7" screen
// Apple CarPlay aesthetic redesign
// 7-tab bottom nav: Nav(0) Audio(1) Phone(2) Climate(3) Vehicle(4) Info(5) Settings(6)
// Tab 7 = reverse camera (auto-switch only, not in nav bar)
// Auto-switches on call / reverse — all StatusBridge signals preserved exactly.
import QtQuick 6.6
import QtQuick.Controls 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    property int activeTab: 0   // 0=home 1=audio 2=phone 3=climate 4=vehicle 5=info 6=settings
    property int previousTab: 0
    property bool volumeOpen: false   // quick-access volume overlay

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

        NavCompanionView  { anchors.fill: parent; visible: activeTab === 0 }
        AudioView         { anchors.fill: parent; visible: activeTab === 1 }
        PhoneView         { anchors.fill: parent; visible: activeTab === 2 }
        ClimateView       { anchors.fill: parent; visible: activeTab === 3 }
        VehicleStatusView { anchors.fill: parent; visible: activeTab === 4 }
        InfoView          { anchors.fill: parent; visible: activeTab === 5 }
        SettingsView      { anchors.fill: parent; visible: activeTab === 6 }

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

    // ── Volume quick-access overlay — slides up from bottom nav ──────────────
    // Not a full screen tab — just a compact slider tray above the nav bar.
    // Auto-dismisses after 4s of no interaction.
    Rectangle {
        id: volumeOverlay
        anchors { bottom: bottomNav.top; left: parent.left; right: parent.right }
        height: 64
        color: "#0D0D0D"
        border { color: Qt.rgba(1, 1, 1, 0.1); width: 1 }

        // Slide animation
        visible: root.volumeOpen
        opacity: root.volumeOpen ? 1.0 : 0.0
        transform: Translate { y: root.volumeOpen ? 0 : 20 }
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        // Auto-dismiss timer
        Timer {
            id: volumeDismissTimer
            interval: 4000
            onTriggered: root.volumeOpen = false
        }

        Row {
            anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
            spacing: 12

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: AudioService.muted ? "🔇" : "🔊"
                font.pixelSize: 20
                MouseArea { anchors.fill: parent; onClicked: AudioService.setMuted(!AudioService.muted) }
            }

            // Volume slider track
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 60; height: 40

                Rectangle {
                    id: volTrack
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width; height: 8; radius: 4
                    color: "#2C2C2E"

                    Rectangle {
                        width: parent.width * (AudioService.volume / 100)
                        height: parent.height; radius: 4
                        color: "#0A84FF"
                        Behavior on width { NumberAnimation { duration: 80 } }
                    }
                }

                // Drag handle
                Rectangle {
                    width: 24; height: 24; radius: 12
                    anchors.verticalCenter: parent.verticalCenter
                    x: Math.max(0, Math.min(parent.width - 24, parent.width * (AudioService.volume / 100) - 12))
                    color: "#FFFFFF"
                    layer.enabled: true
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        var v = Math.round((mouseX / width) * 100)
                        AudioService.setVolume(Math.max(0, Math.min(100, v)))
                        volumeDismissTimer.restart()
                    }
                    onPositionChanged: {
                        if (pressed) {
                            var v = Math.round((mouseX / width) * 100)
                            AudioService.setVolume(Math.max(0, Math.min(100, v)))
                            volumeDismissTimer.restart()
                        }
                    }
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: AudioService.volume + "%"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                width: 40
            }
        }
    }

    // ── Bottom navigation bar — 60px ────────────────────────────────────────
    // 7 content tabs + 1 volume quick-action = 8 items at 100px each.
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

            // ── 7 content tabs ───────────────────────────────────────────────
            Repeater {
                model: [
                    { label: "Home",     icon: "⌂",  tab: 0 },
                    { label: "Audio",    icon: "♪",  tab: 1 },
                    { label: "Phone",    icon: "✆",  tab: 2 },
                    { label: "Climate",  icon: "❄",  tab: 3 },
                    { label: "Vehicle",  icon: "◈",  tab: 4 },
                    { label: "Info",     icon: "ℹ",  tab: 5 },
                    { label: "Settings", icon: "⚙",  tab: 6 }
                ]

                delegate: Item {
                    // 8 items on 800px = 100px each
                    width: 100
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
                            font { family: "Roboto"; pixelSize: 10; weight: Font.Medium }
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
                            if (activeTab !== 7) {  // don't allow manual switch during reverse
                                activeTab = modelData.tab
                                root.volumeOpen = false
                            }
                        }
                    }
                }
            }

            // ── Volume quick-action button (8th item) ─────────────────────
            Item {
                width: 100; height: bottomNav.height

                // Active bar — lit when overlay is open
                Rectangle {
                    anchors { top: parent.top; left: parent.left; right: parent.right }
                    height: 2; radius: 1
                    color: root.volumeOpen ? "#FF9F0A" : "transparent"
                    Behavior on color { ColorAnimation { duration: 150 } }
                }

                Column {
                    anchors.centerIn: parent
                    spacing: 3
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: AudioService.muted ? "🔇" : "🔊"
                        font { pixelSize: 20 }
                        color: root.volumeOpen ? "#FF9F0A" : "#8E8E93"
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Volume"
                        color: root.volumeOpen ? "#FF9F0A" : "#8E8E93"
                        font { family: "Roboto"; pixelSize: 10; weight: Font.Medium }
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.volumeOpen = !root.volumeOpen
                        if (root.volumeOpen) volumeDismissTimer.restart()
                    }
                }
            }
        }
    }
}
