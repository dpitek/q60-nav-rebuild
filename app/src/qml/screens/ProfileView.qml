// ProfileView.qml — Driver profile management screen
// Shown in Settings → "Driver Profiles" row, or auto-shown on first boot.
// Lower 7" control hub (800×420). Design language: true black / #0A84FF accent / Roboto.
//
// Sections:
//   1. Profile card carousel (horizontal scroll)
//   2. Add Profile floating action
//   3. Creation bottom sheet (name + avatar + accent + key slot)
//   4. Per-profile edit screen (all settings)
//   5. Delete with confirmation

import QtQuick 2.15
import QtQuick.Controls 2.15

Item {
    id: root
    anchors.fill: parent

    // On-screen keyboard handle, injected by parent (see SettingsView). When
    // null, TextInputs still receive focus but no on-screen keyboard appears —
    // simulator desktops still have hardware keyboards.
    property var keyboard: null

    // ── State ─────────────────────────────────────────────────────────────────
    property bool createSheetVisible: false
    property bool editScreenVisible:  false
    property int  editTargetIndex:    -1
    property bool deleteConfirmVisible: false

    // Creation fields
    property string newName:    ""
    property string newAvatar:  "🏎️"
    property string newAccent:  "#0A84FF"
    property int    newKeySlot: 0    // 0=none 1=key1 2=key2 3=both

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Header ────────────────────────────────────────────────────────────────
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 44
        color: "#000000"

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.1)
        }

        // Back button
        Rectangle {
            anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
            width: 36; height: 36; radius: 18; color: "transparent"
            Text {
                anchors.centerIn: parent
                text: "‹"
                color: "#0A84FF"
                font { pixelSize: 24; weight: 300 }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: root.visible = false
            }
        }

        Text {
            anchors.centerIn: parent
            text: "Driver Profiles"
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 16; weight: 600 }
        }

        // Add button (top-right)
        Rectangle {
            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            width: 60; height: 28; radius: 14
            color: "#0A84FF"

            Text {
                anchors.centerIn: parent
                text: "+ Add"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 12; weight: 600 }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    root.newName    = ""
                    root.newAvatar  = "🏎️"
                    root.newAccent  = "#0A84FF"
                    root.newKeySlot = 0
                    root.createSheetVisible = true
                }
            }
        }
    }

    // ── Profile Card Carousel ─────────────────────────────────────────────────
    Flickable {
        id: carousel
        anchors {
            top: header.bottom; topMargin: 12
            left: parent.left; leftMargin: 12
            right: parent.right; rightMargin: 12
        }
        height: 160
        contentWidth: carouselRow.implicitWidth
        contentHeight: height
        clip: true
        flickableDirection: Flickable.HorizontalFlick
        boundsMovement: Flickable.StopAtBounds

        Row {
            id: carouselRow
            spacing: 12
            height: carousel.height

            Repeater {
                model: ProfileService.profiles

                delegate: Rectangle {
                    id: cardRoot
                    width: 130
                    height: carousel.height
                    radius: 16
                    color: isActive ? accentCol : "#1C1C1E"
                    border {
                        color: isActive ? accentCol : Qt.rgba(1, 1, 1, 0.08)
                        width: isActive ? 2 : 1
                    }

                    // Glow on active card
                    layer.enabled: isActive
                    layer.effect: null   // no ShaderEffect to keep i686 compat

                    property bool   isActive:   index === ProfileService.activeProfileIndex
                    property string accentCol:  (modelData.accentColor || "#0A84FF")
                    property bool   isKid:      modelData.kidMode || false

                    Behavior on color { ColorAnimation { duration: 200 } }

                    Column {
                        anchors {
                            horizontalCenter: parent.horizontalCenter
                            top: parent.top; topMargin: 20
                        }
                        spacing: 8

                        // Avatar emoji
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.avatar || "🏎️"
                            font.pixelSize: 36
                        }

                        // Name
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.name || "Profile"
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 13; weight: 600 }
                            elide: Text.ElideRight
                            width: 110
                            horizontalAlignment: Text.AlignHCenter
                        }

                        // Key badge
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 4

                            Repeater {
                                model: modelData.keySlots || []
                                delegate: Rectangle {
                                    width: 36; height: 16; radius: 8
                                    color: Qt.rgba(1, 1, 1, 0.15)
                                    Text {
                                        anchors.centerIn: parent
                                        text: "Key " + modelData
                                        color: "#FFFFFF"
                                        font { family: "Roboto"; pixelSize: 9; weight: 500 }
                                    }
                                }
                            }
                        }

                        // Active badge
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: cardRoot.isActive
                            width: 52; height: 16; radius: 8
                            color: Qt.rgba(1, 1, 1, 0.25)
                            Text {
                                anchors.centerIn: parent
                                text: "Active"
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 9; weight: 600 }
                            }
                        }

                        // Kid Mode badge
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: cardRoot.isKid
                            width: 60; height: 16; radius: 8
                            color: Qt.rgba(1, 0.8, 0, 0.25)
                            Text {
                                anchors.centerIn: parent
                                text: "Kid Mode"
                                color: "#FFCC00"
                                font { family: "Roboto"; pixelSize: 9; weight: 600 }
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked:  ProfileService.switchProfile(index)
                        onPressAndHold: {
                            root.editTargetIndex = index
                            root.editScreenVisible = true
                        }
                    }
                }
            }

            // "Guest Mode" card (always last)
            Rectangle {
                width: 130
                height: carousel.height
                radius: 16
                color: "#1C1C1E"
                border { color: Qt.rgba(1, 1, 1, 0.08); width: 1 }

                Column {
                    anchors {
                        horizontalCenter: parent.horizontalCenter
                        top: parent.top; topMargin: 20
                    }
                    spacing: 8

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "👤"
                        font.pixelSize: 36
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Guest"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 13; weight: 600 }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "No data saved"
                        color: "#48484A"
                        font { family: "Roboto"; pixelSize: 10 }
                        width: 110
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: ProfileService.activateGuestMode()
                }
            }
        }
    }

    // ── Hint text ─────────────────────────────────────────────────────────────
    Text {
        anchors {
            top: carousel.bottom; topMargin: 6
            horizontalCenter: parent.horizontalCenter
        }
        text: "Tap to switch · Long press to edit"
        color: "#48484A"
        font { family: "Roboto"; pixelSize: 11 }
    }

    // ── Edit Screen (overlays this view) ─────────────────────────────────────
    ProfileEditScreen {
        id: editScreen
        anchors.fill: parent
        visible: root.editScreenVisible
        profileIndex: root.editTargetIndex
        onCloseRequested: root.editScreenVisible = false
        onDeleteRequested: {
            root.editScreenVisible = false
            root.deleteConfirmVisible = true
        }
    }

    // ── Delete confirmation dialog ────────────────────────────────────────────
    Rectangle {
        id: deleteOverlay
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: root.deleteConfirmVisible
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }

        Rectangle {
            anchors.centerIn: parent
            width: 300; height: 140; radius: 18
            color: "#1C1C1E"

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 22 }
                spacing: 18

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Delete profile?\nThis cannot be undone."
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 14 }
                    horizontalAlignment: Text.AlignHCenter
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12

                    Rectangle {
                        width: 110; height: 36; radius: 10; color: "#2C2C2E"
                        Text {
                            anchors.centerIn: parent
                            text: "Cancel"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 14; weight: 600 }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.deleteConfirmVisible = false
                        }
                    }

                    Rectangle {
                        width: 110; height: 36; radius: 10
                        color: "transparent"
                        border { color: "#FF453A"; width: 1.5 }
                        Text {
                            anchors.centerIn: parent
                            text: "Delete"
                            color: "#FF453A"
                            font { family: "Roboto"; pixelSize: 14; weight: 600 }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                ProfileService.deleteProfile(root.editTargetIndex)
                                root.deleteConfirmVisible = false
                                root.editTargetIndex = -1
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Profile Creation Bottom Sheet ─────────────────────────────────────────
    Rectangle {
        id: createSheet
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.72)
        visible: root.createSheetVisible
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }

        Rectangle {
            id: sheetBody
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: 300
            radius: 20
            color: "#1C1C1E"

            // Drag handle
            Rectangle {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 10 }
                width: 36; height: 4; radius: 2
                color: "#48484A"
            }

            Column {
                anchors { top: parent.top; topMargin: 28; left: parent.left; leftMargin: 20; right: parent.right; rightMargin: 20 }
                spacing: 14

                // Title
                Text {
                    text: "New Driver Profile"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 16; weight: 600 }
                }

                // Name input
                Rectangle {
                    width: parent.width; height: 40; radius: 10
                    color: "#2C2C2E"

                    TextInput {
                        id: nameInput
                        anchors { left: parent.left; leftMargin: 12; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        text: root.newName
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 14 }
                        inputMethodHints: Qt.ImhNoPredictiveText
                        onTextChanged: root.newName = text
                        // Surface the on-screen keyboard when this field gains
                        // focus — previously the field was tappable but no
                        // virtual keyboard appeared on the simulator/DCU.
                        onActiveFocusChanged: {
                            if (activeFocus && root.keyboard) root.keyboard.show(nameInput)
                        }
                        // Also raise on initial tap (some Qt builds don't
                        // re-fire activeFocusChanged on first focus).
                        MouseArea {
                            anchors.fill: parent
                            propagateComposedEvents: true
                            onClicked: function(m) {
                                nameInput.forceActiveFocus()
                                if (root.keyboard) root.keyboard.show(nameInput)
                                m.accepted = false   // let TextInput process the click too
                            }
                        }

                        Text {
                            anchors.fill: parent
                            text: "Your name"
                            color: "#48484A"
                            font: nameInput.font
                            verticalAlignment: Text.AlignVCenter
                            visible: nameInput.text.length === 0 && !nameInput.activeFocus
                        }
                    }
                }

                // Avatar emoji picker
                Column {
                    width: parent.width
                    spacing: 6
                    Text {
                        text: "Avatar"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1.2 }
                    }
                    Row {
                        spacing: 8
                        property var emojis: ["🏎️","🚀","⚡","🎵","🌊","🏔️","🌙","☀️","🎯","🔥","💙","🟢"]
                        Repeater {
                            model: parent.emojis
                            delegate: Rectangle {
                                width: 32; height: 32; radius: 8
                                color: root.newAvatar === modelData ? "#0A84FF" : "#2C2C2E"
                                Behavior on color { ColorAnimation { duration: 120 } }
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData
                                    font.pixelSize: 18
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.newAvatar = modelData
                                }
                            }
                        }
                    }
                }

                // Accent color swatches
                Column {
                    width: parent.width
                    spacing: 6
                    Text {
                        text: "Accent Color"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1.2 }
                    }
                    Row {
                        spacing: 10
                        property var accents: ["#0A84FF","#30D158","#FF9F0A","#FF453A","#BF5AF2","#64D2FF"]
                        Repeater {
                            model: parent.accents
                            delegate: Rectangle {
                                width: 28; height: 28; radius: 14
                                color: modelData
                                border { color: root.newAccent === modelData ? "#FFFFFF" : "transparent"; width: 2 }
                                Behavior on border.color { ColorAnimation { duration: 120 } }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.newAccent = modelData
                                }
                            }
                        }
                    }
                }

                // Key slot assignment
                Column {
                    width: parent.width
                    spacing: 6
                    Text {
                        text: "Key Fob Assignment"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1.2 }
                    }
                    Row {
                        spacing: 8
                        Repeater {
                            model: ["None","Key 1","Key 2","Both"]
                            delegate: Rectangle {
                                width: 60; height: 28; radius: 14
                                color: root.newKeySlot === index ? "#0A84FF" : "#2C2C2E"
                                Behavior on color { ColorAnimation { duration: 120 } }
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: root.newKeySlot === index ? "#FFFFFF" : "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 11; weight: 600 }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.newKeySlot = index
                                }
                            }
                        }
                    }
                }

                // Action buttons
                Row {
                    width: parent.width
                    spacing: 12

                    Rectangle {
                        width: (parent.width - 12) / 2; height: 40; radius: 12
                        color: "#2C2C2E"
                        Text {
                            anchors.centerIn: parent
                            text: "Cancel"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 14; weight: 600 }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.createSheetVisible = false
                        }
                    }

                    Rectangle {
                        width: (parent.width - 12) / 2; height: 40; radius: 12
                        color: root.newName.trim() !== "" ? "#0A84FF" : "#2C2C2E"
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text {
                            anchors.centerIn: parent
                            text: "Create"
                            color: root.newName.trim() !== "" ? "#FFFFFF" : "#48484A"
                            font { family: "Roboto"; pixelSize: 14; weight: 600 }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (root.newName.trim() === "") return
                                const slots = root.newKeySlot === 1 ? [1]
                                            : root.newKeySlot === 2 ? [2]
                                            : root.newKeySlot === 3 ? [1,2]
                                            : []
                                ProfileService.createProfile(root.newName.trim(), root.newAvatar, root.newAccent, slots)
                                root.createSheetVisible = false
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Inline: Profile Edit Screen ───────────────────────────────────────────
    component ProfileEditScreen: Item {
        property int profileIndex: -1
        signal closeRequested()
        signal deleteRequested()

        property var pdata: profileIndex >= 0 ? ProfileService.profileAt(profileIndex) : ({})

        Rectangle { anchors.fill: parent; color: "#000000" }

        Rectangle {
            id: editHeader
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 44
            color: "#000000"
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Qt.rgba(1, 1, 1, 0.1)
            }
            Rectangle {
                anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                width: 36; height: 36; radius: 18; color: "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "‹"
                    color: "#0A84FF"
                    font { pixelSize: 24; weight: 300 }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: closeRequested()
                }
            }
            Text {
                anchors.centerIn: parent
                text: "Edit Profile"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 16; weight: 600 }
            }
        }

        Flickable {
            anchors { top: editHeader.bottom; bottom: parent.bottom; left: parent.left; right: parent.right }
            contentHeight: editCol.implicitHeight + 24
            contentWidth: width
            clip: true
            boundsMovement: Flickable.StopAtBounds

            Column {
                id: editCol
                width: parent.width
                spacing: 0

                // ── Identity ──────────────────────────────────────────────────
                EditSection { label: "IDENTITY" }

                EditRow {
                    label: "Name"
                    valueText: pdata.name || ""
                    onValueEdited: (v) => ProfileService.setProfileField("", "name", v)
                }

                EditRow {
                    label: "Drive Mode Default"
                    valueText: ["Standard","Sport","Sport+","Eco","Snow","Personal"][pdata.drive ? (pdata.drive.defaultMode || 0) : 0]
                    onValueEdited: (v) => {}  // handled via pill selector below
                }

                // ── Climate ───────────────────────────────────────────────────
                EditSection { label: "CLIMATE" }

                EditTempRow {
                    label: "Driver Temp"
                    tempValue: pdata.climate ? (pdata.climate.driverTemp || 72) : 72
                    onTempChanged: (v) => ProfileService.setProfileField("climate", "driverTemp", v)
                }

                EditTempRow {
                    label: "Pass Temp"
                    tempValue: pdata.climate ? (pdata.climate.passTemp || 70) : 70
                    onTempChanged: (v) => ProfileService.setProfileField("climate", "passTemp", v)
                }

                EditToggleRow {
                    label: "Heated Wheel Auto"
                    checked: pdata.climate ? (pdata.climate.heatedWheel || false) : false
                    onToggled: (v) => ProfileService.setProfileField("climate", "heatedWheel", v)
                }

                // ── Audio ─────────────────────────────────────────────────────
                EditSection { label: "AUDIO" }

                EditSliderRow {
                    label: "Volume Default"
                    sliderValue: pdata.audio ? (pdata.audio.volume || 65) : 65
                    minVal: 0; maxVal: 100
                    onSliderChanged: (v) => ProfileService.setProfileField("audio", "volume", v)
                }

                EditToggleRow {
                    label: "AudioPilot (Bose)"
                    checked: pdata.audio ? (pdata.audio.audioPilot !== false) : true
                    onToggled: (v) => ProfileService.setProfileField("audio", "audioPilot", v)
                }

                // ── Navigation ────────────────────────────────────────────────
                EditSection { label: "NAVIGATION" }

                EditRow {
                    label: "Home Address"
                    valueText: pdata.nav ? (pdata.nav.homeAddress || "Not set") : "Not set"
                    onValueEdited: (v) => ProfileService.setProfileField("nav", "homeAddress", v)
                }

                EditRow {
                    label: "Work Address"
                    valueText: pdata.nav ? (pdata.nav.workAddress || "Not set") : "Not set"
                    onValueEdited: (v) => ProfileService.setProfileField("nav", "workAddress", v)
                }

                // ── Display ───────────────────────────────────────────────────
                EditSection { label: "DISPLAY" }

                EditSliderRow {
                    label: "Day Brightness"
                    sliderValue: pdata.display ? (pdata.display.brightness || 80) : 80
                    minVal: 10; maxVal: 100
                    onSliderChanged: (v) => ProfileService.setProfileField("display", "brightness", v)
                }

                EditSliderRow {
                    label: "Night Brightness"
                    sliderValue: pdata.display ? (pdata.display.nightBrightness || 30) : 30
                    minVal: 5; maxVal: 80
                    onSliderChanged: (v) => ProfileService.setProfileField("display", "nightBrightness", v)
                }

                // ── Safety / Privacy ─────────────────────────────────────────
                EditSection { label: "SAFETY & PRIVACY" }

                EditToggleRow {
                    label: "Kid Mode (70 mph alert)"
                    checked: pdata.kidMode || false
                    onToggled: (v) => ProfileService.setProfileField("", "kidMode", v)
                }

                EditToggleRow {
                    label: "PIN Lock"
                    checked: pdata.pinEnabled || false
                    onToggled: (v) => ProfileService.setProfileField("", "pinEnabled", v)
                }

                // ── Delete button ─────────────────────────────────────────────
                Item { width: 1; height: 16 }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 32; height: 40; radius: 12
                    color: "transparent"
                    border { color: "#FF453A"; width: 1.5 }
                    Text {
                        anchors.centerIn: parent
                        text: "Delete Profile"
                        color: "#FF453A"
                        font { family: "Roboto"; pixelSize: 14; weight: 600 }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: deleteRequested()
                    }
                }

                Item { width: 1; height: 24 }
            }
        }
    }

    // ── Sub-components used by edit screen ────────────────────────────────────

    component EditSection: Item {
        property string label: ""
        width: parent.width
        height: 32
        Text {
            anchors { left: parent.left; leftMargin: 16; bottom: parent.bottom; bottomMargin: 4 }
            text: label
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1.4 }
        }
    }

    component EditRow: Rectangle {
        id: editRowBase
        property string label: ""
        property string valueText: ""
        signal valueEdited(string value)

        width: parent.width; height: 46; color: "transparent"
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }
        Text {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            text: editRowBase.label
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 14 }
        }
        Text {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            text: editRowBase.valueText
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }
        }
    }

    component EditToggleRow: Rectangle {
        id: etBase
        property string label: ""
        property bool checked: false
        signal toggled(bool value)

        width: parent.width; height: 46; color: "transparent"
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }
        Text {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            text: etBase.label
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 14 }
        }
        Rectangle {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            width: 44; height: 24; radius: 12
            color: etBase.checked ? "#0A84FF" : "#2C2C2E"
            Behavior on color { ColorAnimation { duration: 150 } }
            Rectangle {
                width: 20; height: 20; radius: 10; color: "#FFFFFF"
                x: etBase.checked ? 22 : 2
                anchors.verticalCenter: parent.verticalCenter
                Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: etBase.toggled(!etBase.checked)
            }
        }
    }

    component EditTempRow: Rectangle {
        id: etempBase
        property string label: ""
        property int tempValue: 72
        signal tempChanged(int value)

        width: parent.width; height: 46; color: "transparent"
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }
        Text {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            text: etempBase.label
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 14 }
        }
        Row {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            spacing: 8
            Rectangle {
                width: 28; height: 28; radius: 8; color: "#2C2C2E"
                Text {
                    anchors.centerIn: parent; text: "−"
                    color: "#0A84FF"
                    font { pixelSize: 18; weight: 600 }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: etempBase.tempChanged(Math.max(60, etempBase.tempValue - 1))
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: etempBase.tempValue + "°F"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 14; weight: 600 }
                width: 44
                horizontalAlignment: Text.AlignHCenter
            }
            Rectangle {
                width: 28; height: 28; radius: 8; color: "#2C2C2E"
                Text {
                    anchors.centerIn: parent; text: "+"
                    color: "#0A84FF"
                    font { pixelSize: 16; weight: 600 }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: etempBase.tempChanged(Math.min(90, etempBase.tempValue + 1))
                }
            }
        }
    }

    component EditSliderRow: Rectangle {
        id: eslBase
        property string label: ""
        property int sliderValue: 50
        property int minVal: 0
        property int maxVal: 100
        signal sliderChanged(int value)

        width: parent.width; height: 54; color: "transparent"
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }
        Text {
            anchors { left: parent.left; leftMargin: 16; top: parent.top; topMargin: 8 }
            text: eslBase.label
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 14 }
        }
        Text {
            anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 8 }
            text: eslBase.sliderValue
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }
        }
        Slider {
            anchors {
                left: parent.left; leftMargin: 16
                right: parent.right; rightMargin: 16
                bottom: parent.bottom; bottomMargin: 6
            }
            height: 24
            from: eslBase.minVal; to: eslBase.maxVal
            value: eslBase.sliderValue
            stepSize: 1
            background: Rectangle {
                x: parent.leftPadding; y: parent.topPadding + parent.availableHeight / 2 - height / 2
                width: parent.availableWidth; height: 4; radius: 2; color: "#3A3A3C"
                Rectangle {
                    width: parent.parent.visualPosition * parent.width
                    height: parent.height; radius: 2; color: "#0A84FF"
                }
            }
            handle: Rectangle {
                x: parent.leftPadding + parent.visualPosition * (parent.availableWidth - width)
                y: parent.topPadding + parent.availableHeight / 2 - height / 2
                width: 20; height: 20; radius: 10; color: "#FFFFFF"
            }
            onMoved: eslBase.sliderChanged(Math.round(value))
        }
    }
}
