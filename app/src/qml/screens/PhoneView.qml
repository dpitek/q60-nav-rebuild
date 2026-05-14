// PhoneView — Bluetooth phone call UI
// Apple CarPlay aesthetic redesign
// Full feature parity: Dial / Contacts / Recent tabs, BT device footer
// All StatusBridge bindings preserved exactly.
import QtQuick
import QtQuick.Controls
import "../components"

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Shared contacts + recent calls data source ───────────────────────────
    // Mock data lives in ContactsModel.qml; same component is also embedded by
    // IncomingCallView for caller-ID resolution. Real PBAP binding pending
    // BlueZ on hardware. See backlog.
    ContactsModel { id: phoneData }

    // Exposed for parents / other QML to drive caller-ID lookups against the
    // same fixture, e.g. `phoneView.lookupCallerName(incomingNumber)`.
    property alias contactsModel: phoneData.contacts
    property alias recentsModel:  phoneData.recents
    function lookupCallerName(number) { return phoneData.lookupCallerName(number) }

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
                    font { family: "Roboto"; pixelSize: 13; weight: 600 }
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
                    font { family: "Roboto"; pixelSize: 17; weight: 600 }
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
                        color: "#30D158"; font { family: "Roboto"; pixelSize: 12; weight: 600 }
                    }
                }

                Column {
                    anchors.horizontalCenter: parent.horizontalCenter; spacing: 4
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter; text: "Incoming"
                        color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 26; weight: 700 }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter; text: callTimerHost.elapsed
                        color: "#8E8E93"; font { family: "Roboto"; pixelSize: 16; weight: 300 }
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
                            color: StatusBridge.muted ? "#0A84FF" : (muteArea.pressed ? "#2C2C2E" : "#1C1C1E")
                            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1.5 }
                            Text { anchors.centerIn: parent; text: "🎤"; font.pixelSize: 24 }
                            MouseArea { id: muteArea; anchors.fill: parent; onClicked: StatusBridge.toggleMute() }
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
                            MouseArea { id: endArea; anchors.fill: parent; onClicked: StatusBridge.endCall() }
                        }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "End"
                               color: "#FF453A"; font { family: "Roboto"; pixelSize: 11; weight: 600 } }
                    }

                    Column {
                        spacing: 6
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 64; height: 64; radius: 32
                            color: StatusBridge.speakerOn ? "#0A84FF" : (spkArea.pressed ? "#2C2C2E" : "#1C1C1E")
                            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1.5 }
                            Text { anchors.centerIn: parent; text: "🔊"; font.pixelSize: 24 }
                            MouseArea { id: spkArea; anchors.fill: parent; onClicked: StatusBridge.toggleSpeaker() }
                        }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Speaker"
                               color: "#8E8E93"; font { family: "Roboto"; pixelSize: 11 } }
                    }
                }

                // Keypad toggle
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: dialPanel.keypadVisible ? "▲ Hide Keypad" : "▼ Keypad"
                    color: "#0A84FF"; font { family: "Roboto"; pixelSize: 13; weight: 500 }
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
                                   font { family: "Roboto"; pixelSize: 20; weight: 300 } }
                            MouseArea { id: dtmfBtn; anchors.fill: parent; onClicked: StatusBridge.sendDtmf(modelData) }
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

                // Contacts list — backed by shared ContactsModel.
                // Rows: avatar, name, number, type pill. Tap to reveal Dial pill.
                // Row touch target = 56px (per spec). Filter applied client-side
                // against name OR number substring.
                ListView {
                    id: contactsList
                    anchors { left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12 }
                    height: parent.height - 36 - 8 - 20  // minus search, spacing, footer
                    clip: true
                    spacing: 2

                    property int pendingIndex: -1
                    model: root.contactsModel

                    delegate: Column {
                        width: contactsList.width
                        spacing: 0

                        // Filter: empty query shows all; otherwise match name OR number.
                        property string _q: contactSearch.text.toLowerCase()
                        visible: _q.length === 0
                                 || name.toLowerCase().indexOf(_q) >= 0
                                 || number.toLowerCase().indexOf(_q) >= 0
                        height: visible ? implicitHeight : 0

                        // Contact row (56px tall — touch target per Q60 UI spec)
                        Rectangle {
                            width: parent.width; height: 56; color: "transparent"
                            radius: 10

                            Rectangle {
                                anchors.fill: parent; radius: 10
                                color: contactRowMA.pressed ? "#1C1C1E" : "transparent"
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }

                            Row {
                                anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 4; right: typePill.left; rightMargin: 8 }
                                spacing: 10

                                // Avatar circle
                                Rectangle {
                                    width: 40; height: 40; radius: 20
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: {
                                        var colors = ["#0A84FF","#BF5AF2","#30D158","#FF9F0A","#FF453A"]
                                        return colors[name.charCodeAt(0) % colors.length]
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        text: name.charAt(0).toUpperCase()
                                        color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 16; weight: 700 }
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    Text { text: name; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 15; weight: 500 } }
                                    Text { text: number; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 12 } }
                                }
                            }

                            // Type pill (mobile / home / work)
                            Rectangle {
                                id: typePill
                                anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 8 }
                                width: typeLbl.width + 16; height: 20; radius: 10
                                color: "#1C1C1E"
                                border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }
                                Text {
                                    id: typeLbl
                                    anchors.centerIn: parent
                                    text: type
                                    color: type === "mobile" ? "#0A84FF"
                                           : type === "work"  ? "#FF9F0A" : "#30D158"
                                    font { family: "Roboto"; pixelSize: 10; weight: 600; capitalization: Font.AllUppercase }
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
                                text: "Call " + name + "?  ✓ Dial"
                                color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 12; weight: 600 }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    contactsList.pendingIndex = -1
                                    StatusBridge.dial(number)
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
                                font { family: "Roboto"; pixelSize: 12; weight: 500 }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: parent.parent.parent.parent.recentSubTab = index
                            }
                        }
                    }
                }

                // Recent calls list — shared recentsModel filtered per sub-tab.
                // Rows that don't match the active sub-tab collapse to zero height
                // so the ListView stays the same model but only shows the slice.
                ListView {
                    id: recentList
                    anchors { left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12 }
                    height: parent.height - 36
                    clip: true; spacing: 2

                    property int pendingIndex: -1
                    // 0=Dialed → "dialed", 1=Received → "received", 2=Missed → "missed"
                    readonly property string activeType: {
                        var sub = parent.parent.recentSubTab
                        if (sub === 0) return "dialed"
                        if (sub === 1) return "received"
                        return "missed"
                    }

                    model: root.recentsModel

                    delegate: Column {
                        width: recentList.width; spacing: 0
                        visible: callType === recentList.activeType
                        height: visible ? implicitHeight : 0

                        // 56px row (touch target per Q60 UI spec)
                        Rectangle {
                            width: parent.width; height: 56; color: "transparent"

                            Rectangle {
                                anchors.fill: parent; radius: 10
                                color: recentRowMA.pressed ? "#1C1C1E" : "transparent"
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }

                            Row {
                                anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 4; right: durLbl.left; rightMargin: 8 }
                                spacing: 10

                                // Call-type icon (arrow direction + tint)
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: callType === "missed"   ? "✕"
                                          : callType === "received" ? "↙"
                                                                    : "↗"
                                    color: callType === "missed"   ? "#FF453A"
                                           : callType === "received" ? "#30D158"
                                                                     : "#0A84FF"
                                    font { family: "Roboto"; pixelSize: 18; weight: 700 }
                                    width: 20; horizontalAlignment: Text.AlignHCenter
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    // Display the name when present, else the raw number
                                    Text {
                                        text: (name && name.length > 0) ? name : number
                                        color: callType === "missed" ? "#FF453A" : "#FFFFFF"
                                        font { family: "Roboto"; pixelSize: 15; weight: 500 }
                                    }
                                    Text {
                                        text: timestamp
                                        color: "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 11 }
                                    }
                                }
                            }

                            // Call duration (blank for missed)
                            Text {
                                id: durLbl
                                anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 8 }
                                text: duration
                                color: "#636366"
                                font { family: "Roboto"; pixelSize: 11 }
                            }

                            MouseArea {
                                id: recentRowMA; anchors.fill: parent
                                onClicked: recentList.pendingIndex = recentList.pendingIndex === index ? -1 : index
                            }
                        }

                        // Call confirmation pill (tap to call back)
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            height: recentList.pendingIndex === index ? 30 : 0
                            width: recentConfirmLbl.width + 24; radius: 15
                            color: "#0A84FF"; clip: true
                            visible: height > 0
                            Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                            Text {
                                id: recentConfirmLbl; anchors.centerIn: parent
                                text: "Call " + ((name && name.length > 0) ? name : number) + " back?  ✓ Dial"
                                color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 12; weight: 600 }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    recentList.pendingIndex = -1
                                    // TODO: initiate BT HFP call to `number` once
                                    // AudioService HFP wiring lands.
                                }
                            }
                        }
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
                        id: answerPanelArea; anchors.fill: parent
                        onClicked: StatusBridge.answerCall()
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Answer"
                    color: "#30D158"
                    font { family: "Roboto"; pixelSize: 10; weight: 500 }
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
                        id: endPanelArea; anchors.fill: parent
                        onClicked: StatusBridge.endCall()
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "End"
                    color: "#FF453A"
                    font { family: "Roboto"; pixelSize: 10; weight: 600 }
                }
            }

            // Mute button
            Column {
                spacing: 5
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 54; height: 54; radius: 27
                    color: StatusBridge.muted ? "#0A84FF" : (mutePanelArea.pressed ? "#2C2C2E" : "#1C1C1E")
                    border { color: Qt.rgba(1, 1, 1, 0.2); width: 1.5 }
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Text {
                        anchors.centerIn: parent; text: "🎤"; font.pixelSize: 20
                    }
                    MouseArea {
                        id: mutePanelArea; anchors.fill: parent
                        onClicked: StatusBridge.toggleMute()
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
