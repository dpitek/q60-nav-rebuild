// AudioView — Audio source selection and media control
// Apple CarPlay aesthetic redesign
// Full feature parity: EQ/Bose panel, FM/AM/SXM presets, RDS text, BT album
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // EQ panel visibility state (scoped at root so volume row can toggle it)
    property bool eqPanelVisible: false

    // ── Source pills row (44px) ──────────────────────────────────────────────
    Row {
        id: sourceRow
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: 6
        }
        height: 44
        spacing: 8

        Repeater {
            model: [
                { name: "BT",  src: 0 },
                { name: "FM",  src: 1 },
                { name: "AM",  src: 2 },
                { name: "SXM", src: 3 },
                { name: "AUX", src: 4 }
            ]

            delegate: Rectangle {
                height: 36; radius: 18
                width: srcLabel.width + 32
                anchors.verticalCenter: parent.verticalCenter
                color: AudioService.source === modelData.src ? "#0A84FF" : "#1C1C1E"
                border {
                    color: AudioService.source === modelData.src
                           ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.15)
                    width: 1
                }
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                    id: srcLabel
                    anchors.centerIn: parent
                    text: modelData.name
                    color: AudioService.source === modelData.src ? "#FFFFFF" : "#8E8E93"
                    font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
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

    // ── Content area (between source row and volume row) ─────────────────────
    Item {
        id: contentArea
        anchors {
            top: sourceRow.bottom
            bottom: volumeRow.top
            left: parent.left; right: parent.right
            topMargin: 8; bottomMargin: 4
        }

        // Source content loader
        Loader {
            id: contentLoader
            anchors.fill: parent
            sourceComponent: {
                switch (AudioService.source) {
                case 0: return btComponent
                case 1: return fmComponent
                case 2: return amComponent
                case 3: return sxmComponent
                default: return auxComponent
                }
            }
        }

        // EQ panel — slides up from bottom of content area
        Rectangle {
            id: eqPanel
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: root.eqPanelVisible ? 200 : 0
            color: "#1C1C1E"
            radius: 16
            clip: true
            z: 10

            Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            // Top border accent
            Rectangle {
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: 1; color: Qt.rgba(1, 1, 1, 0.12)
            }

            Column {
                anchors {
                    top: parent.top; left: parent.left; right: parent.right
                    topMargin: 14; leftMargin: 14; rightMargin: 14
                }
                spacing: 10
                visible: root.eqPanelVisible && eqPanel.height > 60

                // ── EQ sliders ───────────────────────────────────────────────
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 22

                    // BASS
                    EqSlider {
                        label: "BASS"; value: AudioService.bass
                        minVal: -7; maxVal: 7
                        onMoved: (v) => AudioService.setBass(v)
                    }
                    // TREBLE
                    EqSlider {
                        label: "TREBLE"; value: AudioService.treble
                        minVal: -7; maxVal: 7
                        onMoved: (v) => AudioService.setTreble(v)
                    }
                    // BALANCE
                    EqSlider {
                        label: "BALANCE"; value: AudioService.balance
                        minVal: -9; maxVal: 9
                        onMoved: (v) => AudioService.setBalance(v)
                    }
                    // FADE
                    EqSlider {
                        label: "FADE"; value: AudioService.fade
                        minVal: -9; maxVal: 9
                        onMoved: (v) => AudioService.setFade(v)
                    }
                }

                // ── Bose DSP toggles ─────────────────────────────────────────
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    BosePill {
                        label: "AudioPilot"
                        active: AudioService.audioPilotOn
                        onToggled: AudioService.setAudioPilot(!AudioService.audioPilotOn)
                    }
                    BosePill {
                        label: "Centerpoint"
                        active: AudioService.centerpointOn
                        onToggled: AudioService.setCenterpoint(!AudioService.centerpointOn)
                    }
                    BosePill {
                        label: "Surround"
                        active: AudioService.surroundOn
                        onToggled: AudioService.setSurround(!AudioService.surroundOn)
                    }
                    BosePill {
                        label: "Driver Stage"
                        active: AudioService.driverStageOn
                        onToggled: AudioService.setDriverStage(!AudioService.driverStageOn)
                    }
                }

                // ── Speed-Sensitive Volume ────────────────────────────────────
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Speed Vol"
                        color: "#8E8E93"
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
                            height: 26; radius: 13; width: ssvLbl.width + 18
                            color: AudioService.ssvLevel === modelData.value ? "#0A84FF" : "#2C2C2E"
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text {
                                id: ssvLbl; anchors.centerIn: parent
                                text: modelData.label
                                color: AudioService.ssvLevel === modelData.value ? "#FFFFFF" : "#8E8E93"
                                font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: AudioService.setSSVLevel(modelData.value)
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Volume row (44px) ────────────────────────────────────────────────────
    Row {
        id: volumeRow
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 8
        }
        height: 44
        spacing: 10

        // Mute button
        Rectangle {
            width: 40; height: 40; radius: 20
            anchors.verticalCenter: parent.verticalCenter
            color: AudioService.muted ? Qt.rgba(1, 0.2706, 0.2275, 0.2) : "#1C1C1E"
            border {
                color: AudioService.muted ? "#FF453A" : Qt.rgba(1, 1, 1, 0.15)
                width: 1
            }
            Behavior on color { ColorAnimation { duration: 150 } }
            Text { anchors.centerIn: parent; text: AudioService.muted ? "🔇" : "🔊"; font.pixelSize: 17 }
            MouseArea { anchors.fill: parent; onClicked: AudioService.setMuted(!AudioService.muted) }
        }

        // Volume slider
        Item {
            width: 200; height: 44
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width; height: 4; radius: 2; color: "#2C2C2E"
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * AudioService.volume / 100
                height: 4; radius: 2; color: "#0A84FF"
                Behavior on width { NumberAnimation { duration: 80 } }
            }
            Rectangle {
                x: (parent.width * AudioService.volume / 100) - 10
                anchors.verticalCenter: parent.verticalCenter
                width: 20; height: 20; radius: 10; color: "#FFFFFF"
                Behavior on x { NumberAnimation { duration: 80 } }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: AudioService.setVolume(Math.round(mouseX / width * 100))
                onPositionChanged: {
                    if (pressed)
                        AudioService.setVolume(Math.max(0, Math.min(100,
                            Math.round(mouseX / width * 100))))
                }
            }
        }

        // Volume label
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: AudioService.volume + "%"
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }
            width: 38; horizontalAlignment: Text.AlignRight
        }

        // EQ toggle pill
        Rectangle {
            height: 32; radius: 16; width: eqPillLbl.width + 24
            anchors.verticalCenter: parent.verticalCenter
            color: root.eqPanelVisible ? Qt.rgba(0.0392, 0.5176, 1, 0.25) : "#1C1C1E"
            border { color: root.eqPanelVisible ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.15); width: 1 }
            Behavior on color { ColorAnimation { duration: 150 } }
            Text {
                id: eqPillLbl; anchors.centerIn: parent; text: "EQ"
                color: root.eqPanelVisible ? "#0A84FF" : "#8E8E93"
                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
            }
            MouseArea { anchors.fill: parent; onClicked: root.eqPanelVisible = !root.eqPanelVisible }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Source sub-components
    // ═══════════════════════════════════════════════════════════════════════════

    // ── BT ───────────────────────────────────────────────────────────────────
    Component {
        id: btComponent
        Column {
            anchors.centerIn: parent
            spacing: 11

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 96; height: 96; radius: 16
                color: "#1C1C1E"
                border { color: Qt.rgba(1, 1, 1, 0.1); width: 1 }
                Text { anchors.centerIn: parent; text: "♪"; color: "#3A3A3C"; font.pixelSize: 42 }
            }

            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 3

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.trackTitle.length > 0 ? AudioService.trackTitle : "—"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 19; weight: Font.SemiBold }
                    width: 280; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.trackArtist
                    color: "#8E8E93"; font { family: "Roboto"; pixelSize: 14 }
                    width: 280; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.trackAlbum
                    color: "#636366"; font { family: "Roboto"; pixelSize: 12 }
                    width: 280; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                    visible: AudioService.trackAlbum.length > 0
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 16

                Repeater {
                    model: [
                        { icon: "⏮", slot: "prev" },
                        { icon: "⏯", slot: "play" },
                        { icon: "⏭", slot: "next" }
                    ]
                    delegate: Rectangle {
                        width: 50; height: 50; radius: 25
                        color: btBtn.pressed ? "#2C2C2E" : "#1C1C1E"
                        border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Text {
                            anchors.centerIn: parent; text: modelData.icon
                            color: modelData.slot === "play" ? "#0A84FF" : "#FFFFFF"
                            font.pixelSize: 20
                        }
                        MouseArea {
                            id: btBtn; anchors.fill: parent
                            onClicked: {
                                if (modelData.slot === "prev")      AudioService.btPrev()
                                else if (modelData.slot === "play") AudioService.btPlay()
                                else                                AudioService.btNext()
                            }
                        }
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.btConnected
                      ? "● " + (AudioService.btDeviceName.length > 0
                                ? AudioService.btDeviceName : "Bluetooth")
                      : "○  Not connected"
                color: AudioService.btConnected ? "#8E8E93" : "#3A3A3C"
                font { family: "Roboto"; pixelSize: 12 }
            }
        }
    }

    // ── FM ───────────────────────────────────────────────────────────────────
    Component {
        id: fmComponent
        Column {
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 6 }
            spacing: 7

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "FM"; color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 2 }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.fmFrequency.toFixed(1) + " MHz"
                color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 30; weight: Font.Bold }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.fmStation; color: "#0A84FF"
                font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                visible: AudioService.fmStation.length > 0
            }

            // RDS scrolling text
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 340; height: 16; clip: true
                visible: AudioService.rdsText.length > 0
                Text {
                    id: fmRds; text: AudioService.rdsText; color: "#636366"
                    font { family: "Roboto"; pixelSize: 11 }
                    NumberAnimation on x {
                        from: 340; to: -fmRds.width
                        duration: Math.max(6000, fmRds.width * 20)
                        running: AudioService.rdsText.length > 0
                        loops: Animation.Infinite
                    }
                }
            }

            // Seek buttons
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 18

                Repeater {
                    model: [{ icon: "◀◀", fwd: false }, { icon: "▶▶", fwd: true }]
                    delegate: Rectangle {
                        width: 72; height: 38; radius: 19
                        color: fmSeek.pressed ? "#2C2C2E" : "#1C1C1E"
                        border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }
                        Text { anchors.centerIn: parent; text: modelData.icon; color: "#0A84FF"; font.pixelSize: 15 }
                        MouseArea { id: fmSeek; anchors.fill: parent; onClicked: AudioService.seekFM(modelData.fwd) }
                    }
                }
            }

            // FM Preset pills
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6

                Repeater {
                    model: AudioService.fmPresets
                    delegate: Rectangle {
                        property var preset: AudioService.fmPresets[index]
                        property bool isActive: AudioService.activePresetIndex === index
                        property bool hasFreq: preset && preset.freq > 0

                        height: 34; radius: 17
                        width: presetContent.width + 20
                        color: isActive ? "#0A84FF" : "#1C1C1E"
                        border {
                            color: isActive ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.2); width: 1
                        }
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Column {
                            id: presetContent
                            anchors.centerIn: parent
                            spacing: 1

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: hasFreq ? preset.freq.toFixed(1) : (index + 1).toString()
                                color: isActive ? "#FFFFFF" : (hasFreq ? "#FFFFFF" : "#636366")
                                font { family: "Roboto"; pixelSize: hasFreq ? 11 : 13; weight: Font.SemiBold }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: preset && preset.name.length > 0 ? preset.name : ""
                                color: isActive ? Qt.rgba(1, 1, 1, 0.85) : "#8E8E93"
                                font { family: "Roboto"; pixelSize: 9 }
                                visible: preset && preset.name.length > 0
                            }
                        }

                        Timer {
                            id: fmLongPress
                            interval: 500; repeat: false
                            onTriggered: AudioService.savePreset(index)
                        }

                        MouseArea {
                            anchors.fill: parent
                            onPressed: fmLongPress.start()
                            onReleased: fmLongPress.stop()
                            onClicked: {
                                fmLongPress.stop()
                                if (hasFreq) AudioService.recallPreset(index)
                            }
                        }
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Hold preset to save"
                color: "#636366"; font { family: "Roboto"; pixelSize: 10 }
            }
        }
    }

    // ── AM ───────────────────────────────────────────────────────────────────
    Component {
        id: amComponent
        Column {
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 6 }
            spacing: 7

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "AM"; color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 2 }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.fmFrequency.toFixed(0) + " kHz"
                color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 30; weight: Font.Bold }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.fmStation; color: "#0A84FF"
                font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                visible: AudioService.fmStation.length > 0
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 18

                Repeater {
                    model: [{ icon: "◀◀", fwd: false }, { icon: "▶▶", fwd: true }]
                    delegate: Rectangle {
                        width: 72; height: 38; radius: 19
                        color: amSeek.pressed ? "#2C2C2E" : "#1C1C1E"
                        border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }
                        Text { anchors.centerIn: parent; text: modelData.icon; color: "#0A84FF"; font.pixelSize: 15 }
                        MouseArea { id: amSeek; anchors.fill: parent; onClicked: AudioService.seekFM(modelData.fwd) }
                    }
                }
            }

            // AM Preset pills
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6

                Repeater {
                    model: AudioService.amPresets
                    delegate: Rectangle {
                        property var preset: AudioService.amPresets[index]
                        property bool isActive: AudioService.activePresetIndex === index
                        property bool hasFreq: preset && preset.freq > 0

                        height: 34; radius: 17; width: amPresetContent.width + 20
                        color: isActive ? "#0A84FF" : "#1C1C1E"
                        border { color: isActive ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.2); width: 1 }
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Column {
                            id: amPresetContent; anchors.centerIn: parent; spacing: 1

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: hasFreq ? preset.freq.toFixed(0) : (index + 1).toString()
                                color: isActive ? "#FFFFFF" : (hasFreq ? "#FFFFFF" : "#636366")
                                font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: preset && preset.name.length > 0 ? preset.name : ""
                                color: isActive ? Qt.rgba(1, 1, 1, 0.85) : "#8E8E93"
                                font { family: "Roboto"; pixelSize: 9 }
                                visible: preset && preset.name.length > 0
                            }
                        }

                        Timer {
                            id: amLongPress; interval: 500; repeat: false
                            onTriggered: AudioService.savePreset(index)
                        }
                        MouseArea {
                            anchors.fill: parent
                            onPressed: amLongPress.start()
                            onReleased: amLongPress.stop()
                            onClicked: { amLongPress.stop(); if (hasFreq) AudioService.recallPreset(index) }
                        }
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Hold preset to save"
                color: "#636366"; font { family: "Roboto"; pixelSize: 10 }
            }
        }
    }

    // ── SXM ──────────────────────────────────────────────────────────────────
    Component {
        id: sxmComponent
        Column {
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 6 }
            spacing: 7

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "SiriusXM"; color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 2 }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.sxmChannel.length > 0 ? "Ch. " + AudioService.sxmChannel : "—"
                color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 28; weight: Font.Bold }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.sxmName.length > 0 ? AudioService.sxmName : ""
                color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 18; weight: Font.SemiBold }
                width: 300; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                visible: AudioService.sxmName.length > 0
            }

            // Category pill + signal dots
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12

                Rectangle {
                    height: 24; radius: 12; width: sxmCatLbl.width + 16
                    color: Qt.rgba(0.0392, 0.5176, 1, 0.2)
                    border { color: "#0A84FF"; width: 1 }
                    visible: AudioService.sxmCategory.length > 0
                    Text {
                        id: sxmCatLbl; anchors.centerIn: parent
                        text: AudioService.sxmCategory; color: "#0A84FF"
                        font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold }
                    }
                }

                Row {
                    spacing: 4; anchors.verticalCenter: parent.verticalCenter
                    Repeater {
                        model: 5
                        delegate: Rectangle {
                            width: 8; height: 8; radius: 4
                            color: index < AudioService.sxmSignal ? "#30D158" : "#3A3A3C"
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }
                    }
                }
            }

            // Channel ± buttons
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 22

                Repeater {
                    model: [{ icon: "◀", delta: -1 }, { icon: "▶", delta: 1 }]
                    delegate: Rectangle {
                        width: 62; height: 38; radius: 19
                        color: sxmChBtn.pressed ? "#2C2C2E" : "#1C1C1E"
                        border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }
                        Text { anchors.centerIn: parent; text: modelData.icon; color: "#0A84FF"; font.pixelSize: 17 }
                        MouseArea {
                            id: sxmChBtn; anchors.fill: parent
                            onClicked: {
                                var ch = parseInt(AudioService.sxmChannel) || 1
                                AudioService.setSXMChannel(Math.max(1, ch + modelData.delta))
                            }
                        }
                    }
                }
            }

            // SXM Preset pills
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6

                Repeater {
                    model: AudioService.sxmPresets
                    delegate: Rectangle {
                        property var preset: AudioService.sxmPresets[index]
                        property bool isActive: AudioService.activePresetIndex === index
                        property bool hasFreq: preset && preset.freq > 0

                        height: 34; radius: 17; width: sxmPresetContent.width + 20
                        color: isActive ? "#0A84FF" : "#1C1C1E"
                        border { color: isActive ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.2); width: 1 }
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Column {
                            id: sxmPresetContent; anchors.centerIn: parent; spacing: 1

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: hasFreq ? "Ch." + preset.freq.toFixed(0) : (index + 1).toString()
                                color: isActive ? "#FFFFFF" : (hasFreq ? "#FFFFFF" : "#636366")
                                font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: preset && preset.name.length > 0 ? preset.name : ""
                                color: isActive ? Qt.rgba(1, 1, 1, 0.85) : "#8E8E93"
                                font { family: "Roboto"; pixelSize: 9 }
                                visible: preset && preset.name.length > 0
                            }
                        }

                        Timer {
                            id: sxmLongPress; interval: 500; repeat: false
                            onTriggered: AudioService.savePreset(index)
                        }
                        MouseArea {
                            anchors.fill: parent
                            onPressed: sxmLongPress.start()
                            onReleased: sxmLongPress.stop()
                            onClicked: { sxmLongPress.stop(); if (hasFreq) AudioService.recallPreset(index) }
                        }
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Hold preset to save"
                color: "#636366"; font { family: "Roboto"; pixelSize: 10 }
            }
        }
    }

    // ── AUX ──────────────────────────────────────────────────────────────────
    Component {
        id: auxComponent
        Column {
            anchors.centerIn: parent; spacing: 8
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "⇥"; color: "#3A3A3C"; font.pixelSize: 48 }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "AUX Input"; color: "#8E8E93"
                   font { family: "Roboto"; pixelSize: 22 } }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EQ helper components (inline, referenced in EQ panel above)
    // ═══════════════════════════════════════════════════════════════════════════

    component EqSlider: Column {
        id: eqSliderRoot
        property string label: ""
        property int value: 0
        property int minVal: -7
        property int maxVal: 7
        signal moved(int v)

        width: 52; spacing: 4

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: eqSliderRoot.label; color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 9; weight: Font.SemiBold; letterSpacing: 0.5 }
        }

        Item {
            id: sliderTrack
            anchors.horizontalCenter: parent.horizontalCenter
            width: 28; height: 84

            property real range: eqSliderRoot.maxVal - eqSliderRoot.minVal
            property real fillRatio: (eqSliderRoot.value - eqSliderRoot.minVal) / range

            // Track background
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 0; width: 4; height: parent.height; radius: 2; color: "#2C2C2E"
            }
            // Blue fill from center
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                property real ctr: sliderTrack.height / 2
                property real thumbY: sliderTrack.height * (1 - sliderTrack.fillRatio)
                y: Math.min(ctr, thumbY)
                width: 4; height: Math.abs(ctr - thumbY) + 1; radius: 2; color: "#0A84FF"
            }
            // Thumb
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: sliderTrack.height * (1 - sliderTrack.fillRatio) - 8
                width: 16; height: 16; radius: 8; color: "#FFFFFF"
                Behavior on y { NumberAnimation { duration: 80 } }
            }

            MouseArea {
                anchors.fill: parent
                function calcV(my) {
                    var ratio = 1.0 - Math.max(0, Math.min(1, my / sliderTrack.height))
                    return Math.round(ratio * sliderTrack.range + eqSliderRoot.minVal)
                }
                onClicked: eqSliderRoot.moved(calcV(mouseY))
                onPositionChanged: { if (pressed) eqSliderRoot.moved(calcV(mouseY)) }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: eqSliderRoot.value > 0 ? "+" + eqSliderRoot.value : eqSliderRoot.value.toString()
            color: eqSliderRoot.value !== 0 ? "#0A84FF" : "#8E8E93"
            font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
        }
    }

    component BosePill: Rectangle {
        id: bosePillRoot
        property string label: ""
        property bool active: false
        signal toggled()

        height: 28; radius: 14; width: bosePillLbl.width + 20
        color: active ? Qt.rgba(0.0392, 0.5176, 1, 0.2) : "#2C2C2E"
        border { color: active ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.15); width: 1 }
        Behavior on color { ColorAnimation { duration: 150 } }

        Text {
            id: bosePillLbl; anchors.centerIn: parent; text: bosePillRoot.label
            color: bosePillRoot.active ? "#0A84FF" : "#8E8E93"
            font { family: "Roboto"; pixelSize: 11; weight: Font.Medium }
        }
        MouseArea { anchors.fill: parent; onClicked: bosePillRoot.toggled() }
    }
}
