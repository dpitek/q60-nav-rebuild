// AudioView — Audio source selection and media control
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#080d12" }

    // ── Source selector ──────────────────────────────────────────────────
    Row {
        id: sourceRow
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: 20
        }
        spacing: 10

        Repeater {
            model: [
                { name: "BT",  src: 0 },
                { name: "FM",  src: 1 },
                { name: "AM",  src: 2 },
                { name: "SXM", src: 3 },
                { name: "AUX", src: 4 }
            ]
            delegate: Rectangle {
                width: 58; height: 38; radius: 8
                color: AudioService.source === modelData.src ? "#0d2a4a" : "#0e1520"
                border {
                    color: AudioService.source === modelData.src ? "#00d4ff" : "#1e2a3a"
                    width: 1
                }
                Text {
                    anchors.centerIn: parent
                    text: modelData.name
                    color: AudioService.source === modelData.src ? "#00d4ff" : "#555"
                    font { pixelSize: 13; weight: Font.Bold }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: AudioService.setSource(modelData.src)
                }
            }
        }
    }

    // ── Content area — changes based on source ───────────────────────────
    Loader {
        id: contentLoader
        anchors {
            top: sourceRow.bottom
            bottom: volumeRow.top
            left: parent.left; right: parent.right
            margins: 20
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

    // ── Volume bar ───────────────────────────────────────────────────────
    Row {
        id: volumeRow
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 20
        }
        spacing: 16

        Rectangle {
            width: 48; height: 48; radius: 8
            color: AudioService.muted ? "#2a0d0d" : "#0e1520"
            border { color: AudioService.muted ? "#ff4444" : "#1e2a3a"; width: 1 }
            Text {
                anchors.centerIn: parent
                text: AudioService.muted ? "🔇" : "🔊"
                font.pixelSize: 22
            }
            MouseArea {
                anchors.fill: parent
                onClicked: AudioService.setMuted(!AudioService.muted)
            }
        }

        Item {
            width: 200; height: 48
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width; height: 6; radius: 3
                color: "#1e2a3a"
                Rectangle {
                    width: parent.width * AudioService.volume / 100
                    height: parent.height; radius: 3
                    color: "#00d4ff"
                }
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

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: AudioService.volume + "%"
            color: "#888"; font.pixelSize: 14; width: 40
        }
    }

    // ── Source sub-components ────────────────────────────────────────────
    Component {
        id: btComponent
        Column {
            anchors.centerIn: parent
            spacing: 16

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.btConnected ? "● CONNECTED" : "○ Not connected"
                color: AudioService.btConnected ? "#00d4ff" : "#555"
                font { pixelSize: 12; capitalization: Font.AllUppercase }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.trackTitle.length > 0 ? AudioService.trackTitle : "—"
                color: "#f0f0f0"
                font { pixelSize: 22; weight: Font.Light }
                width: 280; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: AudioService.trackArtist
                color: "#888"; font.pixelSize: 14
                width: 280; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
            }
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
                        color: ma.pressed ? "#1a3a5a" : "#0e1520"
                        border { color: "#00d4ff"; width: 1 }
                        Text { anchors.centerIn: parent; text: modelData.icon; color: "#00d4ff"; font.pixelSize: 24 }
                        MouseArea {
                            id: ma; anchors.fill: parent
                            onClicked: {
                                if (modelData.slot === "prev")      AudioService.btPrev()
                                else if (modelData.slot === "play") AudioService.btPlay()
                                else                                AudioService.btNext()
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: fmComponent
        Column {
            anchors.centerIn: parent; spacing: 12
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   text: AudioService.source === 1 ? "FM" : "AM"
                   color: "#555"; font { pixelSize: 11; capitalization: Font.AllUppercase } }
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   text: AudioService.fmFrequency.toFixed(1) + " MHz"
                   color: "#f0f0f0"; font { pixelSize: 36; weight: Font.Light } }
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   text: AudioService.fmStation; color: "#888"; font.pixelSize: 16 }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter; spacing: 24
                Repeater {
                    model: [{ icon: "◀◀", fwd: false }, { icon: "▶▶", fwd: true }]
                    delegate: Rectangle {
                        width: 64; height: 44; radius: 8
                        color: ma2.pressed ? "#1a3a5a" : "#0e1520"
                        border { color: "#00d4ff"; width: 1 }
                        Text { anchors.centerIn: parent; text: modelData.icon; color: "#00d4ff"; font.pixelSize: 20 }
                        MouseArea { id: ma2; anchors.fill: parent
                                    onClicked: AudioService.seekFM(modelData.fwd) }
                    }
                }
            }
        }
    }

    Component {
        id: sxmComponent
        Column {
            anchors.centerIn: parent; spacing: 12
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   text: "SiriusXM"; color: "#555"; font { pixelSize: 11; capitalization: Font.AllUppercase } }
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   text: AudioService.sxmName.length > 0 ? AudioService.sxmName : "—"
                   color: "#f0f0f0"; font { pixelSize: 24; weight: Font.Light } }
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   text: AudioService.sxmChannel; color: "#888"; font.pixelSize: 14 }
        }
    }

    Component {
        id: auxComponent
        Column {
            anchors.centerIn: parent
            Text { text: "AUX Input"; color: "#888"; font.pixelSize: 22 }
        }
    }
}
