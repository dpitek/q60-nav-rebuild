// VehicleStatusView.qml — Vehicle information center
// 5 sub-tabs: Info | Drive | ADAS | ATTESA | Diag
// Content area: 800×360 (800×420 minus 60px nav bar)
import QtQuick 6.6

Item {
    id: root
    anchors.fill: parent

    // ── Background ─────────────────────────────────────────────────────────────
    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Sub-tab state ──────────────────────────────────────────────────────────
    property int activeTab: 0   // 0=Info 1=Drive 2=ADAS 3=ATTESA 4=Diag

    // ── Drive-mode personal config local state ────────────────────────────────
    property int personalEngine:   0   // 0=Standard 1=Sport 2=Eco
    property int personalSteering: 1   // 0=Light 1=Normal 2=Heavy
    property int personalTrace:    2   // 0=Off 1=Light 2=Normal
    property int personalSound:    0   // 0=Off 1=Low 2=High

    // ── Button log (last 5 entries) ────────────────────────────────────────────
    property var buttonLog: []

    // ── ATTESA history (last 20 front-torque readings) ─────────────────────────
    property var atessaHistory: []

    // ── Connections for button log ─────────────────────────────────────────────
    Connections {
        target: VehicleService
        function onVolUp()         { root._logButton("VOL UP") }
        function onVolDown()       { root._logButton("VOL DOWN") }
        function onSeekFwd()       { root._logButton("SEEK FWD") }
        function onSeekBack()      { root._logButton("SEEK BACK") }
        function onAnswerCall()    { root._logButton("ANSWER CALL") }
        function onEndCall()       { root._logButton("END CALL") }
        function onMuteToggle()    { root._logButton("MUTE TOGGLE") }
        function onVoiceActivate() { root._logButton("VOICE ACTIVATE") }
        function onAtessaChanged() {
            var h = root.atessaHistory.slice()
            h.push(VehicleService.atessaFront)
            if (h.length > 20) h.shift()
            root.atessaHistory = h
            if (attesaCanvas.visible) attesaCanvas.requestPaint()
            if (attesaSparkline.visible) attesaSparkline.requestPaint()
        }
    }

    function _logButton(label) {
        var now = new Date()
        var ts  = now.getHours().toString().padStart(2,"0") + ":"
                + now.getMinutes().toString().padStart(2,"0") + ":"
                + now.getSeconds().toString().padStart(2,"0")
        var log = root.buttonLog.slice()
        log.push(ts + "  " + label)
        if (log.length > 5) log.shift()
        root.buttonLog = log
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SUB-TAB BAR  (40px)
    // ══════════════════════════════════════════════════════════════════════════
    Item {
        id: tabBar
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 40

        Row {
            anchors { verticalCenter: parent.verticalCenter; horizontalCenter: parent.horizontalCenter }
            spacing: 4

            Repeater {
                model: ["Info", "Drive", "ADAS", "ATTESA", "Diag"]

                Rectangle {
                    width: 140; height: 36; radius: 18
                    color: root.activeTab === index ? "#0A84FF" : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: 150 }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: root.activeTab === index ? "#FFFFFF" : "#8E8E93"
                        font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.activeTab = index
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CONTENT AREA  (320px below tab bar)
    // ══════════════════════════════════════════════════════════════════════════
    Item {
        id: contentArea
        anchors { top: tabBar.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }

        // ────────────────────────────────────────────────────────────────────
        // TAB 0 — INFO
        // ────────────────────────────────────────────────────────────────────
        Item {
            id: tabInfo
            anchors.fill: parent
            visible: root.activeTab === 0

            // ── Top row: TPMS card + Door/Fuel card ──────────────────────────
            Row {
                id: infoTopRow
                anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 8 }
                spacing: 12

                // ── TPMS Card ────────────────────────────────────────────────
                Rectangle {
                    width: 155; height: 145; radius: 16
                    color: "#1C1C1E"

                    Text {
                        id: tpmsHeader
                        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 8 }
                        text: "TIRES"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                    }

                    // Helper function: PSI color
                    function psiColor(psi) {
                        if (psi <= 0.0) return "#8E8E93"
                        if (psi < 25)   return "#FF453A"
                        if (psi < 30)   return "#FF9F0A"
                        return "#30D158"
                    }
                    function psiText(psi) {
                        return psi <= 0.0 ? "—" : psi.toFixed(0)
                    }

                    // Car top-view silhouette
                    Rectangle {
                        anchors.centerIn: parent; anchors.verticalCenterOffset: 4
                        width: 52; height: 76; radius: 8
                        color: "#2C2C2E"
                        border { color: "rgba(255,255,255,0.12)"; width: 1 }

                        // Windshield
                        Rectangle {
                            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 6 }
                            width: 32; height: 14; radius: 3
                            color: "#3A3A3C"
                        }
                        // Rear window
                        Rectangle {
                            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 6 }
                            width: 32; height: 12; radius: 3
                            color: "#3A3A3C"
                        }
                    }

                    // FL tire
                    Rectangle {
                        x: 10; y: 30; width: 28; height: 28; radius: 14
                        color: parent.psiColor(VehicleService.tirePSI_FL)
                        border { color: "rgba(0,0,0,0.3)"; width: 1 }
                        Text {
                            anchors.centerIn: parent
                            text: parent.parent.psiText(VehicleService.tirePSI_FL)
                            color: "#FFFFFF"; font { pixelSize: 9; weight: Font.Bold }
                        }
                        Text {
                            anchors { bottom: parent.top; horizontalCenter: parent.horizontalCenter; bottomMargin: 1 }
                            text: "FL"; color: "#8E8E93"; font.pixelSize: 8
                        }
                    }

                    // FR tire
                    Rectangle {
                        x: 117; y: 30; width: 28; height: 28; radius: 14
                        color: parent.psiColor(VehicleService.tirePSI_FR)
                        border { color: "rgba(0,0,0,0.3)"; width: 1 }
                        Text {
                            anchors.centerIn: parent
                            text: parent.parent.psiText(VehicleService.tirePSI_FR)
                            color: "#FFFFFF"; font { pixelSize: 9; weight: Font.Bold }
                        }
                        Text {
                            anchors { bottom: parent.top; horizontalCenter: parent.horizontalCenter; bottomMargin: 1 }
                            text: "FR"; color: "#8E8E93"; font.pixelSize: 8
                        }
                    }

                    // RL tire
                    Rectangle {
                        x: 10; y: 88; width: 28; height: 28; radius: 14
                        color: parent.psiColor(VehicleService.tirePSI_RL)
                        border { color: "rgba(0,0,0,0.3)"; width: 1 }
                        Text {
                            anchors.centerIn: parent
                            text: parent.parent.psiText(VehicleService.tirePSI_RL)
                            color: "#FFFFFF"; font { pixelSize: 9; weight: Font.Bold }
                        }
                        Text {
                            anchors { top: parent.bottom; horizontalCenter: parent.horizontalCenter; topMargin: 1 }
                            text: "RL"; color: "#8E8E93"; font.pixelSize: 8
                        }
                    }

                    // RR tire
                    Rectangle {
                        x: 117; y: 88; width: 28; height: 28; radius: 14
                        color: parent.psiColor(VehicleService.tirePSI_RR)
                        border { color: "rgba(0,0,0,0.3)"; width: 1 }
                        Text {
                            anchors.centerIn: parent
                            text: parent.parent.psiText(VehicleService.tirePSI_RR)
                            color: "#FFFFFF"; font { pixelSize: 9; weight: Font.Bold }
                        }
                        Text {
                            anchors { top: parent.bottom; horizontalCenter: parent.horizontalCenter; topMargin: 1 }
                            text: "RR"; color: "#8E8E93"; font.pixelSize: 8
                        }
                    }
                }

                // ── Door/Fuel Card ───────────────────────────────────────────
                Rectangle {
                    width: 155; height: 145; radius: 16
                    color: "#1C1C1E"

                    // Top half: compact door diagram
                    Item {
                        id: compactDoors
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 6 }
                        height: 72

                        Text {
                            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter }
                            text: "DOORS"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }

                        // Car body
                        Rectangle {
                            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 12 }
                            width: 44; height: 50; radius: 6; color: "#2C2C2E"
                            border { color: "rgba(255,255,255,0.1)"; width: 1 }
                        }

                        function doorColor(open) { return open ? "#FF453A" : "#1C1C1E" }
                        function doorBorder(open) { return open ? "#FF453A" : "#3A3A3C" }

                        // FL
                        Rectangle {
                            x: 38; y: 14; width: 20; height: 16; radius: 3
                            color: compactDoors.doorColor(VehicleService.doorDriver)
                            border { color: compactDoors.doorBorder(VehicleService.doorDriver); width: 1 }
                            Text { anchors.centerIn: parent; text: "FL"; color: "#FFFFFF"; font.pixelSize: 7; font.weight: Font.Bold }
                        }
                        // FR
                        Rectangle {
                            x: 97; y: 14; width: 20; height: 16; radius: 3
                            color: compactDoors.doorColor(VehicleService.doorPassenger)
                            border { color: compactDoors.doorBorder(VehicleService.doorPassenger); width: 1 }
                            Text { anchors.centerIn: parent; text: "FR"; color: "#FFFFFF"; font.pixelSize: 7; font.weight: Font.Bold }
                        }
                        // RL
                        Rectangle {
                            x: 38; y: 36; width: 20; height: 16; radius: 3
                            color: compactDoors.doorColor(VehicleService.doorRearLeft)
                            border { color: compactDoors.doorBorder(VehicleService.doorRearLeft); width: 1 }
                            Text { anchors.centerIn: parent; text: "RL"; color: "#FFFFFF"; font.pixelSize: 7; font.weight: Font.Bold }
                        }
                        // RR
                        Rectangle {
                            x: 97; y: 36; width: 20; height: 16; radius: 3
                            color: compactDoors.doorColor(VehicleService.doorRearRight)
                            border { color: compactDoors.doorBorder(VehicleService.doorRearRight); width: 1 }
                            Text { anchors.centerIn: parent; text: "RR"; color: "#FFFFFF"; font.pixelSize: 7; font.weight: Font.Bold }
                        }
                        // Trunk
                        Rectangle {
                            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 58 }
                            width: 32; height: 10; radius: 2
                            color: compactDoors.doorColor(VehicleService.trunkOpen)
                            border { color: compactDoors.doorBorder(VehicleService.trunkOpen); width: 1 }
                            Text { anchors.centerIn: parent; text: "TR"; color: "#FFFFFF"; font.pixelSize: 7; font.weight: Font.Bold }
                        }
                    }

                    // Divider
                    Rectangle {
                        anchors { top: compactDoors.bottom; left: parent.left; right: parent.right; topMargin: 2 }
                        height: 1; color: "#2C2C2E"
                    }

                    // Bottom half: small fuel arc
                    Item {
                        anchors { top: compactDoors.bottom; bottom: parent.bottom; left: parent.left; right: parent.right; topMargin: 4 }

                        Canvas {
                            id: smallFuelArc
                            anchors.fill: parent
                            property real fuelLevel: VehicleService.fuelLevel

                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                var cx = width / 2
                                var cy = height / 2 + 4
                                var r  = 26
                                ctx.beginPath()
                                ctx.arc(cx, cy, r, Math.PI * 0.75, Math.PI * 2.25, false)
                                ctx.strokeStyle = "#2C2C2E"
                                ctx.lineWidth = 6; ctx.lineCap = "round"; ctx.stroke()

                                var sweep = fuelLevel * Math.PI * 1.5
                                if (sweep > 0.01) {
                                    ctx.beginPath()
                                    ctx.arc(cx, cy, r, Math.PI * 0.75, Math.PI * 0.75 + sweep, false)
                                    ctx.strokeStyle = fuelLevel > 0.25 ? "#30D158"
                                                    : fuelLevel > 0.1  ? "#FF9F0A" : "#FF453A"
                                    ctx.lineWidth = 6; ctx.lineCap = "round"; ctx.stroke()
                                }
                            }
                            onFuelLevelChanged: requestPaint()
                            Component.onCompleted: requestPaint()
                        }

                        Text {
                            anchors.centerIn: parent; anchors.verticalCenterOffset: 2
                            text: Math.round(VehicleService.fuelLevel * 100) + "%"
                            color: VehicleService.fuelLevel > 0.25 ? "#FFFFFF"
                                 : VehicleService.fuelLevel > 0.1  ? "#FF9F0A" : "#FF453A"
                            font { family: "Roboto"; pixelSize: 13; weight: Font.Bold }
                        }
                        Text {
                            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 2 }
                            text: "FUEL"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }
                    }
                }
            }

            // ── Middle row: Trip Computer ────────────────────────────────────
            Rectangle {
                id: tripComputer
                anchors { top: infoTopRow.bottom; left: parent.left; right: parent.right; topMargin: 8; leftMargin: 8; rightMargin: 8 }
                height: 60; radius: 16; color: "#1C1C1E"

                Row {
                    anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                    spacing: 0

                    // Trip A
                    Item {
                        width: parent.width / 4; height: parent.height

                        Row {
                            anchors.centerIn: parent
                            spacing: 4

                            Rectangle {
                                width: 18; height: 18; radius: 9
                                color: "#2C2C2E"
                                anchors.verticalCenter: parent.verticalCenter
                                Text { anchors.centerIn: parent; text: "×"; color: "#8E8E93"; font.pixelSize: 11 }
                                MouseArea { anchors.fill: parent; onClicked: VehicleService.resetTripA() }
                            }

                            Column {
                                spacing: 0
                                Text {
                                    text: "A: " + VehicleService.tripAMiles.toFixed(1) + " mi"
                                    color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold }
                                }
                                Text {
                                    text: VehicleService.tripAAvgMPG > 0 ? VehicleService.tripAAvgMPG.toFixed(1) + " MPG" : "— MPG"
                                    color: "#8E8E93"; font { family: "Roboto"; pixelSize: 10 }
                                }
                            }
                        }
                    }

                    // Divider
                    Rectangle { width: 1; height: parent.height * 0.6; anchors.verticalCenter: parent.verticalCenter; color: "#2C2C2E" }

                    // Trip B
                    Item {
                        width: parent.width / 4; height: parent.height

                        Row {
                            anchors.centerIn: parent
                            spacing: 4

                            Rectangle {
                                width: 18; height: 18; radius: 9
                                color: "#2C2C2E"
                                anchors.verticalCenter: parent.verticalCenter
                                Text { anchors.centerIn: parent; text: "×"; color: "#8E8E93"; font.pixelSize: 11 }
                                MouseArea { anchors.fill: parent; onClicked: VehicleService.resetTripB() }
                            }

                            Column {
                                spacing: 0
                                Text {
                                    text: "B: " + VehicleService.tripBMiles.toFixed(1) + " mi"
                                    color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold }
                                }
                                Text {
                                    text: VehicleService.tripBAvgMPG > 0 ? VehicleService.tripBAvgMPG.toFixed(1) + " MPG" : "— MPG"
                                    color: "#8E8E93"; font { family: "Roboto"; pixelSize: 10 }
                                }
                            }
                        }
                    }

                    // Divider
                    Rectangle { width: 1; height: parent.height * 0.6; anchors.verticalCenter: parent.verticalCenter; color: "#2C2C2E" }

                    // Avg Speed
                    Item {
                        width: parent.width / 4; height: parent.height

                        Column {
                            anchors.centerIn: parent; spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: VehicleService.tripAAvgSpeed > 0 ? VehicleService.tripAAvgSpeed.toFixed(0) + " MPH" : "— MPH"
                                color: "#FFFFFF"; font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "avg speed"
                                color: "#8E8E93"; font { family: "Roboto"; pixelSize: 10 }
                            }
                        }
                    }

                    // Divider
                    Rectangle { width: 1; height: parent.height * 0.6; anchors.verticalCenter: parent.verticalCenter; color: "#2C2C2E" }

                    // Inst MPG
                    Item {
                        width: parent.width / 4; height: parent.height

                        Column {
                            anchors.centerIn: parent; spacing: 0

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 3
                                Text {
                                    text: VehicleService.instantMPG > 0 ? VehicleService.instantMPG.toFixed(1) : "—"
                                    color: VehicleService.instantMPG > 25 ? "#30D158"
                                         : VehicleService.instantMPG > 15 ? "#FF9F0A" : "#FF453A"
                                    font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                                }
                                Text {
                                    text: "⚡"
                                    color: VehicleService.instantMPG > 25 ? "#30D158"
                                         : VehicleService.instantMPG > 15 ? "#FF9F0A" : "#FF453A"
                                    font.pixelSize: 12
                                }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "inst MPG"
                                color: "#8E8E93"; font { family: "Roboto"; pixelSize: 10 }
                            }
                        }
                    }
                }
            }

            // ── Bottom row: 5 stat badges ─────────────────────────────────────
            Row {
                id: statBadgeRow
                anchors { top: tripComputer.bottom; left: parent.left; right: parent.right; topMargin: 8; leftMargin: 8; rightMargin: 8 }
                spacing: 6
                height: 68

                // Coolant
                Rectangle {
                    width: (parent.width - 24) / 5; height: parent.height; radius: 12; color: "#1C1C1E"
                    Column {
                        anchors.centerIn: parent; spacing: 3
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "🌡"
                            font.pixelSize: 18
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: VehicleService.coolantTemp > 32 ? VehicleService.coolantTemp.toFixed(0) + "°F" : "—"
                            color: VehicleService.coolantTemp > 230 ? "#FF453A"
                                 : VehicleService.coolantTemp > 210 ? "#FF9F0A" : "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "COOLANT"; color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase }
                        }
                    }
                }

                // Battery
                Rectangle {
                    width: (parent.width - 24) / 5; height: parent.height; radius: 12; color: "#1C1C1E"
                    Column {
                        anchors.centerIn: parent; spacing: 3
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "⚡"; font.pixelSize: 18
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: VehicleService.batteryVolts.toFixed(1) + "V"
                            color: VehicleService.batteryVolts < 11.5 ? "#FF453A"
                                 : VehicleService.batteryVolts < 12.0 ? "#FF9F0A" : "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "BATTERY"; color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase }
                        }
                    }
                }

                // RPM
                Rectangle {
                    width: (parent.width - 24) / 5; height: parent.height; radius: 12; color: "#1C1C1E"
                    Column {
                        anchors.centerIn: parent; spacing: 3
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "⟳"; font.pixelSize: 18
                            color: VehicleService.rpm > 5500 ? "#FF453A" : "#8E8E93"
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: VehicleService.rpm + ""
                            color: VehicleService.rpm > 5500 ? "#FF453A" : "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "RPM"; color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase }
                        }
                    }
                }

                // Oil Life
                Rectangle {
                    width: (parent.width - 24) / 5; height: parent.height; radius: 12; color: "#1C1C1E"
                    Column {
                        anchors.centerIn: parent; spacing: 3
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "🛢"; font.pixelSize: 18
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: VehicleService.oilLife.toFixed(0) + "%"
                            color: VehicleService.oilLife < 15 ? "#FF453A"
                                 : VehicleService.oilLife < 30 ? "#FF9F0A" : "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "OIL LIFE"; color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase }
                        }
                    }
                }

                // Cruise
                Rectangle {
                    width: (parent.width - 24) / 5; height: parent.height; radius: 12; color: "#1C1C1E"
                    Column {
                        anchors.centerIn: parent; spacing: 3
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "◉"; font.pixelSize: 16
                            color: VehicleService.cruiseActive ? "#0A84FF" : "#3A3A3C"
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: VehicleService.cruiseActive
                                ? VehicleService.cruiseSpeed + " MPH" : "—"
                            color: VehicleService.cruiseActive ? "#0A84FF" : "#8E8E93"
                            font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "CRUISE"; color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase }
                        }
                    }
                }
            }
        }

        // ────────────────────────────────────────────────────────────────────
        // TAB 1 — DRIVE MODE
        // ────────────────────────────────────────────────────────────────────
        Item {
            id: tabDrive
            anchors.fill: parent
            visible: root.activeTab === 1

            property var modes: [
                { name: "Standard", icon: "⊙", desc: "Balanced performance" },
                { name: "Sport",    icon: "▲",  desc: "Sharpened throttle + steering" },
                { name: "Sport+",   icon: "▲▲", desc: "Max performance, firm suspension" },
                { name: "Eco",      icon: "⌚", desc: "Maximum fuel efficiency" },
                { name: "Snow",     icon: "❄",  desc: "Low-traction surface mode" },
                { name: "Personal", icon: "⚙",  desc: "Your custom configuration" }
            ]

            // Mode set confirmation toast
            property bool showToast: false
            property string toastText: ""

            // Mode grid
            Grid {
                id: modeGrid
                anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 10 }
                columns: 3; rows: 2
                columnSpacing: 12; rowSpacing: 10

                Repeater {
                    model: tabDrive.modes

                    Rectangle {
                        width: 120; height: 82; radius: 12
                        color: VehicleService.driveMode === index ? "transparent" : "#1C1C1E"
                        border {
                            color: VehicleService.driveMode === index ? "transparent" : "rgba(255,255,255,0.08)"
                            width: 1
                        }

                        // Gradient for active
                        Rectangle {
                            anchors.fill: parent; radius: 12
                            visible: VehicleService.driveMode === index
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#0A84FF" }
                                GradientStop { position: 1.0; color: "rgba(10,132,255,0.6)" }
                            }
                        }

                        Column {
                            anchors.centerIn: parent; spacing: 4
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData.icon
                                font.pixelSize: 22
                                color: "#FFFFFF"
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData.name
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData.desc
                                color: VehicleService.driveMode === index ? "rgba(255,255,255,0.85)" : "#8E8E93"
                                font { family: "Roboto"; pixelSize: 9 }
                                width: 112; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                VehicleService.setDriveMode(index)
                                tabDrive.toastText = "Mode set: " + modelData.name
                                tabDrive.showToast = true
                                toastTimer.restart()
                            }
                        }
                    }
                }
            }

            Timer {
                id: toastTimer
                interval: 1500
                onTriggered: tabDrive.showToast = false
            }

            // Toast confirmation
            Rectangle {
                anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 8 }
                width: toastLabel.width + 32; height: 32; radius: 16
                color: "#0A84FF"
                visible: tabDrive.showToast
                opacity: tabDrive.showToast ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 200 } }

                Text {
                    id: toastLabel
                    anchors.centerIn: parent
                    text: tabDrive.toastText
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                }
            }

            // Personal config panel (shown when Personal mode active)
            Rectangle {
                anchors { top: modeGrid.bottom; left: parent.left; right: parent.right; topMargin: 8; leftMargin: 8; rightMargin: 8 }
                height: 80; radius: 12; color: "#1C1C1E"
                visible: VehicleService.driveMode === 5

                Column {
                    anchors { fill: parent; margins: 8 }
                    spacing: 4

                    Repeater {
                        model: [
                            { label: "Engine/Trans", opts: ["Standard","Sport","Eco"],    prop: "personalEngine" },
                            { label: "Steering",     opts: ["Light","Normal","Heavy"],    prop: "personalSteering" },
                            { label: "Trace Ctrl",   opts: ["Off","Light","Normal"],       prop: "personalTrace" },
                            { label: "Sound Mgmt",   opts: ["Off","Low","High"],           prop: "personalSound" }
                        ]

                        Row {
                            spacing: 6; height: 16

                            Text {
                                text: modelData.label
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 10 }
                                width: 72
                                verticalAlignment: Text.AlignVCenter; height: parent.height
                            }

                            Repeater {
                                model: modelData.opts

                                Rectangle {
                                    height: 16; radius: 8
                                    width: optLabel.width + 12
                                    color: root[modelData.prop] === index ? "#0A84FF" : "#2C2C2E"

                                    Text {
                                        id: optLabel
                                        anchors.centerIn: parent
                                        text: modelData
                                        color: root[modelData.prop] === index ? "#FFFFFF" : "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 9 }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: root[modelData.prop] = index
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ────────────────────────────────────────────────────────────────────
        // TAB 2 — ADAS
        // ────────────────────────────────────────────────────────────────────
        Item {
            id: tabAdas
            anchors.fill: parent
            visible: root.activeTab === 2

            // Header
            Row {
                id: adasHeader
                anchors { top: parent.top; left: parent.left; leftMargin: 12; topMargin: 8 }
                spacing: 8

                Text {
                    text: "Driver Assistance Systems"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                    anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                    height: 20; radius: 4; width: warningBadgeLabel.width + 12
                    color: "#3A2800"
                    border { color: "#FF9F0A"; width: 1 }
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        id: warningBadgeLabel
                        anchors.centerIn: parent
                        text: "⚠ Q50_LIKELY"
                        color: "#FF9F0A"
                        font { family: "Roboto"; pixelSize: 9; weight: Font.SemiBold }
                    }
                }
            }

            // VDC warning banner
            Rectangle {
                id: vdcWarning
                anchors { top: adasHeader.bottom; left: parent.left; right: parent.right; topMargin: 4; leftMargin: 8; rightMargin: 8 }
                height: 28; radius: 8
                color: "#3A2000"
                border { color: "#FF9F0A"; width: 1 }
                visible: !VehicleService.vdcOn

                Text {
                    anchors.centerIn: parent
                    text: "⚠  Disabling VDC reduces stability. Re-enable if traction is lost."
                    color: "#FF9F0A"
                    font { family: "Roboto"; pixelSize: 10 }
                }
            }

            // Toggle columns
            property int toggleGridTop: (vdcWarning.visible ? vdcWarning.y + vdcWarning.height : adasHeader.y + adasHeader.height) + 6

            Row {
                anchors { top: parent.top; topMargin: tabAdas.toggleGridTop; left: parent.left; right: parent.right; leftMargin: 8; rightMargin: 8 }
                spacing: 8

                // Left column
                Column {
                    width: (parent.width - 8) / 2
                    spacing: 0

                    Repeater {
                        model: [
                            { abbr: "BSW",  full: "Blind Spot Warning",             propR: "bswOn", setter: "setBSW" },
                            { abbr: "LDW",  full: "Lane Departure Warning",         propR: "ldwOn", setter: "setLDW" },
                            { abbr: "FEB",  full: "Forward Emergency Braking",      propR: "febOn", setter: "setFEB" },
                            { abbr: "VDC",  full: "Vehicle Dynamic Control",        propR: "vdcOn", setter: "setVDC" }
                        ]

                        Rectangle {
                            width: parent.width; height: 44
                            color: "transparent"

                            Row {
                                anchors { fill: parent; leftMargin: 4; rightMargin: 4 }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 56; spacing: 1

                                    Text {
                                        text: modelData.abbr
                                        color: "#FFFFFF"
                                        font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                                    }
                                    Text {
                                        text: modelData.full
                                        color: "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 10 }
                                    }
                                }

                                // Toggle switch
                                Rectangle {
                                    id: toggleLeft
                                    width: 44; height: 24; radius: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: VehicleService[modelData.propR] ? "#0A84FF" : "#2C2C2E"
                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Rectangle {
                                        id: thumbLeft
                                        width: 20; height: 20; radius: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: VehicleService[modelData.propR] ? 22 : 2
                                        color: "#FFFFFF"
                                        Behavior on x { NumberAnimation { duration: 150 } }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: VehicleService[modelData.setter](!VehicleService[modelData.propR])
                                    }
                                }
                            }

                            Rectangle {
                                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                                height: 1; color: "#2C2C2E"
                            }
                        }
                    }
                }

                // Right column
                Column {
                    width: (parent.width - 8) / 2
                    spacing: 0

                    Repeater {
                        model: [
                            { abbr: "BSI",  full: "Blind Spot Intervention",        propR: "bsiOn", setter: "setBSI" },
                            { abbr: "LDP",  full: "Lane Departure Prevention",      propR: "ldpOn", setter: "setLDP" },
                            { abbr: "BCI",  full: "Back-Up Collision Intervention", propR: "bciOn", setter: "setBCI" },
                            { abbr: "",     full: "",                               propR: "",       setter: "" }
                        ]

                        Rectangle {
                            width: parent.width; height: 44
                            color: "transparent"
                            visible: modelData.abbr !== ""

                            Row {
                                anchors { fill: parent; leftMargin: 4; rightMargin: 4 }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 56; spacing: 1

                                    Text {
                                        text: modelData.abbr
                                        color: "#FFFFFF"
                                        font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                                    }
                                    Text {
                                        text: modelData.full
                                        color: "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 10 }
                                    }
                                }

                                Rectangle {
                                    width: 44; height: 24; radius: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: VehicleService[modelData.propR] ? "#0A84FF" : "#2C2C2E"
                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Rectangle {
                                        width: 20; height: 20; radius: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: VehicleService[modelData.propR] ? 22 : 2
                                        color: "#FFFFFF"
                                        Behavior on x { NumberAnimation { duration: 150 } }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: VehicleService[modelData.setter](!VehicleService[modelData.propR])
                                    }
                                }
                            }

                            Rectangle {
                                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                                height: 1; color: "#2C2C2E"
                            }
                        }
                    }
                }
            }

            // PFCW section
            Rectangle {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right; bottomMargin: 8; leftMargin: 8; rightMargin: 8 }
                height: 52; radius: 12; color: "#1C1C1E"

                Row {
                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "PFCW"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                        width: 44
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Predictive Forward Collision"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 10 }
                        width: 160
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4

                        Repeater {
                            model: ["Off", "Far", "Normal", "Near"]

                            Rectangle {
                                height: 28; radius: 14; width: pfcwLabel.width + 16
                                color: VehicleService.pfcwSensitivity === index ? "#0A84FF" : "#2C2C2E"
                                Behavior on color { ColorAnimation { duration: 150 } }

                                Text {
                                    id: pfcwLabel
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: VehicleService.pfcwSensitivity === index ? "#FFFFFF" : "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 11 }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: VehicleService.setPFCWSensitivity(index)
                                }
                            }
                        }
                    }
                }
            }
        }

        // ────────────────────────────────────────────────────────────────────
        // TAB 3 — ATTESA
        // ────────────────────────────────────────────────────────────────────
        Item {
            id: tabAttesa
            anchors.fill: parent
            visible: root.activeTab === 3

            property bool noData: VehicleService.atessaFront === 0 && VehicleService.atessaRear === 0

            // No-data placeholder
            Text {
                anchors.centerIn: parent
                text: "AWD data available when driving"
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 13 }
                visible: tabAttesa.noData
            }

            // Main visualization
            Item {
                anchors.fill: parent
                visible: !tabAttesa.noData

                // Torque split canvas
                Canvas {
                    id: attesaCanvas
                    anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 8 }
                    width: 320; height: 160

                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)

                        var cx  = width / 2
                        var bodyW = 60; var bodyH = 100
                        var bodyX = cx - bodyW / 2
                        var bodyY = (height - bodyH) / 2

                        // Car body
                        ctx.beginPath()
                        ctx.roundRect(bodyX, bodyY, bodyW, bodyH, 10)
                        ctx.strokeStyle = "rgba(255,255,255,0.25)"
                        ctx.lineWidth = 1.5
                        ctx.stroke()

                        // Front axle line
                        var frontY = bodyY + 22
                        ctx.beginPath()
                        ctx.moveTo(cx - 90, frontY)
                        ctx.lineTo(cx + 90, frontY)
                        ctx.strokeStyle = "rgba(255,255,255,0.15)"
                        ctx.lineWidth = 1; ctx.stroke()

                        // Rear axle line
                        var rearY = bodyY + bodyH - 22
                        ctx.beginPath()
                        ctx.moveTo(cx - 90, rearY)
                        ctx.lineTo(cx + 90, rearY)
                        ctx.strokeStyle = "rgba(255,255,255,0.15)"
                        ctx.lineWidth = 1; ctx.stroke()

                        // Driveshaft
                        ctx.beginPath()
                        ctx.moveTo(cx, frontY)
                        ctx.lineTo(cx, rearY)
                        ctx.strokeStyle = "rgba(255,255,255,0.1)"
                        ctx.lineWidth = 2; ctx.stroke()

                        // Wheel dots
                        var wheels = [
                            {x: cx-90, y: frontY},
                            {x: cx+90, y: frontY},
                            {x: cx-90, y: rearY},
                            {x: cx+90, y: rearY}
                        ]
                        wheels.forEach(function(w) {
                            ctx.beginPath()
                            ctx.arc(w.x, w.y, 7, 0, Math.PI * 2)
                            ctx.fillStyle = "#2C2C2E"
                            ctx.fill()
                            ctx.strokeStyle = "rgba(255,255,255,0.3)"
                            ctx.lineWidth = 1.5; ctx.stroke()
                        })

                        // Front torque arc (blue)
                        var fPct = VehicleService.atessaFront / 100
                        if (fPct > 0) {
                            var fSweep = fPct * Math.PI * 1.2
                            ctx.beginPath()
                            ctx.arc(cx, frontY, 36, -Math.PI/2 - fSweep/2, -Math.PI/2 + fSweep/2, false)
                            ctx.strokeStyle = "#0A84FF"
                            ctx.lineWidth = 6; ctx.lineCap = "round"; ctx.stroke()
                        }

                        // Rear torque arc (amber)
                        var rPct = VehicleService.atessaRear / 100
                        if (rPct > 0) {
                            var rSweep = rPct * Math.PI * 1.2
                            ctx.beginPath()
                            ctx.arc(cx, rearY, 36, -Math.PI/2 - rSweep/2, -Math.PI/2 + rSweep/2, false)
                            ctx.strokeStyle = "#FF9F0A"
                            ctx.lineWidth = 6; ctx.lineCap = "round"; ctx.stroke()
                        }
                    }

                    Connections {
                        target: VehicleService
                        function onAtessaChanged() { attesaCanvas.requestPaint() }
                    }
                    Component.onCompleted: requestPaint()
                }

                // Front/Rear stat badges
                Row {
                    anchors { top: attesaCanvas.bottom; horizontalCenter: parent.horizontalCenter; topMargin: 8 }
                    spacing: 24

                    Rectangle {
                        width: 110; height: 48; radius: 12; color: "#1C1C1E"
                        Column {
                            anchors.centerIn: parent; spacing: 2
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: VehicleService.atessaFront.toFixed(0) + "%"
                                color: "#0A84FF"
                                font { family: "Roboto"; pixelSize: 20; weight: Font.Bold }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "FRONT"
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                            }
                        }
                    }

                    Rectangle {
                        width: 110; height: 48; radius: 12; color: "#1C1C1E"
                        Column {
                            anchors.centerIn: parent; spacing: 2
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: VehicleService.atessaRear.toFixed(0) + "%"
                                color: "#FF9F0A"
                                font { family: "Roboto"; pixelSize: 20; weight: Font.Bold }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "REAR"
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                            }
                        }
                    }
                }

                // Sparkline
                Rectangle {
                    anchors { bottom: parent.bottom; left: parent.left; right: parent.right; bottomMargin: 8; leftMargin: 8; rightMargin: 8 }
                    height: 56; radius: 12; color: "#1C1C1E"

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 6; leftMargin: 10 }
                        text: "Split History"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                    }

                    Canvas {
                        id: attesaSparkline
                        anchors { fill: parent; topMargin: 18; leftMargin: 8; rightMargin: 8; bottomMargin: 6 }

                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var h = root.atessaHistory
                            if (h.length < 2) return

                            ctx.beginPath()
                            for (var i = 0; i < h.length; i++) {
                                var x = (i / (h.length - 1)) * width
                                var y = height - (h[i] / 100) * height
                                if (i === 0) ctx.moveTo(x, y)
                                else ctx.lineTo(x, y)
                            }
                            ctx.strokeStyle = "#0A84FF"
                            ctx.lineWidth = 1.5
                            ctx.stroke()
                        }
                    }
                }
            }
        }

        // ────────────────────────────────────────────────────────────────────
        // TAB 4 — DIAG
        // ────────────────────────────────────────────────────────────────────
        Item {
            id: tabDiag
            anchors.fill: parent
            visible: root.activeTab === 4

            Flickable {
                anchors.fill: parent
                contentHeight: diagColumn.height + 16
                clip: true

                Column {
                    id: diagColumn
                    anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 8; leftMargin: 8; rightMargin: 8 }
                    spacing: 4

                    // Helper component: diag row
                    component DiagRow: Rectangle {
                        property alias rowContent: innerRow.children
                        width: parent ? parent.width : 0
                        height: 30; radius: 8; color: "#1C1C1E"
                        Row {
                            id: innerRow
                            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                            spacing: 16
                        }
                    }

                    // Row 1: Gear | Rev | Brake | P-Brake
                    Rectangle {
                        width: parent.width; height: 30; radius: 8; color: "#1C1C1E"
                        Row {
                            anchors { fill: parent; leftMargin: 10 }
                            spacing: 20

                            DiagCell { label: "Gear"; value: VehicleService.gearPosition }
                            DiagCell { label: "Rev";   value: VehicleService.reverseOn ? "●" : "○"; valColor: VehicleService.reverseOn ? "#0A84FF" : "#8E8E93" }
                            DiagCell { label: "Brake"; value: VehicleService.brakePressed ? "●" : "○"; valColor: VehicleService.brakePressed ? "#FF453A" : "#8E8E93" }
                            DiagCell { label: "P-Brake"; value: VehicleService.parkingBrake ? "●" : "○"; valColor: VehicleService.parkingBrake ? "#FF453A" : "#8E8E93" }
                        }
                    }

                    // Row 2: Speed | RPM | Steer
                    Rectangle {
                        width: parent.width; height: 30; radius: 8; color: "#1C1C1E"
                        Row {
                            anchors { fill: parent; leftMargin: 10 }
                            spacing: 20

                            DiagCell { label: "Speed"; value: VehicleService.speed.toFixed(1) + " mph" }
                            DiagCell { label: "RPM";   value: VehicleService.rpm.toString() }
                            DiagCell { label: "Steer"; value: (VehicleService.steeringAngle >= 0 ? "+" : "") + VehicleService.steeringAngle.toFixed(1) + "°" }
                        }
                    }

                    // Row 3: Outside Temp | Coolant | Battery
                    Rectangle {
                        width: parent.width; height: 30; radius: 8; color: "#1C1C1E"
                        Row {
                            anchors { fill: parent; leftMargin: 10 }
                            spacing: 20

                            DiagCell { label: "Out Temp"; value: VehicleService.outsideTemp.toFixed(0) + "°F" }
                            DiagCell { label: "Coolant";  value: VehicleService.coolantTemp.toFixed(0) + "°F" }
                            DiagCell { label: "Battery";  value: VehicleService.batteryVolts.toFixed(1) + "V" }
                        }
                    }

                    // Row 4: Ignition | Cruise
                    Rectangle {
                        width: parent.width; height: 30; radius: 8; color: "#1C1C1E"
                        Row {
                            anchors { fill: parent; leftMargin: 10 }
                            spacing: 20

                            DiagCell { label: "Ignition"; value: VehicleService.ignitionOn ? "ON" : "OFF"; valColor: VehicleService.ignitionOn ? "#30D158" : "#8E8E93" }
                            DiagCell {
                                label: "Cruise"
                                value: VehicleService.cruiseActive ? ("ACTIVE " + VehicleService.cruiseSpeed) : "OFF"
                                valColor: VehicleService.cruiseActive ? "#0A84FF" : "#8E8E93"
                            }
                        }
                    }

                    // Row 5: Doors
                    Rectangle {
                        width: parent.width; height: 30; radius: 8; color: "#1C1C1E"
                        Row {
                            anchors { fill: parent; leftMargin: 10 }
                            spacing: 12

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Doors:"
                                color: "#8E8E93"; font { family: "Roboto"; pixelSize: 10 }
                            }

                            Repeater {
                                model: [
                                    { lbl: "FL", val: VehicleService.doorDriver },
                                    { lbl: "FR", val: VehicleService.doorPassenger },
                                    { lbl: "RL", val: VehicleService.doorRearLeft },
                                    { lbl: "RR", val: VehicleService.doorRearRight },
                                    { lbl: "TR", val: VehicleService.trunkOpen }
                                ]

                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 3
                                    Text { text: modelData.lbl; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 10 } }
                                    Text { text: modelData.val ? "●" : "○"; color: modelData.val ? "#FF453A" : "#30D158"; font.pixelSize: 10 }
                                }
                            }
                        }
                    }

                    // Row 6: Wipers | Rear Defrost
                    Rectangle {
                        width: parent.width; height: 30; radius: 8; color: "#1C1C1E"
                        Row {
                            anchors { fill: parent; leftMargin: 10 }
                            spacing: 20

                            DiagCell { label: "Wipers"; value: VehicleService.wiperState }
                            DiagCell { label: "R.Defrost"; value: VehicleService.rearDefrostOn ? "ON" : "OFF"; valColor: VehicleService.rearDefrostOn ? "#30D158" : "#8E8E93" }
                        }
                    }

                    // Row 7: ADAS flags
                    Rectangle {
                        width: parent.width; height: 30; radius: 8; color: "#1C1C1E"
                        Row {
                            anchors { fill: parent; leftMargin: 10 }
                            spacing: 12

                            Repeater {
                                model: [
                                    { lbl: "BSW", val: VehicleService.bswOn },
                                    { lbl: "LDW", val: VehicleService.ldwOn },
                                    { lbl: "FEB", val: VehicleService.febOn },
                                    { lbl: "BCI", val: VehicleService.bciOn },
                                    { lbl: "VDC", val: VehicleService.vdcOn }
                                ]

                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 3
                                    Text { text: modelData.lbl; color: "#8E8E93"; font { family: "Roboto"; pixelSize: 10 } }
                                    Text {
                                        text: modelData.val ? "ON" : "OFF"
                                        color: modelData.val ? "#30D158" : "#FF453A"
                                        font { family: "Roboto"; pixelSize: 10; weight: Font.SemiBold }
                                    }
                                }
                            }
                        }
                    }

                    // Button Log
                    Rectangle {
                        width: parent.width; radius: 8; color: "#1C1C1E"
                        height: 14 + (buttonLogRepeater.count * 18) + 8

                        Text {
                            anchors { top: parent.top; left: parent.left; topMargin: 6; leftMargin: 10 }
                            text: "Button Log"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }

                        Column {
                            anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 20; leftMargin: 10 }
                            spacing: 0

                            Repeater {
                                id: buttonLogRepeater
                                model: root.buttonLog

                                Text {
                                    text: modelData
                                    color: "#FFFFFF"
                                    font { family: "Roboto"; pixelSize: 11 }
                                    height: 18
                                }
                            }

                            Text {
                                visible: root.buttonLog.length === 0
                                text: "No button events yet"
                                color: "#3A3A3C"
                                font { family: "Roboto"; pixelSize: 11 }
                                height: 18
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Inline DiagCell component ─────────────────────────────────────────────
    component DiagCell: Row {
        property string label: ""
        property string value: "—"
        property color  valColor: "#FFFFFF"

        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: label + ":"
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 10 }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: value
            color: valColor
            font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold }
        }
    }
}
