// AudioView — Audio source selection and media control
// Apple CarPlay aesthetic redesign
// All AudioService bindings preserved exactly.
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Source pills ────────────────────────────────────────────────────────
    Row {
        id: sourceRow
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: 16
        }
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
                color: AudioService.source === modelData.src ? "#0A84FF" : "#1C1C1E"
                border {
                    color: AudioService.source === modelData.src
                           ? "#0A84FF" : "rgba(255,255,255,0.15)"
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
                    onClicked: AudioService.setSource(modelData.src)
                }
            }
        }
    }

    // ── Content area ────────────────────────────────────────────────────────
    Loader {
        id: contentLoader
        anchors {
            top: sourceRow.bottom
            bottom: volumeRow.top
            left: parent.left; right: parent.right
            topMargin: 12; bottomMargin: 12
        }
        sourceComponent: {
            switch (AudioService.source) {
            case 0: return btComponent
            case 1: return fmComponent
            case 2: return fmComponent
            case 3: return sxmComponent
            default: return auxComponent
            }
        }
    }

    // ── Volume row ──────────────────────────────────────────────────────────
    Row {
        id: volumeRow
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 16
        }
        spacing: 12

        // Mute button
        Rectangle {
            width: 44; height: 44; radius: 22
            color: AudioService.muted
                   ? "rgba(255,69,58,0.2)" : "#1C1C1E"
            border {
                color: AudioService.muted ? "#FF453A" : "rgba(255,255,255,0.15)"
                width: 1
            }

            Text {
                anchors.centerIn: parent
                text: AudioService.muted ? "🔇" : "🔊"
                font.pixelSize: 18
            }

            MouseArea {
                anchors.fill: parent
                onClicked: AudioService.setMuted(!AudioService.muted)
            }
        }

        // Slider track
        Item {
            width: 220; height: 44
            anchors.verticalCenter: parent.verticalCenter

            // Track bg
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width; height: 4; radius: 2
                color: "#2C2C2E"
            }

            // Fill
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * AudioService.volume / 100
                height: 4; radius: 2
                color: "#0A84FF"
                Behavior on width { NumberAnimation { duration: 80 } }
            }

            // Thumb
            Rectangle {
                x: (parent.width * AudioService.volume / 100) - 10
                anchors.verticalCenter: parent.verticalCenter
                width: 20; height: 20; radius: 10
                color: "#FFFFFF"
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

        // Volume value
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: AudioService.volume + "%"
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }
            width: 44
            horizontalAlignment: Text.AlignRight
        }
    }

    // ── Source sub-components ────────────────────────────────────────────────

    // BT component
    Component {
        id: btComponent
        Column {
            anchors.centerIn: parent
            spacing: 16

            // Album art placeholder
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 120; height: 120; radius: 16
                color: "#1C1C1E"
                border { color: "rgba(255,255,255,0.1)"; width: 1 }

                Text {
                    anchors.centerIn: parent
                    text: "♪"
                    color: "#3A3A3C"
                    font { pixelSize: 52 }
                }
            }

            // Track / artist
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 4

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.trackTitle.length > 0 ? AudioService.trackTitle : "—"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 22; weight: Font.SemiBold }
                    width: 300; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: AudioService.trackArtist.length > 0 ? AudioService.trackArtist : ""
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 17 }
                    width: 300; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                }
            }

            // Transport controls
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 20

                Repeater {
                    model: [
                        { icon: "⏮", slot: "prev" },
                        { icon: "⏯", slot: "play" },
                        { icon: "⏭", slot: "next" }
                    ]
                    delegate: Rectangle {
                        width: 56; height: 56; radius: 28
                        color: tma.pressed ? "#2C2C2E" : "#1C1C1E"
                        border { color: "rgba(255,255,255,0.15)"; width: 1 }

                        Behavior on color { ColorAnimation { duration: 100 } }

                        Text {
                            anchors.centerIn: parent
                            text: modelData.icon
                            color: modelData.slot === "play" ? "#0A84FF" : "#FFFFFF"
                            font { pixelSize: 24 }
                        }

                        MouseArea {
                            id: tma; anchors.fill: parent
                            onClicked: {
                                if (modelData.slot === "prev")      AudioService.btPrev()
                                else if (modelData.slot === "play") AudioService.btPlay()
                                else                                AudioService.btNext()
                            }
                        }
                    }
                }
            }

            // BT device footer
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.btConnected ? "● " + "Bluetooth" : "○  Not connected"
                color: AudioService.btConnected ? "#8E8E93" : "#3A3A3C"
                font { family: "Roboto"; pixelSize: 13 }
            }
        }
    }

    // FM / AM component
    Component {
        id: fmComponent
        Column {
            anchors.centerIn: parent
            spacing: 14

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.source === 1 ? "FM" : "AM"
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 2 }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.source === 1
                      ? AudioService.fmFrequency.toFixed(1) + " MHz"
                      : AudioService.fmFrequency.toFixed(0) + " kHz"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 34; weight: Font.Bold }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.fmStation.length > 0 ? AudioService.fmStation : ""
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 17 }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 24

                Repeater {
                    model: [{ icon: "◀◀", fwd: false }, { icon: "▶▶", fwd: true }]
                    delegate: Rectangle {
                        width: 80; height: 48; radius: 24
                        color: fm2.pressed ? "#2C2C2E" : "#1C1C1E"
                        border { color: "rgba(255,255,255,0.15)"; width: 1 }

                        Text { anchors.centerIn: parent; text: modelData.icon; color: "#0A84FF"; font.pixelSize: 18 }
                        MouseArea {
                            id: fm2; anchors.fill: parent
                            onClicked: AudioService.seekFM(modelData.fwd)
                        }
                    }
                }
            }
        }
    }

    // SiriusXM component
    Component {
        id: sxmComponent
        Column {
            anchors.centerIn: parent
            spacing: 12

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "SiriusXM"
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 11; capitalization: Font.AllUppercase; letterSpacing: 2 }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.sxmName.length > 0 ? AudioService.sxmName : "—"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 28; weight: Font.SemiBold }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.sxmChannel.length > 0 ? "Ch. " + AudioService.sxmChannel : ""
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 15 }
            }
        }
    }

    // AUX component
    Component {
        id: auxComponent
        Column {
            anchors.centerIn: parent
            spacing: 8

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "⇥"
                color: "#3A3A3C"
                font { pixelSize: 48 }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "AUX Input"
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 22 }
            }
        }
    }
}
