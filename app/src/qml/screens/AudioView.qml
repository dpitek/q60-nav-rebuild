// AudioView — Audio source selection and media control
// Layout mirrors original Q60 Clarion head-unit audio screen:
//   Row 1: source selector tabs (full-width segments, 46px)
//   Row 2: volume slider + EQ toggle (38px)
//   Row 3: tuner zone — seek/ch buttons flank the main info block (~222px)
//   Row 4: 6 large preset buttons pinned to bottom (54px)
//              BT uses row 4 for prev/play/next transport controls
// EQ panel slides up from below and overlays the tuner zone.
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    property bool eqPanelVisible: false
    property bool settingsPanelVisible: false
    property bool ascInfoVisible: false

    Rectangle { anchors.fill: parent; color: "#0A0A0A" }

    // ── Persisted ASC state sync ────────────────────────────────────────────
    // SettingsService.ascEnabled is the persisted "source of truth"; we mirror
    // it into VehicleService on load and on user toggle. This survives reboot.
    Component.onCompleted: {
        // Apply persisted ASC state at view-mount time. The Settings panel
        // toggle writes back to both services below.
        if (typeof SettingsService !== "undefined"
                && typeof VehicleService !== "undefined"
                && SettingsService.ascEnabled !== VehicleService.ascEnabled) {
            VehicleService.setAscEnabled(SettingsService.ascEnabled)
        }
    }
    Connections {
        target: SettingsService
        function onAscEnabledChanged() {
            if (VehicleService.ascEnabled !== SettingsService.ascEnabled)
                VehicleService.setAscEnabled(SettingsService.ascEnabled)
        }
    }

    // ── Row 1: Source tabs ──────────────────────────────────────────────────
    Item {
        id: sourceTabRow
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 46

        Rectangle { anchors.fill: parent; color: "#111111" }
        Rectangle {
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: 1; color: Qt.rgba(1, 1, 1, 0.1)
        }

        Row {
            anchors.fill: parent

            Repeater {
                model: [
                    { name: "BT",  src: 0 },
                    { name: "FM",  src: 1 },
                    { name: "AM",  src: 2 },
                    { name: "SXM", src: 3 },
                    { name: "AUX", src: 4 }
                ]

                delegate: Item {
                    width: sourceTabRow.width / 5
                    height: sourceTabRow.height
                    property bool isActive: AudioService.source === modelData.src

                    // Vertical divider between tabs
                    Rectangle {
                        anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
                        width: 1; color: Qt.rgba(1, 1, 1, 0.08)
                        visible: index < 4
                    }

                    Text {
                        anchors.centerIn: parent
                        text: modelData.name
                        color: isActive ? "#FFFFFF" : "#636366"
                        font {
                            family: "Roboto"
                            pixelSize: 14
                            weight: isActive ? Font.SemiBold : Font.Normal
                        }
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    // Active indicator bar
                    Rectangle {
                        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                        height: 3; color: "#0A84FF"
                        visible: isActive
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.eqPanelVisible = false
                            AudioService.setSource(modelData.src)
                        }
                    }
                }
            }
        }
    }

    // ── Row 2: Volume + EQ ──────────────────────────────────────────────────
    Item {
        id: volumeRow
        anchors { top: sourceTabRow.bottom; left: parent.left; right: parent.right }
        height: 38

        Rectangle { anchors.fill: parent; color: "#0D0D0D" }
        Rectangle {
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: 1; color: Qt.rgba(1, 1, 1, 0.08)
        }

        Row {
            anchors { verticalCenter: parent.verticalCenter; left: parent.left; right: parent.right;
                      leftMargin: 10; rightMargin: 10 }
            spacing: 8

            // Mute button
            Rectangle {
                width: 36; height: 28; radius: 6
                anchors.verticalCenter: parent.verticalCenter
                color: AudioService.muted ? Qt.rgba(1, 0.27, 0.23, 0.18) : "transparent"
                border {
                    color: AudioService.muted ? "#FF453A" : Qt.rgba(1, 1, 1, 0.14)
                    width: 1
                }
                Behavior on color { ColorAnimation { duration: 120 } }
                Text { anchors.centerIn: parent; text: AudioService.muted ? "🔇" : "🔊"; font.pixelSize: 14 }
                MouseArea { anchors.fill: parent; onClicked: AudioService.setMuted(!AudioService.muted) }
            }

            // Volume slider
            Item {
                // Fill remaining space: total - mute(36) - vol#(28) - eqBtn(44) - settingsBtn(32) - spacings(8*4=32)
                width: parent.width - 36 - 28 - 44 - 32 - 32
                height: parent.height
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width; height: 3; radius: 1.5; color: "#2C2C2E"
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * AudioService.volume / 100
                    height: 3; radius: 1.5
                    color: AudioService.muted ? "#3A3A3C" : "#0A84FF"
                    Behavior on width { NumberAnimation { duration: 80 } }
                }
                Rectangle {
                    x: (parent.width * AudioService.volume / 100) - 9
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18; height: 18; radius: 9
                    color: AudioService.muted ? "#3A3A3C" : "#FFFFFF"
                    Behavior on x { NumberAnimation { duration: 80 } }
                }
                MouseArea {
                    anchors.fill: parent
                    function setVol(mx) {
                        AudioService.setVolume(Math.max(0, Math.min(100, Math.round(mx / width * 100))))
                    }
                    onClicked: setVol(mouseX)
                    onPositionChanged: { if (pressed) setVol(mouseX) }
                }
            }

            // Volume number
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: AudioService.volume
                color: "#636366"
                font { family: "Roboto"; pixelSize: 12 }
                width: 22; horizontalAlignment: Text.AlignRight
            }

            // EQ button
            Rectangle {
                height: 26; width: 44; radius: 6
                anchors.verticalCenter: parent.verticalCenter
                color: root.eqPanelVisible ? Qt.rgba(0.04, 0.52, 1, 0.22) : "#1A1A1A"
                border {
                    color: root.eqPanelVisible ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.14)
                    width: 1
                }
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent; text: "EQ"
                    color: root.eqPanelVisible ? "#0A84FF" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.eqPanelVisible = !root.eqPanelVisible
                        if (root.eqPanelVisible) root.settingsPanelVisible = false
                    }
                }
            }

            // Settings (⚙) button — opens the Audio Settings slide-up panel
            // (currently houses the Active Sound Control toggle).
            Rectangle {
                height: 26; width: 32; radius: 6
                anchors.verticalCenter: parent.verticalCenter
                color: root.settingsPanelVisible ? Qt.rgba(0.04, 0.52, 1, 0.22) : "#1A1A1A"
                border {
                    color: root.settingsPanelVisible ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.14)
                    width: 1
                }
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent; text: "⚙"
                    color: root.settingsPanelVisible ? "#0A84FF" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 14 }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.settingsPanelVisible = !root.settingsPanelVisible
                        if (root.settingsPanelVisible) root.eqPanelVisible = false
                    }
                }
            }
        }
    }

    // ── Row 4: Preset / transport bar (anchored to bottom) ──────────────────
    Item {
        id: presetRow
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 54

        Rectangle { anchors.fill: parent; color: "#0D0D0D" }
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1; color: Qt.rgba(1, 1, 1, 0.12)
        }

        // ── FM presets ──
        Row {
            anchors.fill: parent
            visible: AudioService.source === 1
            Repeater {
                model: AudioService.fmPresets
                delegate: PresetButton {
                    preset: AudioService.fmPresets[index]
                    isActive: AudioService.activePresetIndex === index
                    isSxm: false
                    presetIndex: index
                    width: presetRow.width / AudioService.fmPresets.length
                    height: presetRow.height
                }
            }
        }

        // ── AM presets ──
        Row {
            anchors.fill: parent
            visible: AudioService.source === 2
            Repeater {
                model: AudioService.amPresets
                delegate: PresetButton {
                    preset: AudioService.amPresets[index]
                    isActive: AudioService.activePresetIndex === index
                    isSxm: false
                    presetIndex: index
                    width: presetRow.width / AudioService.amPresets.length
                    height: presetRow.height
                }
            }
        }

        // ── SXM presets ──
        Row {
            anchors.fill: parent
            visible: AudioService.source === 3
            Repeater {
                model: AudioService.sxmPresets
                delegate: PresetButton {
                    preset: AudioService.sxmPresets[index]
                    isActive: AudioService.activePresetIndex === index
                    isSxm: true
                    presetIndex: index
                    width: presetRow.width / AudioService.sxmPresets.length
                    height: presetRow.height
                }
            }
        }

        // ── BT transport ──
        Row {
            anchors.centerIn: parent
            spacing: 24
            visible: AudioService.source === 0

            Repeater {
                model: [
                    { icon: "⏮", action: "prev" },
                    { icon: "⏯", action: "play" },
                    { icon: "⏭", action: "next" }
                ]
                delegate: Rectangle {
                    width: 72; height: 42; radius: 10
                    anchors.verticalCenter: parent.verticalCenter
                    color: btBtn.pressed ? "#2C2C2E" : "#1A1A1A"
                    border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Text {
                        anchors.centerIn: parent
                        text: modelData.icon
                        color: modelData.action === "play" ? "#0A84FF" : "#FFFFFF"
                        font.pixelSize: 22
                    }
                    MouseArea {
                        id: btBtn; anchors.fill: parent
                        onClicked: {
                            if (modelData.action === "prev")      AudioService.btPrev()
                            else if (modelData.action === "play") AudioService.btPlay()
                            else                                   AudioService.btNext()
                        }
                    }
                }
            }
        }

        // ── AUX — empty ──
        Item { anchors.fill: parent; visible: AudioService.source === 4 }
    }

    // ── Row 3: Tuner / content zone ─────────────────────────────────────────
    Item {
        id: tunerZone
        anchors {
            top: volumeRow.bottom; bottom: presetRow.top
            left: parent.left; right: parent.right
        }

        // Source content
        Loader {
            anchors.fill: parent
            sourceComponent: {
                switch (AudioService.source) {
                case 0: return btContent
                case 1: return fmContent
                case 2: return amContent
                case 3: return sxmContent
                default: return auxContent
                }
            }
        }

        // ── EQ panel — slides up over tuner zone ─────────────────────────
        Rectangle {
            id: eqPanel
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: root.eqPanelVisible ? Math.min(parent.height, 210) : 0
            color: "#141414"; clip: true; z: 10
            Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            Rectangle {
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: 1; color: Qt.rgba(1, 1, 1, 0.14)
            }

            Column {
                anchors {
                    fill: parent
                    topMargin: 14; leftMargin: 12; rightMargin: 12; bottomMargin: 10
                }
                spacing: 10
                visible: root.eqPanelVisible && eqPanel.height > 50

                // Sliders
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 24

                    EqSlider { label: "BASS";    value: AudioService.bass;    minVal: -7; maxVal: 7; onMoved: (v) => AudioService.setBass(v) }
                    EqSlider { label: "TREBLE";  value: AudioService.treble;  minVal: -7; maxVal: 7; onMoved: (v) => AudioService.setTreble(v) }
                    EqSlider { label: "BALANCE"; value: AudioService.balance; minVal: -9; maxVal: 9; onMoved: (v) => AudioService.setBalance(v) }
                    EqSlider { label: "FADE";    value: AudioService.fade;    minVal: -9; maxVal: 9; onMoved: (v) => AudioService.setFade(v) }
                }

                // Bose DSP
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    BosePill { label: "AudioPilot";   active: AudioService.audioPilotOn;   onToggled: AudioService.setAudioPilot(!AudioService.audioPilotOn) }
                    BosePill { label: "Centerpoint";  active: AudioService.centerpointOn;  onToggled: AudioService.setCenterpoint(!AudioService.centerpointOn) }
                    BosePill { label: "Surround";     active: AudioService.surroundOn;     onToggled: AudioService.setSurround(!AudioService.surroundOn) }
                    BosePill { label: "Driver Stage"; active: AudioService.driverStageOn;  onToggled: AudioService.setDriverStage(!AudioService.driverStageOn) }
                }

                // Speed-sensitive volume
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Speed Vol"; color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 11 }
                        width: 60
                    }
                    Repeater {
                        model: [
                            { label: "Off", value: 0 }, { label: "1", value: 1 },
                            { label: "2",   value: 2 }, { label: "3", value: 3 },
                            { label: "4",   value: 4 }, { label: "5", value: 5 }
                        ]
                        delegate: Rectangle {
                            height: 26; radius: 6; width: ssvLbl.width + 16
                            color: AudioService.ssvLevel === modelData.value ? "#0A84FF" : "#2C2C2E"
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Text {
                                id: ssvLbl; anchors.centerIn: parent; text: modelData.label
                                color: AudioService.ssvLevel === modelData.value ? "#FFFFFF" : "#8E8E93"
                                font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
                            }
                            MouseArea { anchors.fill: parent; onClicked: AudioService.setSSVLevel(modelData.value) }
                        }
                    }
                }
            }
        }
    }

    // ── Settings panel — slides up over tuner zone ───────────────────────────
    // Currently houses the Active Sound Control (ASC) toggle. Keep additions
    // here tight — the Settings panel is intended to stay short.
    Rectangle {
        id: settingsPanel
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: root.settingsPanelVisible ? Math.min(parent.height, 138) : 0
        color: "#141414"; clip: true; z: 10
        Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1; color: Qt.rgba(1, 1, 1, 0.14)
        }

        Column {
            anchors {
                fill: parent
                topMargin: 14; leftMargin: 14; rightMargin: 14; bottomMargin: 12
            }
            spacing: 10
            visible: root.settingsPanelVisible && settingsPanel.height > 50

            // Header
            Text {
                text: "Audio Settings"
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 1.5 }
            }

            // ── ASC toggle row ───────────────────────────────────────────────
            Item {
                width: parent.width
                height: 44

                // Label + info button
                Row {
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Active Sound Control (Engine Sound Enhancement)"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13 }
                    }

                    // ⓘ hint button — opens brief explainer overlay
                    Rectangle {
                        width: 20; height: 20; radius: 10
                        anchors.verticalCenter: parent.verticalCenter
                        color: "transparent"
                        border { color: Qt.rgba(1, 1, 1, 0.28); width: 1 }
                        Text {
                            anchors.centerIn: parent; text: "i"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold; italic: true }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.ascInfoVisible = true
                        }
                    }
                }

                // Toggle pill — bound to VehicleService.ascEnabled, writes both services.
                Rectangle {
                    id: ascToggle
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    width: 52; height: 30; radius: 15
                    color: VehicleService.ascEnabled ? "#30D158" : "#3A3A3C"
                    Behavior on color { ColorAnimation { duration: 140 } }

                    Rectangle {
                        width: 26; height: 26; radius: 13; color: "#FFFFFF"
                        x: VehicleService.ascEnabled ? parent.width - width - 2 : 2
                        anchors.verticalCenter: parent.verticalCenter
                        Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            const next = !VehicleService.ascEnabled
                            VehicleService.setAscEnabled(next)
                            // Persist via SettingsService — survives reboot.
                            SettingsService.ascEnabled = next
                        }
                    }
                }
            }
        }
    }

    // ── ASC explainer overlay ────────────────────────────────────────────────
    Rectangle {
        id: ascInfoOverlay
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.78)
        visible: root.ascInfoVisible
        z: 100
        MouseArea { anchors.fill: parent; onClicked: root.ascInfoVisible = false }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 40, 380)
            height: Math.min(parent.height - 40, 160)
            radius: 12
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.14); width: 1 }
            MouseArea { anchors.fill: parent }  // swallow clicks inside the card

            Column {
                anchors { fill: parent; margins: 16 }
                spacing: 10

                Text {
                    text: "Active Sound Control"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 16; weight: Font.SemiBold }
                }
                Text {
                    width: parent.width
                    text: "Synthesized engine sound piped through speakers by Bose. " +
                          "Disable for natural V6 sound."
                    color: "#C7C7CC"
                    font { family: "Roboto"; pixelSize: 13 }
                    wrapMode: Text.WordWrap
                }
                Item { width: 1; height: 4 }
                Rectangle {
                    anchors.right: parent.right
                    width: 80; height: 30; radius: 8
                    color: "#0A84FF"
                    Text {
                        anchors.centerIn: parent; text: "OK"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.ascInfoVisible = false
                    }
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Tuner zone sub-components
    // ═══════════════════════════════════════════════════════════════════════════

    // ── FM ────────────────────────────────────────────────────────────────────
    Component {
        id: fmContent
        Item {
            // Left seek button
            Rectangle {
                id: fmSeekBack
                anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 }
                width: 84; height: 46; radius: 10
                color: fmSeekBackArea.pressed ? "#2C2C2E" : "#1A1A1A"
                border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }
                Behavior on color { ColorAnimation { duration: 100 } }
                Text { anchors.centerIn: parent; text: "◀◀"; color: "#0A84FF"; font.pixelSize: 17 }
                MouseArea { id: fmSeekBackArea; anchors.fill: parent; onClicked: AudioService.seekFM(false) }
            }

            // Right seek button
            Rectangle {
                id: fmSeekFwd
                anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 8 }
                width: 84; height: 46; radius: 10
                color: fmSeekFwdArea.pressed ? "#2C2C2E" : "#1A1A1A"
                border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }
                Behavior on color { ColorAnimation { duration: 100 } }
                Text { anchors.centerIn: parent; text: "▶▶"; color: "#0A84FF"; font.pixelSize: 17 }
                MouseArea { id: fmSeekFwdArea; anchors.fill: parent; onClicked: AudioService.seekFM(true) }
            }

            // Center info block
            Column {
                anchors {
                    verticalCenter: parent.verticalCenter
                    left: fmSeekBack.right; right: fmSeekFwd.left
                }
                spacing: 4

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "FM"
                    color: "#3A3A3C"
                    font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 2.5 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.fmFrequency.toFixed(1) + " MHz"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 34; weight: Font.Bold }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.fmStation
                    color: "#0A84FF"
                    font { family: "Roboto"; pixelSize: 15; weight: Font.SemiBold }
                    visible: AudioService.fmStation.length > 0
                    elide: Text.ElideRight
                    width: parent.width - 8
                    horizontalAlignment: Text.AlignHCenter
                }

                // RDS scrolling ticker
                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 8; height: 15; clip: true
                    visible: AudioService.rdsText.length > 0

                    Text {
                        id: fmRds
                        text: AudioService.rdsText
                        color: "#636366"
                        font { family: "Roboto"; pixelSize: 11 }
                        NumberAnimation on x {
                            from: parent.width; to: -fmRds.width
                            duration: Math.max(8000, fmRds.width * 22)
                            running: AudioService.rdsText.length > 0
                            loops: Animation.Infinite
                        }
                    }
                }
            }
        }
    }

    // ── AM ────────────────────────────────────────────────────────────────────
    Component {
        id: amContent
        Item {
            Rectangle {
                id: amSeekBack
                anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 }
                width: 84; height: 46; radius: 10
                color: amSeekBackArea.pressed ? "#2C2C2E" : "#1A1A1A"
                border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }
                Behavior on color { ColorAnimation { duration: 100 } }
                Text { anchors.centerIn: parent; text: "◀◀"; color: "#0A84FF"; font.pixelSize: 17 }
                MouseArea { id: amSeekBackArea; anchors.fill: parent; onClicked: AudioService.seekFM(false) }
            }

            Rectangle {
                id: amSeekFwd
                anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 8 }
                width: 84; height: 46; radius: 10
                color: amSeekFwdArea.pressed ? "#2C2C2E" : "#1A1A1A"
                border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }
                Behavior on color { ColorAnimation { duration: 100 } }
                Text { anchors.centerIn: parent; text: "▶▶"; color: "#0A84FF"; font.pixelSize: 17 }
                MouseArea { id: amSeekFwdArea; anchors.fill: parent; onClicked: AudioService.seekFM(true) }
            }

            Column {
                anchors {
                    verticalCenter: parent.verticalCenter
                    left: amSeekBack.right; right: amSeekFwd.left
                }
                spacing: 4

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "AM"; color: "#3A3A3C"
                    font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 2.5 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.fmFrequency.toFixed(0) + " kHz"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 34; weight: Font.Bold }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.fmStation; color: "#0A84FF"
                    font { family: "Roboto"; pixelSize: 15; weight: Font.SemiBold }
                    visible: AudioService.fmStation.length > 0
                    elide: Text.ElideRight
                    width: parent.width - 8
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }

    // ── SXM ───────────────────────────────────────────────────────────────────
    Component {
        id: sxmContent
        Item {
            // Channel down
            Rectangle {
                id: sxmChDown
                anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 }
                width: 84; height: 46; radius: 10
                color: sxmChDownArea.pressed ? "#2C2C2E" : "#1A1A1A"
                border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }
                Behavior on color { ColorAnimation { duration: 100 } }
                Column {
                    anchors.centerIn: parent; spacing: 0
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "◀"; color: "#0A84FF"; font.pixelSize: 15 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "CH"; color: "#636366";
                           font { family: "Roboto"; pixelSize: 9; letterSpacing: 1 } }
                }
                MouseArea {
                    id: sxmChDownArea; anchors.fill: parent
                    onClicked: {
                        var ch = parseInt(AudioService.sxmChannel) || 1
                        AudioService.setSXMChannel(Math.max(1, ch - 1))
                    }
                }
            }

            // Channel up
            Rectangle {
                id: sxmChUp
                anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 8 }
                width: 84; height: 46; radius: 10
                color: sxmChUpArea.pressed ? "#2C2C2E" : "#1A1A1A"
                border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }
                Behavior on color { ColorAnimation { duration: 100 } }
                Column {
                    anchors.centerIn: parent; spacing: 0
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "▶"; color: "#0A84FF"; font.pixelSize: 15 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "CH"; color: "#636366";
                           font { family: "Roboto"; pixelSize: 9; letterSpacing: 1 } }
                }
                MouseArea {
                    id: sxmChUpArea; anchors.fill: parent
                    onClicked: {
                        var ch = parseInt(AudioService.sxmChannel) || 1
                        AudioService.setSXMChannel(ch + 1)
                    }
                }
            }

            // Center block
            Column {
                anchors {
                    verticalCenter: parent.verticalCenter
                    left: sxmChDown.right; right: sxmChUp.left
                }
                spacing: 5

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "SIRIUSXM"; color: "#3A3A3C"
                    font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 2.5 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.sxmChannel.length > 0 ? "Ch. " + AudioService.sxmChannel : "—"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 32; weight: Font.Bold }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.sxmName
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 15; weight: Font.SemiBold }
                    visible: AudioService.sxmName.length > 0
                    elide: Text.ElideRight
                    width: parent.width - 8
                    horizontalAlignment: Text.AlignHCenter
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10

                    // Category pill
                    Rectangle {
                        height: 22; radius: 6; width: sxmCatLbl.width + 14
                        color: Qt.rgba(0.04, 0.52, 1, 0.18)
                        border { color: "#0A84FF"; width: 1 }
                        visible: AudioService.sxmCategory.length > 0
                        Text {
                            id: sxmCatLbl; anchors.centerIn: parent
                            text: AudioService.sxmCategory; color: "#0A84FF"
                            font { family: "Roboto"; pixelSize: 10; weight: Font.SemiBold }
                        }
                    }

                    // Signal dots
                    Row {
                        spacing: 4; anchors.verticalCenter: parent.verticalCenter
                        Repeater {
                            model: 5
                            delegate: Rectangle {
                                width: 7; height: 7; radius: 3.5
                                color: index < AudioService.sxmSignal ? "#30D158" : "#2C2C2E"
                                Behavior on color { ColorAnimation { duration: 150 } }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── BT ────────────────────────────────────────────────────────────────────
    Component {
        id: btContent
        Item {
            // Album art — left side, vertically centered
            Rectangle {
                id: albumArt
                anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 16 }
                width: Math.min(parent.height - 20, 100)
                height: width; radius: 10
                color: "#1A1A1A"
                border { color: Qt.rgba(1, 1, 1, 0.1); width: 1 }
                Text {
                    anchors.centerIn: parent; text: "♪"
                    color: "#3A3A3C"; font.pixelSize: 38
                }
            }

            // Track info — right of album art
            Column {
                anchors {
                    left: albumArt.right; right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: 14; rightMargin: 12
                }
                spacing: 4

                Text {
                    width: parent.width
                    text: AudioService.trackTitle.length > 0 ? AudioService.trackTitle : "—"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 17; weight: Font.SemiBold }
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: AudioService.trackArtist
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 13 }
                    elide: Text.ElideRight
                    visible: AudioService.trackArtist.length > 0
                }
                Text {
                    width: parent.width
                    text: AudioService.trackAlbum
                    color: "#636366"
                    font { family: "Roboto"; pixelSize: 11 }
                    elide: Text.ElideRight
                    visible: AudioService.trackAlbum.length > 0
                }

                Item { height: 4; width: 1 }

                // Connection status
                Row {
                    spacing: 6
                    Rectangle {
                        width: 7; height: 7; radius: 3.5
                        anchors.verticalCenter: parent.verticalCenter
                        color: AudioService.btConnected ? "#30D158" : "#3A3A3C"
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: AudioService.btConnected
                              ? (AudioService.btDeviceName.length > 0 ? AudioService.btDeviceName : "Bluetooth")
                              : "Not connected"
                        color: AudioService.btConnected ? "#8E8E93" : "#3A3A3C"
                        font { family: "Roboto"; pixelSize: 11 }
                    }
                }
            }
        }
    }

    // ── AUX ───────────────────────────────────────────────────────────────────
    Component {
        id: auxContent
        Column {
            anchors.centerIn: parent; spacing: 8
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "⇥"; color: "#2C2C2E"; font.pixelSize: 40 }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "AUX Input"; color: "#636366"
                font { family: "Roboto"; pixelSize: 18 }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Preset button (FM / AM / SXM)
    // ═══════════════════════════════════════════════════════════════════════════
    component PresetButton: Item {
        property var    preset:       null
        property bool   isActive:     false
        property bool   isSxm:        false
        property int    presetIndex:  0

        property bool   hasData: preset && preset.freq > 0

        // Vertical divider
        Rectangle {
            anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
            width: 1; color: Qt.rgba(1, 1, 1, 0.08)
            visible: presetIndex < (isSxm ? AudioService.sxmPresets.length : 5)
        }

        // Button background
        Rectangle {
            anchors.fill: parent
            color: isActive ? "#1A2A3A" : (presetArea.pressed ? "#1C1C1E" : "transparent")
            Behavior on color { ColorAnimation { duration: 120 } }
        }

        // Active left accent bar
        Rectangle {
            anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
            width: 3; color: "#0A84FF"
            visible: isActive
        }

        Column {
            anchors.centerIn: parent
            spacing: 2

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    if (!hasData) return (presetIndex + 1).toString()
                    if (isSxm)   return "Ch " + preset.freq.toFixed(0)
                    return preset.freq.toFixed(1)
                }
                color: hasData ? "#FFFFFF" : "#3A3A3C"
                font {
                    family: "Roboto"
                    pixelSize: hasData ? 13 : 15
                    weight: Font.SemiBold
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: preset && preset.name.length > 0 ? preset.name : ""
                color: isActive ? "#0A84FF" : "#636366"
                font { family: "Roboto"; pixelSize: 9; weight: Font.Medium }
                visible: preset && preset.name.length > 0
                elide: Text.ElideRight
                width: parent.width < 120 ? parent.width - 6 : 110
                horizontalAlignment: Text.AlignHCenter
            }
        }

        Timer {
            id: longPressTimer
            interval: 500; repeat: false
            onTriggered: AudioService.savePreset(presetIndex)
        }

        MouseArea {
            id: presetArea; anchors.fill: parent
            onPressed:  longPressTimer.start()
            onReleased: longPressTimer.stop()
            onClicked: {
                longPressTimer.stop()
                if (hasData) AudioService.recallPreset(presetIndex)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EQ helpers
    // ═══════════════════════════════════════════════════════════════════════════
    component EqSlider: Column {
        id: eqSliderRoot
        property string label: ""
        property int value: 0
        property int minVal: -7
        property int maxVal: 7
        signal moved(int v)

        width: 54; spacing: 4

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: eqSliderRoot.label; color: "#636366"
            font { family: "Roboto"; pixelSize: 9; weight: Font.SemiBold; letterSpacing: 0.5 }
        }

        Item {
            id: sliderTrack
            anchors.horizontalCenter: parent.horizontalCenter
            width: 28; height: 80

            property real range: eqSliderRoot.maxVal - eqSliderRoot.minVal
            property real fillRatio: (eqSliderRoot.value - eqSliderRoot.minVal) / range

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 0; width: 4; height: parent.height; radius: 2; color: "#1C1C1E"
            }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                property real ctr: sliderTrack.height / 2
                property real thumbY: sliderTrack.height * (1 - sliderTrack.fillRatio)
                y: Math.min(ctr, thumbY)
                width: 4; height: Math.abs(ctr - thumbY) + 1; radius: 2; color: "#0A84FF"
            }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: sliderTrack.height * (1 - sliderTrack.fillRatio) - 8
                width: 16; height: 16; radius: 8; color: "#FFFFFF"
                Behavior on y { NumberAnimation { duration: 80 } }
            }

            MouseArea {
                anchors.fill: parent
                function calcV(my) {
                    var r = 1.0 - Math.max(0, Math.min(1, my / sliderTrack.height))
                    return Math.round(r * sliderTrack.range + eqSliderRoot.minVal)
                }
                onClicked: eqSliderRoot.moved(calcV(mouseY))
                onPositionChanged: { if (pressed) eqSliderRoot.moved(calcV(mouseY)) }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: eqSliderRoot.value > 0 ? "+" + eqSliderRoot.value : eqSliderRoot.value.toString()
            color: eqSliderRoot.value !== 0 ? "#0A84FF" : "#636366"
            font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
        }
    }

    component BosePill: Rectangle {
        id: bosePillRoot
        property string label: ""
        property bool active: false
        signal toggled()

        height: 26; radius: 6; width: bosePillLbl.width + 18
        color: active ? Qt.rgba(0.04, 0.52, 1, 0.2) : "#1C1C1E"
        border { color: active ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.12); width: 1 }
        Behavior on color { ColorAnimation { duration: 120 } }

        Text {
            id: bosePillLbl; anchors.centerIn: parent; text: bosePillRoot.label
            color: bosePillRoot.active ? "#0A84FF" : "#8E8E93"
            font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
        }
        MouseArea { anchors.fill: parent; onClicked: bosePillRoot.toggled() }
    }
}
