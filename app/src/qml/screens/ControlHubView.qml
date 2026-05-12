// ControlHubView — Lower 7" screen
// Tabs: Climate | Audio | Nav | Phone
// Auto-switches on call / reverse
import QtQuick 6.6
import QtQuick.Controls 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    property int activeTab: 0   // 0=climate 1=audio 2=nav 3=phone

    Rectangle { anchors.fill: parent; color: "#080d12" }

    // ── Auto-switch triggers ─────────────────────────────────────────────
    Connections {
        target: StatusBridge
        function onSwitchLowerToPhone()  { activeTab = 3 }
        function onRestoreLowerScreen()  { activeTab = previousTab }
    }
    Connections {
        target: StatusBridge
        function onReverseActiveChanged(rev) {
            if (rev) { previousTab = activeTab; activeTab = 4 }
            else      { activeTab = previousTab }
        }
    }

    property int previousTab: 0

    // ── Content area ─────────────────────────────────────────────────────
    Item {
        id: contentArea
        anchors {
            top: parent.top
            bottom: tabBar.top
            left: parent.left; right: parent.right
        }

        ClimateView      { anchors.fill: parent; visible: activeTab === 0 }
        AudioView        { anchors.fill: parent; visible: activeTab === 1 }
        NavCompanionView { anchors.fill: parent; visible: activeTab === 2 }
        PhoneView        { anchors.fill: parent; visible: activeTab === 3 }

        // Reverse / camera placeholder (tab 4 — auto only)
        Rectangle {
            anchors.fill: parent
            visible: activeTab === 4
            color: "#000"
            Text {
                anchors.centerIn: parent
                text: "R"
                color: "#ff4444"
                font { pixelSize: 80; weight: Font.Black }
                opacity: 0.15
            }
            Text {
                anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 20 }
                text: "REVERSE"
                color: "#ff4444"
                font { pixelSize: 13; weight: Font.Bold; capitalization: Font.AllUppercase }
            }
        }
    }

    // ── Tab bar ──────────────────────────────────────────────────────────
    TabBar {
        id: tabBar
        anchors { bottom: statusBar.top; left: parent.left; right: parent.right }
        tabs:  ["CLIMATE", "AUDIO", "NAV", "PHONE"]
        icons: ["❄",       "♪",     "⬆",   "✆"]
        currentTab: activeTab < 4 ? activeTab : -1
        onTabSelected: function(i) { activeTab = i }
    }

    // ── Status bar ───────────────────────────────────────────────────────
    Rectangle {
        id: statusBar
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 26
        color: "#050a0f"
        border { color: "#0d1520"; width: 1 }

        Row {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 14 }
            spacing: 12

            Row {
                spacing: 5
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    width: 6; height: 6; radius: 3
                    anchors.verticalCenter: parent.verticalCenter
                    color: StatusBridge.gpsLock ? "#3adf8a" : "#555"
                }
                Text { text: "GPS"; color: StatusBridge.gpsLock ? "#3adf8a" : "#444"; font.pixelSize: 10 }
            }

            Row {
                spacing: 5
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    width: 6; height: 6; radius: 3
                    anchors.verticalCenter: parent.verticalCenter
                    color: StatusBridge.btConnected ? "#00d4ff" : "#555"
                }
                Text { text: "BT"; color: StatusBridge.btConnected ? "#00d4ff" : "#444"; font.pixelSize: 10 }
            }

            Row {
                spacing: 5
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    width: 6; height: 6; radius: 3
                    anchors.verticalCenter: parent.verticalCenter
                    color: StatusBridge.sxmActive ? "#a855f7" : "#555"
                }
                Text { text: "SXM"; color: StatusBridge.sxmActive ? "#a855f7" : "#444"; font.pixelSize: 10 }
            }
        }

        Text {
            anchors.centerIn: parent
            text: StatusBridge.navActive
                  ? (StatusBridge.nextDistance.toFixed(1) + " mi · " + StatusBridge.eta)
                  : ""
            color: "#00d4ff"
            font.pixelSize: 10
        }

        Row {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 14 }
            spacing: 12
            Text { text: VehicleService.outsideTemp.toFixed(0) + "°F"; color: "#555"; font.pixelSize: 10 }
            Text { text: StatusBridge.timeString; color: "#666"; font.pixelSize: 10 }
        }
    }
}
