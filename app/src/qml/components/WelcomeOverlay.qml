// WelcomeOverlay.qml — Startup welcome sequence (upper 8" screen)
// Shown over the navigation view for ~3 seconds, then fades out.
// Non-blocking: sits on top of NavigationView, never pushes the nav stack.
//
// Two modes:
//   1. profileLoaded = true  → "Welcome back, Doug" + last session chip
//   2. noProfileMode = true  → "Who's driving?" with profile avatar taps
//
// Accent glow matches active profile color (ProfileService.activeAccentColor).
// Tap anywhere or wait 3s to dismiss.
//
// Upper screen is 800×480. This overlay fills the parent (NavigationView).

import QtQuick 6.6

Item {
    id: root
    anchors.fill: parent

    // Bound to ProfileService
    property bool profileLoaded:    ProfileService.profileLoaded
    property bool noProfileMode:    ProfileService.noProfileMode
    property bool overlayVisible:   ProfileService.welcomeVisible

    // Internal display state
    property bool showing: false

    onOverlayVisibleChanged: {
        if (overlayVisible) {
            root.showing = true
            contentAnim.restart()
            if (!noProfileMode) {
                autoDismissTimer.restart()
            }
        } else {
            fadeOut.restart()
        }
    }

    // ── Background scrim ─────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: root.showing ? 0.88 : 0
        Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
    }

    // ── Accent glow border ────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border {
            color: ProfileService.activeAccentColor
            width: root.showing ? 3 : 0
        }
        opacity: root.showing ? 0.55 : 0
        Behavior on opacity { NumberAnimation { duration: 400 } }
        Behavior on border.width { NumberAnimation { duration: 300 } }
    }

    // ── Mode: Profile loaded — Welcome back ───────────────────────────────────
    Item {
        id: welcomeContent
        anchors.centerIn: parent
        width: 400; height: 220
        visible: root.showing && !root.noProfileMode
        opacity: 0

        Column {
            anchors.centerIn: parent
            spacing: 16

            // Avatar with scale-in animation
            Text {
                id: avatarText
                anchors.horizontalCenter: parent.horizontalCenter
                text: ProfileService.activeProfileAvatar
                font.pixelSize: 64
                scale: 0.6
                opacity: 0
                SequentialAnimation {
                    id: avatarAnim
                    running: false
                    PauseAnimation { duration: 100 }
                    ParallelAnimation {
                        NumberAnimation {
                            target: avatarText; property: "scale"
                            from: 0.6; to: 1.0
                            duration: 420; easing.type: Easing.OutBack
                        }
                        NumberAnimation {
                            target: avatarText; property: "opacity"
                            from: 0; to: 1
                            duration: 300
                        }
                    }
                }
            }

            // "Welcome back, Doug"
            Text {
                id: welcomeText
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Welcome back, " + ProfileService.activeProfileName
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 28; weight: Font.Light }
                opacity: 0
                SequentialAnimation {
                    id: welcomeTextAnim
                    running: false
                    PauseAnimation { duration: 250 }
                    NumberAnimation {
                        target: welcomeText; property: "opacity"
                        from: 0; to: 1
                        duration: 350
                    }
                }
            }

            // Last session chip
            Rectangle {
                id: sessionChip
                anchors.horizontalCenter: parent.horizontalCenter
                visible: ProfileService.lastSessionSummary !== ""
                width: sessionLabel.implicitWidth + 28
                height: 28; radius: 14
                color: "rgba(255,255,255,0.10)"
                opacity: 0

                Text {
                    id: sessionLabel
                    anchors.centerIn: parent
                    text: ProfileService.lastSessionSummary
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 12 }
                }

                SequentialAnimation {
                    id: chipAnim
                    running: false
                    PauseAnimation { duration: 450 }
                    NumberAnimation {
                        target: sessionChip; property: "opacity"
                        from: 0; to: 1
                        duration: 300
                    }
                }
            }
        }
    }

    // ── Mode: No profile — "Who's driving?" ───────────────────────────────────
    Item {
        id: whoContent
        anchors.centerIn: parent
        width: parent.width - 60; height: 260
        visible: root.showing && root.noProfileMode
        opacity: 0

        Column {
            anchors.centerIn: parent
            spacing: 20

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Who's driving?"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 26; weight: Font.Light }
            }

            // Profile avatar row (tap to select)
            Row {
                id: avatarRow
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 20

                Repeater {
                    model: ProfileService.profiles

                    delegate: Column {
                        spacing: 8

                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 72; height: 72; radius: 36
                            color: "#1C1C1E"
                            border { color: modelData.accentColor || "#0A84FF"; width: 2 }

                            Text {
                                anchors.centerIn: parent
                                text: modelData.avatar || "🏎️"
                                font.pixelSize: 36
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: ProfileService.switchProfile(index)
                            }
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.name || "Profile"
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 12; weight: Font.Medium }
                        }
                    }
                }
            }

            // Guest mode option
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 120; height: 32; radius: 16
                color: "rgba(255,255,255,0.08)"

                Text {
                    anchors.centerIn: parent
                    text: "Continue as Guest"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 12 }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: ProfileService.activateGuestMode()
                }
            }
        }
    }

    // ── Master entrance animation ─────────────────────────────────────────────
    SequentialAnimation {
        id: contentAnim
        running: false
        NumberAnimation {
            target: welcomeContent; property: "opacity"
            from: 0; to: 1
            duration: 280
        }
        ScriptAction {
            script: {
                avatarAnim.start()
                welcomeTextAnim.start()
                chipAnim.start()
            }
        }
    }

    // Parallel entrance for "who's driving" mode
    NumberAnimation {
        id: whoAnim
        target: whoContent; property: "opacity"
        from: 0; to: 1
        duration: 350
        running: root.showing && root.noProfileMode
    }

    // ── Auto-dismiss (3 seconds) ──────────────────────────────────────────────
    Timer {
        id: autoDismissTimer
        interval: 3000
        repeat: false
        running: false
        onTriggered: ProfileService.dismissWelcome()
    }

    // ── Fade-out ──────────────────────────────────────────────────────────────
    SequentialAnimation {
        id: fadeOut
        running: false
        ParallelAnimation {
            NumberAnimation {
                target: welcomeContent; property: "opacity"
                to: 0; duration: 280; easing.type: Easing.InCubic
            }
            NumberAnimation {
                target: whoContent; property: "opacity"
                to: 0; duration: 280; easing.type: Easing.InCubic
            }
        }
        ScriptAction {
            script: {
                root.showing = false
                avatarText.opacity = 0
                avatarText.scale   = 0.6
                welcomeText.opacity = 0
                sessionChip.opacity = 0
            }
        }
    }

    // ── Tap-to-dismiss anywhere ───────────────────────────────────────────────
    MouseArea {
        anchors.fill: parent
        enabled: root.showing && !root.noProfileMode
        onClicked: {
            autoDismissTimer.stop()
            ProfileService.dismissWelcome()
        }
    }

    // Only show overlay when ProfileService says so
    visible: root.showing
}
