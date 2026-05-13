// PhoneView — Bluetooth phone call UI
// Apple CarPlay aesthetic redesign
// Full feature parity: Dial / Contacts / Recent tabs, BT device footer
// All StatusBridge bindings preserved exactly.
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── 3-tab sub-navigation ─────────────────────────────────────────────────
    property int activeTab: 0   // 0=Dial 1=Contacts 2=Recent

    Row {
        id: tabRow
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: 8
        }
        height: 36
        spacing: 8

        Repeater {
            model: ["Dial", "Contacts", "Recent"]
            delegate: Rectangle {
                height: 32; radius: 16; width: tabLbl.width + 26
                anchors.verticalCenter: parent.verticalCenter
                color: root.activeTab === index ? "#0A84FF" : "#1C1C1E"
                border {
                    color: root.activeTab === index ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.15)
                    width: 1
                }
                Behavior on color { ColorAnimation { duration: 150 } }
                Text {
                    id: tabLbl; anchors.centerIn: parent; text: modelData
                    color: root.activeTab === index ? "#FFFFFF" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.activeTab = index
                }
            }
        }
    }

    // ── Content area (between tabs and BT footer) ────────────────────────────
    Item {
        id: contentArea
        anchors {
            top: tabRow.bottom
            bottom: btFooter.top
            left: parent.left; right: callPanel.left
            topMargin: 6; bottomMargin: 4
        }

        // ── DIAL TAB ─────────────────────────────────────────────────────────
        Item {
            id: dialPanel
            anchors.fill: parent
            visible: root.activeTab === 0

            // Idle state
            Column {
                anchors.centerIn: parent
                spacing: 16
                visible: !StatusBridge.callActive

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 80; height: 80; radius: 40
                    color: StatusBridge.btConnected ? Qt.rgba(0.0392, 0.5176, 1, 0.15) : "#1C1C1E"
                    border {
                        color: StatusBridge.btConnected ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.1)
                        width: 2
                    }
                    Text {
                        anchors.centerIn: parent; text: "✆"
                        color: StatusBridge.btConnected ? "#0A84FF" : "#3A3A3C"
                        font.pixelSize: 32
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: StatusBridge.btConnected ? "Phone Connected" : "No Phone Connected"
                    color: StatusBridge.btConnected ? "#FFFFFF" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 17; weight: Font.SemiBold }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: StatusBridge.btConnected
                          ? "Incoming calls will appear here"
                          : "Pair via phone Bluetooth settings"
                    color: "#8E8E93"; font { family: "Roboto"; pixelSize: 13 }
                }
            }

            // Active call state
            Column {
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    top: parent.top; topMargin: 16
                }
                spacing: 16
                visible: StatusBridge.callActive

                // Active call badge
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: 28; radius: 14; width: activeBadgeLbl.width + 28
                    color: Qt.rgba(0.1882, 0.8196, 0.3451, 0.2); border { color: "#30D158"; width: 1 }
                    Text {
                        id: activeBadgeLbl; anchors.centerIn: parent; text: "Active Call"
                        color: "#30D158"; font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                    }
                }

                Column {
                    anchors.horizontalCenter: parent.horizontalCenter; spacing: 4
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter; text: "Incoming"
                        color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 26; weight: Font.Bold }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter; text: callTimerHost.elapsed
                        color: "#8E8E93"; font { family: "Roboto"; pixelSize: 16; weight: Font.Light }
                    }
                }

                // Mute | END | Speaker
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter; spacing: 20

                    Column {
                        spacing: 6
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 64; height: 64; radius: 32
                            color: muteArea.pressed ? "#2C2C2E" : "#1C1C1E"
                            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1.5 }
                            Text { anchors.centerIn: parent; text: "🎤"; font.pixelSize: 24 }
                            MouseArea { id: muteArea; anchors.fill: parent; onClicked: {} }
                        }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Mute"
                               color: "#8E8E93"; font { family: "Roboto"; pixelSize: 11 } }
                    }

                    Column {
                        spacing: 6
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 64; height: 64; radius: 32
                            color: endArea.pressed ? "#CC1A1A" : "#FF453A"
                            Behavior on color { ColorAnimation { duration: 100 } }
                            Text { anchors.centerIn: parent; text: "✆"; color: "#FFFFFF"
                                   font.pixelSize: 26; rotation: 135 }
                            MouseArea { id: endArea; anchors.fill: parent; onClicked: {} }
                        }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "End"
                               color: "#FF453A"; font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold } }
                    }

                    Column {
                        spacing: 6
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 64; height: 64; radius: 32
                            color: spkArea.pressed ? "#2C2C2E" : "#1C1C1E"
                            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1.5 }
                            Text { anchors.centerIn: parent; text: "🔊"; font.pixelSize: 24 }
                            MouseArea { id: spkArea; anchors.fill: parent; onClicked: {} }
                        }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Speaker"
                               color: "#8E8E93"; font { family: "Roboto"; pixelSize: 11 } }
                    }
                }

                // Keypad toggle
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: dialPanel.keypadVisible ? "▲ Hide Keypad" : "▼ Keypad"
                    color: "#0A84FF"; font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
                    MouseArea { anchors.fill: parent; onClicked: dialPanel.keypadVisible = !dialPanel.keypadVisible }
                }
            }

            // DTMF keypad sheet
            property bool keypadVisible: false

            Rectangle {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                height: parent.keypadVisible ? 200 : 0
                color: "#1C1C1E"; radius: 16; clip: true

                Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                Rectangle {
                    anchors { top: parent.top; left: parent.left; right: parent.right }
                    height: 1; color: Qt.rgba(1, 1, 1, 0.15)
                }

                Grid {
                    anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 12 }
                    columns: 3; rows: 4; spacing: 10

                    Repeater {
                        model: ["1","2","3","4","5","6","7","8","9","*","0","#"]
                        delegate: Rectangle {
                            width: 72; height: 44; radius: 10
                            color: dtmfBtn.pressed ? "#2C2C2E" : "#3A3A3C"
                            Text { anchors.centerIn: parent; text: modelData; color: "#FFFFFF"
                                   font { family: "Roboto"; pixelSize: 20; weight: Font.Light } }
                            MouseArea { id: dtmfBtn; anchors.fill: parent; onClicked: {} }
                        }
                    }
                }
            }
        }

        // ── CONTACTS TAB ─────────────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: root.activeTab === 1

            property int pendingCallIndex: -1

            Column {
                anchors.fill: parent
                spacing: 0

                // Search bar
                Rectangle {
                    anchors { left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12 }
                    height: 36; radius: 10; color: "#1C1C1E"
                    border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }

                    Row {
                        anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 10 }
                        spacing: 6

                        Text { text: "🔍"; font.pixelSize: 14; color: "#636366"; anchors.verticalCenter: parent.verticalCenter }
                        TextField {
                            id: contactSearch
                            width: 260; color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 14 }
                            placeholderText: "Search contacts"
                            placeholderTextColor: "#636366"
                            background: Item {}
                        }
                    }
                }

                // Contacts list
                ListView {
                    id: contactsList
                    anchors { left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12 }
                    height: parent.height - 36 - 8 - 20  // minus search, spacing, footer
                    clip: true
                    spacing: 2

                    property int pendingIndex: -1

                    model: ListModel {
                        ListElement { cname: "Sarah Johnson";  cnumber: "+1 (919) 555-0147" }
                        ListElement { cname: "Mike Chen";      cnumber: "+1 (704) 555-0193" }
                        ListElement { cname: "Mom";            cnumber: "+1 (910) 555-0281" }
                        ListElement { cname: "Work";           cnumber: "+1 (919) 555-0134" }
                        ListElement { cname: "David Park";     cnumber: "+1 (919) 555-0162" }
                        ListElement { cname: "KellyAnne";      cnumber: "+1 (919) 555-0199" }
                    }

                    // Filter by search
                    delegate: Column {
                        width: contactsList.width
                        spacing: 0
                        visible: contactSearch.text.length === 0
                                 || cname.toLowerCase().indexOf(contactSearch.text.toLowerCase()) >= 0

                        // Contact row
                        Rectangle {
                            width: parent.width; height: 48; color: "transparent"
                            radius: 10

                            Rectangle {
                                anchors.fill: parent; radius: 10
                                color: contactRowMA.pressed ? "#1C1C1E" : "transparent"
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }

                            Row {
                                anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 4 }
                                spacing: 10

                                // Avatar circle
                                Rectangle {
                                    width: 36; height: 36; radius: 18
                                    color: {
                                        var colors = ["#0A84FF","#BF5AF2","#30D158","#FF9F0A","#FF453A"]
                                        return colors[cname.charCodeAt(0) % colors.length]
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        text: cname.charAt(0).toUpperCase()
                                        color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 16; weight: Font.Bold }
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    Text { text: cname; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 15; weight: Font.Medium } }
                                    Text { text: cnumber; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 12 } }
                                }
                            }

                            MouseArea {
                                id: contactRowMA; anchors.fill: parent
                                onClicked: {
                                    contactsList.pendingIndex = contactsList.pendingIndex === index ? -1 : index
                                }
                            }
                        }

                        // Call confirmation pill
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            height: contactsList.pendingIndex === index ? 32 : 0
                            width: confirmLbl.width + 28; radius: 16
                            color: "#0A84FF"; clip: true
                            visible: height > 0

                            Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                            Text {
                                id: confirmLbl; anchors.centerIn: parent
                                text: "Call " + cname + "?  ✓ Dial"
                                color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    contactsList.pendingIndex = -1
                                    // TODO: initiate BT HFP call to cnumber
                                }
                            }
                        }
                    }
                }

                // Pull contacts footer
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Contacts synced via PBAP  ·  Tap to call"
                    color: "#3A3A3C"; font { family: "Roboto"; pixelSize: 10 }
                    height: 20
                }
            }
        }

        // ── RECENT TAB ───────────────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: root.activeTab === 2

            property int recentSubTab: 0  // 0=Dialed 1=Received 2=Missed

            Column {
                anchors.fill: parent
                spacing: 6

                // Sub-tab pills
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8; height: 30

                    Repeater {
                        model: ["Dialed", "Received", "Missed"]
                        delegate: Rectangle {
                            height: 26; radius: 13; width: recentSubLbl.width + 20
                            anchors.verticalCenter: parent.verticalCenter
                            color: parent.parent.parent.recentSubTab === index ? "#2C2C2E" : "transparent"
                            border {
                                color: parent.parent.parent.recentSubTab === index
                                       ? Qt.rgba(1, 1, 1, 0.3) : Qt.rgba(1, 1, 1, 0.1)
                                width: 1
                            }
                            Text {
                                id: recentSubLbl; anchors.centerIn: parent; text: modelData
                                color: {
                                    if (parent.parent.parent.recentSubTab !== index) return "#8E8E93"
                                    if (index === 0) return "#0A84FF"
                                    if (index === 1) return "#30D158"
                                    return "#FF453A"
                                }
                                font { family: "Roboto"; pixelSize: 12; weight: Font.Medium }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: parent.parent.parent.parent.recentSubTab = index
                            }
                        }
                    }
                }

                // Recent calls list
                ListView {
                    id: recentList
                    anchors { left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12 }
                    height: parent.height - 36
                    clip: true; spacing: 2

                    property int pendingIndex: -1

                    model: {
                        var sub = parent.recentSubTab
                        if (sub === 0) return dialedModel
                        if (sub === 1) return receivedModel
                        return missedModel
                    }

                    delegate: Column {
                        width: recentList.width; spacing: 0

                        Rectangle {
                            width: parent.width; height: 50; color: "transparent"

                            Rectangle {
                                anchors.fill: parent; radius: 10
                                color: recentRowMA.pressed ? "#1C1C1E" : "transparent"
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }

                            Row {
                                anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 4 }
                                spacing: 10

                                // Colored type dot
                                Rectangle {
                                    width: 10; height: 10; radius: 5
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: callType === "missed" ? "#FF453A"
                                           : callType === "received" ? "#30D158" : "#0A84FF"
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    Text { text: callerName; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 15; weight: Font.Medium } }
                                    Text { text: callTime; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 11 } }
                                }

                                Item { width: 1 }  // spacer

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: callDuration; color: "#636366"
                                    font { family: "Roboto"; pixelSize: 11 }
                                }
                            }

                            MouseArea {
                                id: recentRowMA; anchors.fill: parent
                                onClicked: recentList.pendingIndex = recentList.pendingIndex === index ? -1 : index
                            }
                        }

                        // Call confirmation pill
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            height: recentList.pendingIndex === index ? 30 : 0
                            width: recentConfirmLbl.width + 24; radius: 15
                            color: "#0A84FF"; clip: true
                            visible: height > 0
                            Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                            Text {
                                id: recentConfirmLbl; anchors.centerIn: parent
                                text: "Call " + callerName + "?  ✓ Dial"
                                color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    recentList.pendingIndex = -1
                                    // TODO: initiate BT HFP call
                                }
                            }
                        }
                    }

                    ListModel {
                        id: dialedModel
                        ListElement { callerName: "KellyAnne";    callTime: "Today 2:14 PM";    callDuration: "4:32";  callType: "dialed" }
                        ListElement { callerName: "Work";         callTime: "Today 10:07 AM";   callDuration: "8:11";  callType: "dialed" }
                        ListElement { callerName: "Mike Chen";    callTime: "Yesterday 6:44 PM"; callDuration: "1:28"; callType: "dialed" }
                        ListElement { callerName: "Mom";          callTime: "Yesterday 12:00 PM"; callDuration: "12:04"; callType: "dialed" }
                        ListElement { callerName: "David Park";   callTime: "May 10 3:22 PM";   callDuration: "0:42";  callType: "dialed" }
                    }

                    ListModel {
                        id: receivedModel
                        ListElement { callerName: "Sarah Johnson"; callTime: "Today 9:15 AM";    callDuration: "3:17";  callType: "received" }
                        ListElement { callerName: "Mom";           callTime: "Today 8:02 AM";    callDuration: "6:50";  callType: "received" }
                        ListElement { callerName: "KellyAnne";    callTime: "Yesterday 7:30 PM"; callDuration: "2:05"; callType: "received" }
                        ListElement { callerName: "Work";         callTime: "Yesterday 9:00 AM"; callDuration: "15:33"; callType: "received" }
                        ListElement { callerName: "David Park";   callTime: "May 11 4:05 PM";   callDuration: "0:58";  callType: "received" }
                    }

                    ListModel {
                        id: missedModel
                        ListElement { callerName: "Unknown";       callTime: "Today 7:44 AM";    callDuration: "";      callType: "missed" }
                        ListElement { callerName: "Mike Chen";     callTime: "Yesterday 5:20 PM"; callDuration: "";     callType: "missed" }
                        ListElement { callerName: "Sarah Johnson"; callTime: "May 11 11:30 AM";  callDuration: "";      callType: "missed" }
                        ListElement { callerName: "+1 (910) 555-0999"; callTime: "May 10 8:00 PM"; callDuration: "";   callType: "missed" }
                        ListElement { callerName: "Work";          callTime: "May 10 8:45 AM";   callDuration: "";      callType: "missed" }
                    }
                }
            }
        }
    }

    // ── BT device footer bar ─────────────────────────────────────────────────
    Rectangle {
        id: btFooter
        anchors { bottom: parent.bottom; left: parent.left; right: callPanel.left }
        height: 28; color: "#0D0D0D"

        // Top separator
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1; color: Qt.rgba(1, 1, 1, 0.08)
        }

        Row {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 14 }
            spacing: 8

            // Connected dot
            Rectangle {
                width: 8; height: 8; radius: 4
                anchors.verticalCenter: parent.verticalCenter
                color: AudioService.btConnected ? "#30D158" : "#636366"
                Behavior on color { ColorAnimation { duration: 150 } }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: AudioService.btConnected
                      ? (AudioService.btDeviceName.length > 0 ? AudioService.btDeviceName : "iPhone")
                      : "No device"
                color: AudioService.btConnected ? "#8E8E93" : "#636366"
                font { family: "Roboto"; pixelSize: 11 }
            }
        }

        // Signal bars (right side) — decorative, wired when RSSI available
        Row {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 14 }
            spacing: 3

            Repeater {
                model: 4
                delegate: Rectangle {
                    width: 4; height: 6 + index * 3; radius: 1
                    anchors.bottom: parent.bottom
                    color: index < (AudioService.btConnected ? 3 : 0) ? "#8E8E93" : "#3A3A3C"
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }
        }
    }

    // ── Persistent call controls (right panel) ────────────────────────────────
    // Always visible — answer, end, and mute regardless of active call state.
    Rectangle {
        id: callPanel
        anchors { top: parent.top; right: parent.right; bottom: parent.bottom }
        width: 88
        color: "#080808"

        // Left separator
        Rectangle {
            anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
            width: 1; color: Qt.rgba(1, 1, 1, 0.1)
        }

        Column {
            anchors.centerIn: parent
            spacing: 14

            // Answer button
            Column {
                spacing: 5
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 54; height: 54; radius: 27
                    color: answerPanelArea.pressed ? "#228B22" : "#30D158"
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Text {
                        anchors.centerIn: parent; text: "✆"
                        color: "#FFFFFF"; font.pixelSize: 24
                    }
                    MouseArea {
                        id: answerPanelArea; anchors.fill: parent; onClicked: {}
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Answer"
                    color: "#30D158"
                    font { family: "Roboto"; pixelSize: 10; weight: Font.Medium }
                }
            }

            // End call button
            Column {
                spacing: 5
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 54; height: 54; radius: 27
                    color: endPanelArea.pressed ? "#CC1A1A" : "#FF453A"
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Text {
                        anchors.centerIn: parent; text: "✆"
                        color: "#FFFFFF"; font.pixelSize: 24; rotation: 135
                    }
                    MouseArea {
                        id: endPanelArea; anchors.fill: parent; onClicked: {}
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "End"
                    color: "#FF453A"
                    font { family: "Roboto"; pixelSize: 10; weight: Font.SemiBold }
                }
            }

            // Mute button
            Column {
                spacing: 5
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 54; height: 54; radius: 27
                    color: mutePanelArea.pressed ? "#2C2C2E" : "#1C1C1E"
                    border { color: Qt.rgba(1, 1, 1, 0.2); width: 1.5 }
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Text {
                        anchors.centerIn: parent; text: "🎤"; font.pixelSize: 20
                    }
                    MouseArea {
                        id: mutePanelArea; anchors.fill: parent; onClicked: {}
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Mute"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 10 }
                }
            }
        }
    }

    // ── Call timer ───────────────────────────────────────────────────────────
    // Note: Timer can't be a child of QtObject (no default property).
    // Use a plain Item container so both the state object and Timer coexist.
    Item {
        id: callTimerHost
        visible: false  // no visual — logic only

        property int seconds: 0
        property string elapsed: {
            var m = Math.floor(seconds / 60)
            var s = seconds % 60
            return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
        }

        Timer {
            interval: 1000; repeat: true; running: StatusBridge.callActive
            onTriggered: callTimerHost.seconds++
        }
    }

    Connections {
        target: StatusBridge
        function onCallActiveChanged(active) {
            if (!active) callTimerHost.seconds = 0
        }
    }
}
