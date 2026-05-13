// VehicleSettingsView — BCM Work Support unlocks + DTCs + maintenance resets.
// Reached from the main SettingsView "Vehicle Unlocks" row.
// Every write path here is Q50_HYPOTHESIZED — see SettingsService.canVerifiedWrites
// (master gate) and docs/hardware-day-capture-checklist.md.
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    signal closed()

    property var s: SettingsService
    property var v: VehicleService

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Header ──────────────────────────────────────────────────────────────
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 48
        color: "#000000"
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.1)
        }
        Row {
            anchors { fill: parent; leftMargin: 8 }
            spacing: 6
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 36; height: 36; radius: 18
                color: "transparent"
                Text { anchors.centerIn: parent; text: "‹"; color: "#FFFFFF"; font { pixelSize: 22 } }
                MouseArea { anchors.fill: parent; onClicked: root.closed() }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Vehicle Unlocks"; color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 17; weight: Font.SemiBold }
            }
        }
    }

    // ── Gate banner ─────────────────────────────────────────────────────────
    Rectangle {
        id: gateBanner
        anchors { top: header.bottom; left: parent.left; right: parent.right; margins: 8 }
        height: 56
        radius: 10
        color: s.canVerifiedWrites ? Qt.rgba(0.04, 0.5, 0.34, 0.18) : Qt.rgba(1.0, 0.62, 0.04, 0.18)
        border { color: s.canVerifiedWrites ? "#30D158" : "#FF9F0A"; width: 1 }
        Row {
            anchors { fill: parent; margins: 10 }
            spacing: 10
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: s.canVerifiedWrites ? "✓" : "⚠"
                color: s.canVerifiedWrites ? "#30D158" : "#FF9F0A"
                font { pixelSize: 22 }
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 110
                Text {
                    text: s.canVerifiedWrites ? "CAN writes ENABLED" : "CAN writes DISABLED — log only"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                }
                Text {
                    text: s.canVerifiedWrites
                          ? "BCM unlocks transmit live frames."
                          : "Flip after J2534 capture confirms IDs."
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11 }
                    width: parent.width; elide: Text.ElideRight
                }
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 44; height: 26; radius: 13
                color: s.canVerifiedWrites ? "#30D158" : "#3A3A3C"
                Behavior on color { ColorAnimation { duration: 150 } }
                Rectangle {
                    id: gateKnob
                    width: 22; height: 22; radius: 11
                    anchors.verticalCenter: parent.verticalCenter
                    x: s.canVerifiedWrites ? 20 : 2
                    color: "#FFFFFF"
                    Behavior on x { NumberAnimation { duration: 150 } }
                }
                MouseArea { anchors.fill: parent; onClicked: s.canVerifiedWrites = !s.canVerifiedWrites }
            }
        }
    }

    // ── Scrollable body ─────────────────────────────────────────────────────
    Flickable {
        anchors { top: gateBanner.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; topMargin: 8 }
        contentHeight: bodyCol.implicitHeight + 24
        clip: true

        Column {
            id: bodyCol
            width: parent.width
            spacing: 8

            // ─── Door locks ────────────────────────────────────────────────
            SectionHeader { sectionText: "DOOR LOCKS" }

            CardShell {
                labelText: "Auto-lock at speed"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: [
                            { lbl: "Off",    val: 0, mph: 0 },
                            { lbl: "15 mph", val: 1, mph: 15 },
                            { lbl: "25 mph", val: 2, mph: 25 },
                            { lbl: "Custom", val: 3, mph: -1 }
                        ]
                        delegate: Pill {
                            pillActive: s.autoLockSpeed === modelData.val
                            pillLabel: modelData.lbl
                            onTapped: {
                                s.autoLockSpeed = modelData.val
                                v.applyAutoLockThreshold(modelData.val === 3 ? s.autoLockSpeedCustom : modelData.mph)
                            }
                        }
                    }
                }
            }

            CardShell {
                showRow: s.autoLockSpeed === 3
                labelText: "Custom threshold"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Slider {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 220
                        from: 5; to: 40; stepSize: 1
                        value: s.autoLockSpeedCustom
                        onMoved: {
                            s.autoLockSpeedCustom = Math.round(value)
                            v.applyAutoLockThreshold(s.autoLockSpeedCustom)
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: s.autoLockSpeedCustom + " mph"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13 }
                    }
                }
            }

            // ─── Mirrors ───────────────────────────────────────────────────
            SectionHeader { sectionText: "MIRRORS" }
            ToggleShell {
                labelText: "Tilt on reverse"
                toggleValue: s.mirrorTiltReverse
                onToggleTapped: s.mirrorTiltReverse = !s.mirrorTiltReverse
            }
            ToggleShell {
                showRow: s.mirrorTiltReverse
                labelText: "Driver side"
                toggleValue: s.mirrorTiltLeft
                onToggleTapped: { s.mirrorTiltLeft = !s.mirrorTiltLeft; v.applyMirrorTiltConfig(s.mirrorTiltAngle, s.mirrorTiltLeft, s.mirrorTiltRight) }
            }
            ToggleShell {
                showRow: s.mirrorTiltReverse
                labelText: "Passenger side"
                toggleValue: s.mirrorTiltRight
                onToggleTapped: { s.mirrorTiltRight = !s.mirrorTiltRight; v.applyMirrorTiltConfig(s.mirrorTiltAngle, s.mirrorTiltLeft, s.mirrorTiltRight) }
            }
            CardShell {
                showRow: s.mirrorTiltReverse
                labelText: "Tilt depth"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Slider {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 220
                        from: 0; to: 100; stepSize: 5
                        value: s.mirrorTiltAngle
                        onMoved: {
                            s.mirrorTiltAngle = Math.round(value)
                            v.applyMirrorTiltConfig(s.mirrorTiltAngle, s.mirrorTiltLeft, s.mirrorTiltRight)
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: s.mirrorTiltAngle + "%"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13 }
                    }
                }
            }
            ToggleShell {
                labelText: "Walk-away auto-fold"
                toggleValue: s.mirrorFoldLock
                onToggleTapped: s.mirrorFoldLock = !s.mirrorFoldLock
            }

            // ─── Comfort windows ───────────────────────────────────────────
            SectionHeader { sectionText: "WINDOWS" }
            ToggleShell {
                labelText: "Comfort close from fob (lock-hold)"
                toggleValue: s.fobLockHoldCloses
                onToggleTapped: s.fobLockHoldCloses = !s.fobLockHoldCloses
            }
            ToggleShell {
                labelText: "One-touch up/down — all 4"
                toggleValue: s.allWindowsOneTouch
                onToggleTapped: s.allWindowsOneTouch = !s.allWindowsOneTouch
            }
            ToggleShell {
                labelText: "Auto-up when wipers go active"
                toggleValue: s.autoUpOnRain
                onToggleTapped: s.autoUpOnRain = !s.autoUpOnRain
            }

            // ─── Horn / chirp ──────────────────────────────────────────────
            SectionHeader { sectionText: "HORN / LOCK CONFIRMATION" }
            CardShell {
                labelText: "Mode"
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    Row {
                        spacing: 6
                        Repeater {
                            model: [
                                { lbl: "Silent",       val: 0 },
                                { lbl: "Hazards only", val: 1 },
                                { lbl: "Haz + horn",   val: 2 }
                            ]
                            delegate: Pill {
                                pillActive: s.hornChirpMode === modelData.val
                                pillLabel: modelData.lbl
                                onTapped: { s.hornChirpMode = modelData.val; v.applyHornChirpMode(modelData.val) }
                            }
                        }
                    }
                    Row {
                        spacing: 6
                        Repeater {
                            model: [
                                { lbl: "Double chirp", val: 3 },
                                { lbl: "Lights only",  val: 4 }
                            ]
                            delegate: Pill {
                                pillActive: s.hornChirpMode === modelData.val
                                pillLabel: modelData.lbl
                                onTapped: { s.hornChirpMode = modelData.val; v.applyHornChirpMode(modelData.val) }
                            }
                        }
                    }
                }
            }

            // ─── Welcome lighting ──────────────────────────────────────────
            SectionHeader { sectionText: "WELCOME LIGHTING" }
            CardShell {
                labelText: "Choreography"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: [
                            { lbl: "Off",     val: 0 },
                            { lbl: "Sweep",   val: 1 },
                            { lbl: "Fade",    val: 2 },
                            { lbl: "Cascade", val: 3 }
                        ]
                        delegate: Pill {
                            pillActive: s.welcomeLightSequence === modelData.val
                            pillLabel: modelData.lbl
                            onTapped: { s.welcomeLightSequence = modelData.val; v.applyWelcomeLightSequence(modelData.val) }
                        }
                    }
                }
            }

            // ─── DRL matrix ────────────────────────────────────────────────
            SectionHeader { sectionText: "DAYTIME RUNNING LIGHTS" }
            CardShell {
                labelText: "Mode"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: [
                            { lbl: "Off",         val: 0 },
                            { lbl: "Always",      val: 1 },
                            { lbl: "+Parking",    val: 2 },
                            { lbl: "Cancel turn", val: 3 }
                        ]
                        delegate: Pill {
                            pillActive: s.drlMode === modelData.val
                            pillLabel: modelData.lbl
                            onTapped: { s.drlMode = modelData.val; v.applyDrlMode(modelData.val) }
                        }
                    }
                }
            }

            // ─── Headlight delay ───────────────────────────────────────────
            SectionHeader { sectionText: "AUTO HEADLIGHT DELAY" }
            CardShell {
                labelText: "Stay on for"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: [0, 15, 30, 60, 120, 180]
                        delegate: Pill {
                            pillActive: s.headlightDelaySec === modelData
                            pillLabel: modelData === 0 ? "Off" : (modelData < 60 ? modelData + "s" : (modelData/60) + "m")
                            onTapped: { s.headlightDelaySec = modelData; v.applyHeadlightDelay(modelData) }
                        }
                    }
                }
            }

            // ─── TPMS ──────────────────────────────────────────────────────
            SectionHeader { sectionText: "TPMS THRESHOLDS" }
            CardShell {
                labelText: "Profile"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: [
                            { lbl: "Street",  warn: 30, crit: 26, val: 0 },
                            { lbl: "Track",   warn: 38, crit: 32, val: 1 },
                            { lbl: "Touring", warn: 32, crit: 28, val: 2 }
                        ]
                        delegate: Pill {
                            pillActive: s.tpmsProfile === modelData.val
                            pillLabel: modelData.lbl
                            onTapped: {
                                s.tpmsProfile = modelData.val
                                s.tpmsWarnPsi = modelData.warn
                                s.tpmsCritPsi = modelData.crit
                                v.applyTpmsThresholds(modelData.warn, modelData.crit)
                            }
                        }
                    }
                }
            }
            CardShell {
                labelText: "Warn at"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Slider {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 220
                        from: 20; to: 50; stepSize: 1
                        value: s.tpmsWarnPsi
                        onMoved: {
                            s.tpmsWarnPsi = Math.round(value)
                            v.applyTpmsThresholds(s.tpmsWarnPsi, s.tpmsCritPsi)
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: s.tpmsWarnPsi + " psi"; color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13 }
                    }
                }
            }
            CardShell {
                labelText: "Critical at"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Slider {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 220
                        from: 18; to: 45; stepSize: 1
                        value: s.tpmsCritPsi
                        onMoved: {
                            s.tpmsCritPsi = Math.round(value)
                            v.applyTpmsThresholds(s.tpmsWarnPsi, s.tpmsCritPsi)
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: s.tpmsCritPsi + " psi"; color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 13 }
                    }
                }
            }

            // ─── Maintenance resets ────────────────────────────────────────
            SectionHeader { sectionText: "MAINTENANCE RESETS" }
            CardShell {
                labelText: "Reset reminders"
                cardHeight: 96
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Row {
                        spacing: 6
                        Pill { pillActive: false; pillLabel: "Oil life";      onTapped: v.resetOilLife() }
                        Pill { pillActive: false; pillLabel: "Tire rotation"; onTapped: v.resetTireRotation() }
                        Pill { pillActive: false; pillLabel: "Brake fluid";   onTapped: v.resetBrakeFluid() }
                    }
                    Row {
                        spacing: 6
                        Pill { pillActive: false; pillLabel: "Air filter";   onTapped: v.resetAirFilter() }
                        Pill { pillActive: false; pillLabel: "Cabin filter"; onTapped: v.resetCabinFilter() }
                    }
                }
            }

            // ─── DTC reader ────────────────────────────────────────────────
            SectionHeader { sectionText: "DIAGNOSTIC TROUBLE CODES" }
            CardShell {
                labelText: "Actions"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Pill {
                        pillActive: v.dtcReadInFlight
                        pillLabel: v.dtcReadInFlight ? "Scanning…" : "Scan now"
                        onTapped: v.readDtcs()
                    }
                    Pill {
                        pillActive: false
                        pillLabel: "Clear all"
                        onTapped: v.clearDtcs()
                    }
                }
            }
            Column {
                width: parent.width
                spacing: 4
                Repeater {
                    model: v.currentDtcs
                    delegate: Rectangle {
                        width: bodyCol.width - 16
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: 56
                        radius: 10
                        color: "#1C1C1E"
                        border { color: Qt.rgba(1, 1, 1, 0.08); width: 1 }
                        Row {
                            anchors { fill: parent; margins: 10 }
                            spacing: 8
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 42; height: 22; radius: 6
                                color: modelData.status === "active"  ? "#FF453A"
                                     : modelData.status === "pending" ? "#FF9F0A" : "#8E8E93"
                                Text { anchors.centerIn: parent; text: modelData.ecu; color: "#FFFFFF"; font { pixelSize: 10; weight: Font.SemiBold } }
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 60
                                Text { text: modelData.code + " — " + modelData.status; color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 13; weight: Font.Medium } }
                                Text { text: modelData.desc; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 11 }; width: parent.width; elide: Text.ElideRight }
                            }
                        }
                    }
                }
                Item {
                    width: parent.width; height: 30
                    visible: !v.dtcReadInFlight && (!v.currentDtcs || v.currentDtcs.length === 0)
                    Text {
                        anchors.centerIn: parent
                        text: "No codes — run a scan to refresh"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 12 }
                    }
                }
            }

            Item { width: parent.width; height: 16 }
        }
    }

    // ── Inline components (file-scoped) ─────────────────────────────────────
    component SectionHeader: Item {
        property string sectionText: ""
        width: parent ? parent.width : 0
        height: 30
        Text {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 16 }
            text: parent.sectionText
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 10; weight: Font.Medium; letterSpacing: 1.4 }
        }
    }

    component CardShell: Rectangle {
        id: cardRoot
        property string labelText: ""
        property bool showRow: true
        property int cardHeight: 60
        default property alias contentItems: contentHolder.data
        width: parent ? parent.width - 16 : 0
        anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
        height: showRow ? cardHeight : 0
        visible: showRow
        clip: true
        radius: 10
        color: "#1C1C1E"
        border { color: Qt.rgba(1, 1, 1, 0.07); width: 1 }
        Row {
            anchors { fill: parent; margins: 10 }
            spacing: 10
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 160
                text: cardRoot.labelText
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
                wrapMode: Text.WordWrap
            }
            Item {
                id: contentHolder
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 180
                height: cardRoot.height - 20
            }
        }
    }

    component ToggleShell: Rectangle {
        id: toggleRoot
        property string labelText: ""
        property bool toggleValue: false
        property bool showRow: true
        signal toggleTapped()
        width: parent ? parent.width - 16 : 0
        anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
        height: showRow ? 52 : 0
        visible: showRow
        clip: true
        radius: 10
        color: "#1C1C1E"
        border { color: Qt.rgba(1, 1, 1, 0.07); width: 1 }
        Row {
            anchors { fill: parent; margins: 10 }
            spacing: 10
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 70
                text: toggleRoot.labelText
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
                wrapMode: Text.WordWrap
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 44; height: 26; radius: 13
                color: toggleRoot.toggleValue ? "#0A84FF" : "#3A3A3C"
                Behavior on color { ColorAnimation { duration: 150 } }
                Rectangle {
                    width: 22; height: 22; radius: 11
                    anchors.verticalCenter: parent.verticalCenter
                    x: toggleRoot.toggleValue ? 20 : 2
                    color: "#FFFFFF"
                    Behavior on x { NumberAnimation { duration: 150 } }
                }
                MouseArea { anchors.fill: parent; onClicked: toggleRoot.toggleTapped() }
            }
        }
    }

    component Pill: Rectangle {
        id: pillRoot
        property bool pillActive: false
        property string pillLabel: ""
        signal tapped()
        height: 32
        width: pillText.implicitWidth + 22
        radius: 16
        color: pillActive ? "#0A84FF" : "#2C2C2E"
        Text {
            id: pillText
            anchors.centerIn: parent
            text: pillRoot.pillLabel
            color: pillRoot.pillActive ? "#FFFFFF" : "#8E8E93"
            font { family: "Roboto"; pixelSize: 12; weight: Font.Medium }
        }
        MouseArea { anchors.fill: parent; onClicked: pillRoot.tapped() }
    }
}
