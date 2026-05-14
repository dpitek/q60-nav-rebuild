// VehicleStatusView.qml — Vehicle information center
// 6 sub-tabs: Info | Drive | ADAS | ATTESA | Diag | Track
// Content area: 800×360 (800×420 minus 60px nav bar)
import QtQuick 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    // ── Background ─────────────────────────────────────────────────────────────
    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Sub-tab state ──────────────────────────────────────────────────────────
    property int activeTab: 0   // 0=Info 1=Drive 2=ADAS 3=ATTESA 4=Diag 5=Track

    // ── Drive-mode personal config (Q60 "Personal" mode 5-axis tuning) ────────
    // Loaded from SettingsService.driveModePersonalConfig (JSON) on construction;
    // changes are persisted back as JSON via setDriveModePersonalConfig().
    //
    // Each is 0-2 (Soft / Normal / Sport). Matches what the factory UI exposes.
    property int personalThrottle:    1   // 0=Std 1=Sport 2=Eco — engine/trans response
    property int personalSteering:    1   // 0=Light 1=Normal 2=Heavy
    property int personalTrace:       2   // 0=Off 1=Light 2=Normal — Active Trace Ctrl
    property int personalEngineBrake: 1   // 0=Off 1=Light 2=Normal — Active Engine Brake
    property int personalASM:         0   // 0=Off 1=Low 2=High — Active Sound Mgmt

    // Apply config JSON → properties. Empty/invalid resets to compiled defaults.
    function _applyPersonalConfig(jsonStr) {
        if (!jsonStr) return
        try {
            var p = JSON.parse(jsonStr)
            if (p && typeof p === "object") {
                if ("throttle"    in p) root.personalThrottle    = p.throttle
                if ("steering"    in p) root.personalSteering    = p.steering
                if ("trace"       in p) root.personalTrace       = p.trace
                if ("engineBrake" in p) root.personalEngineBrake = p.engineBrake
                if ("asm"         in p) root.personalASM         = p.asm
            }
        } catch (e) {
            console.warn("VehicleStatusView: malformed driveModePersonalConfig JSON:", e)
        }
    }

    // ── ADAS safety: long-press-to-disable + tap-to-enable ────────────────────
    // Tap to ENABLE a safety aid: fires immediately.
    // To DISABLE a safety aid: hold 2 seconds. We surface a small toast that
    // shows the running countdown; releasing early aborts.
    //
    // Pattern matches the existing UDS door-lock warning style — we never silently
    // disable a safety system on a careless tap.
    property string adasHoldLabel: ""        // label being held; "" = idle
    property real   adasHoldProgress: 0.0    // 0.0–1.0

    function _fireAdasToggle(setter, currVal) {
        // Enable: instant. Disable: must come via the 2-sec hold path; bare
        // taps that try to disable are ignored here.
        if (!currVal) {
            // currently OFF → turning ON, fire immediately
            VehicleService[setter](true)
            return true
        }
        return false   // disable not honored on a quick tap
    }

    function _persistPersonalConfig() {
        var p = {
            throttle:    root.personalThrottle,
            steering:    root.personalSteering,
            trace:       root.personalTrace,
            engineBrake: root.personalEngineBrake,
            asm:         root.personalASM
        }
        SettingsService.driveModePersonalConfig = JSON.stringify(p)
    }

    Component.onCompleted: {
        _applyPersonalConfig(SettingsService.driveModePersonalConfig)
    }

    Connections {
        target: SettingsService
        function onDriveModePersonalConfigChanged() {
            root._applyPersonalConfig(SettingsService.driveModePersonalConfig)
        }
    }

    // ── Vehicle body config ────────────────────────────────────────────────────
    // Q60 is a 2-door coupe. Set true when VIN detection identifies a 4-door model.
    property bool fourDoorModel:   false

    // ── Button log (last 5 entries) ────────────────────────────────────────────
    property var buttonLog: []

    // ── ATTESA history (240 samples × 250ms = 60s scrolling window) ────────────
    // Sampled by a 250ms QML Timer rather than only the atessaChanged signal so
    // the sparkline has uniform spacing even when the CAN frame stutters.
    property var atessaHistory: []
    readonly property int atessaHistoryMax: 240

    // Session-best peak front-bias.  Reset on app start; not persisted.
    property real atessaMaxFront: 0.0

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
            // Track session peak — fires on every CAN frame so we never miss a spike,
            // even between the 250ms history samples below.
            var f = VehicleService.atessaFront
            if (f > root.atessaMaxFront) root.atessaMaxFront = f
            if (attesaCanvas.visible) attesaCanvas.requestPaint()
        }
    }

    // 250ms ATTESA sampler — uniform spacing for the 60s sparkline window.
    Timer {
        interval: 250
        running: root.activeTab === 3   // only sample while ATTESA tab visible
        repeat: true
        onTriggered: {
            var h = root.atessaHistory.slice()
            h.push(VehicleService.atessaFront)
            if (h.length > root.atessaHistoryMax) h.shift()
            root.atessaHistory = h
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
                model: ["Info", "Drive", "ADAS", "ATTESA", "Diag", "Track"]

                Rectangle {
                    width: 116; height: 36; radius: 18
                    color: root.activeTab === index ? "#0A84FF" : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: 150 }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: root.activeTab === index ? "#FFFFFF" : "#8E8E93"
                        font { family: "Roboto"; pixelSize: 13; weight: 600 }
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

                // ── TPMS Card — Q60 coupe rendering, PSI outside wheels ──────
                Rectangle {
                    id: tpmsCard
                    width: 364; height: 160; radius: 16
                    color: "#1C1C1E"

                    // Helper functions
                    function psiColor(psi) {
                        if (psi <= 0.0) return "#8E8E93"
                        if (psi < 25)   return "#FF453A"
                        if (psi < 30)   return "#FF9F0A"
                        return "#30D158"
                    }
                    function psiText(psi) { return psi <= 0.0 ? "—" : psi.toFixed(0) }

                    Text {
                        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 6 }
                        text: "TIRES"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                    }

                    // ── Q60 coupe top-down silhouette ─────────────────────────
                    Canvas {
                        id: coupeCanvas
                        width: 108; height: 124
                        anchors { centerIn: parent; verticalCenterOffset: 4 }

                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var cx = width / 2, cy = height / 2
                            var bW = 42, bH = 96
                            var bx = cx - bW / 2, by = cy - bH / 2

                            // Body outline — coupe proportions (longer hood, tapered rear)
                            ctx.beginPath()
                            ctx.moveTo(cx, by)
                            ctx.bezierCurveTo(cx + 9, by, bx + bW, by + 10, bx + bW, by + 18)
                            ctx.lineTo(bx + bW, by + bH - 20)
                            ctx.bezierCurveTo(bx + bW, by + bH - 10, cx + 8, by + bH, cx, by + bH)
                            ctx.bezierCurveTo(cx - 8, by + bH, bx, by + bH - 10, bx, by + bH - 20)
                            ctx.lineTo(bx, by + 18)
                            ctx.bezierCurveTo(bx, by + 10, cx - 9, by, cx, by)
                            ctx.closePath()
                            ctx.fillStyle = "#2C2C2E"
                            ctx.fill()
                            ctx.strokeStyle = "rgba(255,255,255,0.22)"
                            ctx.lineWidth = 1.5; ctx.stroke()

                            // Windshield (raked — Q60 characteristic)
                            ctx.beginPath()
                            ctx.moveTo(cx - 15, by + 18)
                            ctx.lineTo(cx + 15, by + 18)
                            ctx.lineTo(cx + 13, by + 35)
                            ctx.lineTo(cx - 13, by + 35)
                            ctx.closePath()
                            ctx.fillStyle = "rgba(80,150,215,0.3)"
                            ctx.fill()

                            // Roof panel
                            ctx.beginPath()
                            ctx.moveTo(cx - 13, by + 35)
                            ctx.lineTo(cx + 13, by + 35)
                            ctx.lineTo(cx + 10, by + bH - 32)
                            ctx.lineTo(cx - 10, by + bH - 32)
                            ctx.closePath()
                            ctx.fillStyle = "#181818"
                            ctx.fill()

                            // Rear window (fastback — shallow angle)
                            ctx.beginPath()
                            ctx.moveTo(cx - 10, by + bH - 32)
                            ctx.lineTo(cx + 10, by + bH - 32)
                            ctx.lineTo(cx + 7,  by + bH - 20)
                            ctx.lineTo(cx - 7,  by + bH - 20)
                            ctx.closePath()
                            ctx.fillStyle = "rgba(80,150,215,0.22)"
                            ctx.fill()

                            // Side mirrors (Q60 prominent mirrors)
                            ctx.beginPath(); ctx.arc(bx - 4, by + 23, 3.5, 0, Math.PI * 2)
                            ctx.fillStyle = "rgba(255,255,255,0.28)"; ctx.fill()
                            ctx.beginPath(); ctx.arc(bx + bW + 4, by + 23, 3.5, 0, Math.PI * 2)
                            ctx.fillStyle = "rgba(255,255,255,0.28)"; ctx.fill()
                        }
                    }

                    // ── FL — top-left ─────────────────────────────────────────
                    Column {
                        anchors { left: parent.left; top: parent.top; leftMargin: 10; topMargin: 22 }
                        spacing: 3

                        Text { text: "FL"; color: "#636366"; font { family: "Roboto"; pixelSize: 9; weight: 600 } }
                        Row {
                            spacing: 5
                            Rectangle {
                                width: 14; height: 14; radius: 7
                                anchors.verticalCenter: parent.verticalCenter
                                color: tpmsCard.psiColor(VehicleService.tirePSI_FL)
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: tpmsCard.psiText(VehicleService.tirePSI_FL)
                                color: tpmsCard.psiColor(VehicleService.tirePSI_FL)
                                font { family: "Roboto"; pixelSize: 16; weight: 700 }
                            }
                        }
                        Text { text: "psi"; color: "#636366"; font { family: "Roboto"; pixelSize: 9 } }
                    }

                    // ── FR — top-right ────────────────────────────────────────
                    Column {
                        anchors { right: parent.right; top: parent.top; rightMargin: 10; topMargin: 22 }
                        spacing: 3

                        Text { text: "FR"; color: "#636366"; font { family: "Roboto"; pixelSize: 9; weight: 600 } }
                        Row {
                            spacing: 5
                            Rectangle {
                                width: 14; height: 14; radius: 7
                                anchors.verticalCenter: parent.verticalCenter
                                color: tpmsCard.psiColor(VehicleService.tirePSI_FR)
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: tpmsCard.psiText(VehicleService.tirePSI_FR)
                                color: tpmsCard.psiColor(VehicleService.tirePSI_FR)
                                font { family: "Roboto"; pixelSize: 16; weight: 700 }
                            }
                        }
                        Text { text: "psi"; color: "#636366"; font { family: "Roboto"; pixelSize: 9 } }
                    }

                    // ── RL — bottom-left ──────────────────────────────────────
                    Column {
                        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 10; bottomMargin: 12 }
                        spacing: 3

                        Row {
                            spacing: 5
                            Rectangle {
                                width: 14; height: 14; radius: 7
                                anchors.verticalCenter: parent.verticalCenter
                                color: tpmsCard.psiColor(VehicleService.tirePSI_RL)
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: tpmsCard.psiText(VehicleService.tirePSI_RL)
                                color: tpmsCard.psiColor(VehicleService.tirePSI_RL)
                                font { family: "Roboto"; pixelSize: 16; weight: 700 }
                            }
                        }
                        Text { text: "psi"; color: "#636366"; font { family: "Roboto"; pixelSize: 9 } }
                        Text { text: "RL"; color: "#636366"; font { family: "Roboto"; pixelSize: 9; weight: 600 } }
                    }

                    // ── RR — bottom-right ─────────────────────────────────────
                    Column {
                        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 10; bottomMargin: 12 }
                        spacing: 3

                        Row {
                            spacing: 5
                            Rectangle {
                                width: 14; height: 14; radius: 7
                                anchors.verticalCenter: parent.verticalCenter
                                color: tpmsCard.psiColor(VehicleService.tirePSI_RR)
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: tpmsCard.psiText(VehicleService.tirePSI_RR)
                                color: tpmsCard.psiColor(VehicleService.tirePSI_RR)
                                font { family: "Roboto"; pixelSize: 16; weight: 700 }
                            }
                        }
                        Text { text: "psi"; color: "#636366"; font { family: "Roboto"; pixelSize: 9 } }
                        Text { text: "RR"; color: "#636366"; font { family: "Roboto"; pixelSize: 9; weight: 600 } }
                    }
                }

                // ── Doors + Fuel Card — 2-door coupe by default ───────────────
                Rectangle {
                    id: doorFuelCard
                    width: 240; height: 160; radius: 16
                    color: "#1C1C1E"

                    // Door section (top ~112px)
                    Item {
                        id: doorSection
                        anchors { top: parent.top; left: parent.left; right: parent.right
                                  bottom: doorFuelDivider.top; topMargin: 6 }

                        Text {
                            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter }
                            text: "DOORS"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }

                        function doorOn(open)  { return open ? "#FF453A" : "#30D158" }
                        function doorOff(open) { return open ? "#FF453A" : "#2C2C2E" }

                        // Car body (coupe — centered)
                        Rectangle {
                            id: doorCarBody
                            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 16 }
                            width: 36
                            height: root.fourDoorModel ? 72 : 54
                            radius: 6; color: "#2C2C2E"
                            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }
                            Behavior on height { NumberAnimation { duration: 200 } }
                        }

                        // FL door (driver — left side)
                        Rectangle {
                            x: 70; y: 16
                            width: 24; height: root.fourDoorModel ? 30 : 38; radius: 4
                            color: doorSection.doorOff(VehicleService.doorDriver)
                            border { color: doorSection.doorOn(VehicleService.doorDriver); width: 1.5 }
                            Behavior on color { ColorAnimation { duration: 100 } }
                            Text { anchors.centerIn: parent; text: "FL"; color: "#FFFFFF"; font { pixelSize: 8; weight: 700 } }
                        }

                        // FR door (passenger — right side)
                        Rectangle {
                            x: 148; y: 16
                            width: 24; height: root.fourDoorModel ? 30 : 38; radius: 4
                            color: doorSection.doorOff(VehicleService.doorPassenger)
                            border { color: doorSection.doorOn(VehicleService.doorPassenger); width: 1.5 }
                            Behavior on color { ColorAnimation { duration: 100 } }
                            Text { anchors.centerIn: parent; text: "FR"; color: "#FFFFFF"; font { pixelSize: 8; weight: 700 } }
                        }

                        // RL door — 4-door only
                        Rectangle {
                            x: 70; y: 50
                            width: 24; height: 26; radius: 4
                            visible: root.fourDoorModel
                            color: doorSection.doorOff(VehicleService.doorRearLeft)
                            border { color: doorSection.doorOn(VehicleService.doorRearLeft); width: 1.5 }
                            Behavior on color { ColorAnimation { duration: 100 } }
                            Text { anchors.centerIn: parent; text: "RL"; color: "#FFFFFF"; font { pixelSize: 8; weight: 700 } }
                        }

                        // RR door — 4-door only
                        Rectangle {
                            x: 148; y: 50
                            width: 24; height: 26; radius: 4
                            visible: root.fourDoorModel
                            color: doorSection.doorOff(VehicleService.doorRearRight)
                            border { color: doorSection.doorOn(VehicleService.doorRearRight); width: 1.5 }
                            Behavior on color { ColorAnimation { duration: 100 } }
                            Text { anchors.centerIn: parent; text: "RR"; color: "#FFFFFF"; font { pixelSize: 8; weight: 700 } }
                        }

                        // Trunk (hatch bar below body)
                        Rectangle {
                            anchors { top: doorCarBody.bottom; horizontalCenter: parent.horizontalCenter; topMargin: 3 }
                            width: 30; height: 10; radius: 2
                            color: doorSection.doorOff(VehicleService.trunkOpen)
                            border { color: doorSection.doorOn(VehicleService.trunkOpen); width: 1.5 }
                            Behavior on color { ColorAnimation { duration: 100 } }
                            Text { anchors.centerIn: parent; text: "TR"; color: "#FFFFFF"; font { pixelSize: 7; weight: 700 } }
                        }
                    }

                    Rectangle {
                        id: doorFuelDivider
                        anchors { left: parent.left; right: parent.right; bottom: oilLifeSection.top }
                        height: 1; color: "#2C2C2E"
                    }

                    // Oil-life circular gauge (replaces fuel bar — no fuelLevel CAN PID
                    // is plumbed yet, but oil life is and the scope asks for a gauge).
                    Item {
                        id: oilLifeSection
                        anchors { bottom: parent.bottom; left: parent.left; right: parent.right
                                  leftMargin: 10; rightMargin: 10 }
                        height: 42

                        function oilColor(pct) {
                            return pct >= 40 ? "#30D158"
                                 : pct >= 15 ? "#FF9F0A" : "#FF453A"
                        }

                        Text {
                            id: oilWordLabel
                            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                            text: "OIL"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }

                        // Circular gauge — Canvas (no roundRect; bezier/arc OK)
                        Canvas {
                            id: oilGauge
                            anchors {
                                left: oilWordLabel.right; verticalCenter: parent.verticalCenter
                                leftMargin: 8
                            }
                            width: 36; height: 36

                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                var cx = width / 2, cy = height / 2, r = 14
                                var pct = Math.max(0, Math.min(100, VehicleService.oilLife))

                                // Track
                                ctx.beginPath()
                                ctx.arc(cx, cy, r, 0, Math.PI * 2)
                                ctx.strokeStyle = "#2C2C2E"; ctx.lineWidth = 4
                                ctx.stroke()

                                // Progress arc
                                ctx.beginPath()
                                var start = -Math.PI / 2
                                var end   = start + (pct / 100) * Math.PI * 2
                                ctx.arc(cx, cy, r, start, end, false)
                                ctx.strokeStyle = oilLifeSection.oilColor(pct)
                                ctx.lineWidth = 4
                                ctx.lineCap = "round"
                                ctx.stroke()
                            }

                            Connections {
                                target: VehicleService
                                function onOilLifeChanged() { oilGauge.requestPaint() }
                            }
                            Component.onCompleted: requestPaint()
                        }

                        Text {
                            anchors { left: oilGauge.right; verticalCenter: parent.verticalCenter; leftMargin: 6 }
                            text: VehicleService.oilLife.toFixed(0) + "%"
                            color: oilLifeSection.oilColor(VehicleService.oilLife)
                            font { family: "Roboto"; pixelSize: 13; weight: 600 }
                        }

                        Text {
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                            text: "life"
                            color: "#636366"
                            font { family: "Roboto"; pixelSize: 10 }
                        }
                    }
                }
            }

            // ── Middle row: Trip Computer with A/B tabs ──────────────────────
            // Tabs let the user pick A or B; selected trip drives the stat row +
            // live instantaneous-MPG bar (sampled from VehicleService.instantMPG).
            Rectangle {
                id: tripComputer
                anchors { top: infoTopRow.bottom; left: parent.left; right: parent.right; topMargin: 8; leftMargin: 8; rightMargin: 8 }
                height: 72; radius: 16; color: "#1C1C1E"

                // 0 = Trip A, 1 = Trip B
                property int activeTrip: 0

                function fmtTime(secs) {
                    if (!secs || secs <= 0) return "—"
                    var h = Math.floor(secs / 3600)
                    var m = Math.floor((secs % 3600) / 60)
                    return h > 0 ? (h + "h" + (m < 10 ? "0" : "") + m + "m")
                                 : (m + "m")
                }

                // Tab strip on the left
                Column {
                    id: tripTabCol
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom; leftMargin: 8; topMargin: 6; bottomMargin: 6 }
                    width: 50
                    spacing: 4

                    Repeater {
                        model: ["A", "B"]

                        Rectangle {
                            width: parent.width
                            height: (tripComputer.height - 12 - 4) / 2
                            radius: 8
                            color: tripComputer.activeTrip === index ? "#0A84FF" : "#2C2C2E"
                            Behavior on color { ColorAnimation { duration: 120 } }

                            Text {
                                anchors.centerIn: parent
                                text: "TRIP " + modelData
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 10; weight: 600 }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: tripComputer.activeTrip = index
                            }
                        }
                    }
                }

                // Stat columns — distance / avg MPG / avg speed / elapsed time
                Row {
                    anchors { left: tripTabCol.right; right: tripResetBtn.left;
                              top: parent.top; bottom: tripMpgBar.top;
                              leftMargin: 8; rightMargin: 8; topMargin: 4 }
                    spacing: 0

                    // Each cell takes 1/4 of available width
                    Item {
                        width: parent.width / 4; height: parent.height
                        Column {
                            anchors.centerIn: parent; spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: (tripComputer.activeTrip === 0 ? VehicleService.tripAMiles : VehicleService.tripBMiles).toFixed(1)
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 14; weight: 600 }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "mi"
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 9 }
                            }
                        }
                    }
                    Item {
                        width: parent.width / 4; height: parent.height
                        Column {
                            anchors.centerIn: parent; spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: {
                                    var v = tripComputer.activeTrip === 0 ? VehicleService.tripAAvgMPG : VehicleService.tripBAvgMPG
                                    return v > 0 ? v.toFixed(1) : "—"
                                }
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 14; weight: 600 }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "avg MPG"
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 9 }
                            }
                        }
                    }
                    Item {
                        width: parent.width / 4; height: parent.height
                        Column {
                            anchors.centerIn: parent; spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: {
                                    var v = tripComputer.activeTrip === 0 ? VehicleService.tripAAvgSpeed : VehicleService.tripBAvgSpeed
                                    return v > 0 ? v.toFixed(0) : "—"
                                }
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 14; weight: 600 }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "avg mph"
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 9 }
                            }
                        }
                    }
                    Item {
                        width: parent.width / 4; height: parent.height
                        Column {
                            anchors.centerIn: parent; spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: tripComputer.fmtTime(tripComputer.activeTrip === 0 ? VehicleService.tripASeconds : VehicleService.tripBSeconds)
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 14; weight: 600 }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "elapsed"
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 9 }
                            }
                        }
                    }
                }

                // Reset button (right edge) — resets the currently-selected trip.
                Rectangle {
                    id: tripResetBtn
                    anchors { right: parent.right; top: parent.top; rightMargin: 8; topMargin: 6 }
                    width: 36; height: 22; radius: 6
                    color: "#2C2C2E"

                    Text {
                        anchors.centerIn: parent
                        text: "RESET"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 8; weight: 600; letterSpacing: 0.5 }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (tripComputer.activeTrip === 0) VehicleService.resetTripA()
                            else                                VehicleService.resetTripB()
                        }
                    }
                }

                // Live instantaneous-MPG bar at the bottom of the card.
                Item {
                    id: tripMpgBar
                    anchors { left: tripTabCol.right; right: parent.right;
                              bottom: parent.bottom;
                              leftMargin: 8; rightMargin: 12; bottomMargin: 6 }
                    height: 12

                    function mpgColor(v) {
                        return v > 25 ? "#30D158" : v > 15 ? "#FF9F0A" : "#FF453A"
                    }

                    Text {
                        id: mpgLabel
                        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                        text: "inst"
                        color: "#636366"
                        font { family: "Roboto"; pixelSize: 9 }
                    }

                    Rectangle {
                        anchors { left: mpgLabel.right; right: mpgValue.left;
                                  verticalCenter: parent.verticalCenter;
                                  leftMargin: 6; rightMargin: 6 }
                        height: 5; radius: 3; color: "#2C2C2E"

                        // Fill — cap at 40 MPG for the bar scale (typical Q60 ceiling)
                        Rectangle {
                            width: parent.width * Math.min(1.0, Math.max(0.0, VehicleService.instantMPG / 40))
                            height: parent.height; radius: 3
                            color: tripMpgBar.mpgColor(VehicleService.instantMPG)
                            Behavior on width { NumberAnimation { duration: 250 } }
                        }
                    }

                    Text {
                        id: mpgValue
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        text: VehicleService.instantMPG > 0 ? VehicleService.instantMPG.toFixed(1) + " MPG" : "— MPG"
                        color: tripMpgBar.mpgColor(VehicleService.instantMPG)
                        font { family: "Roboto"; pixelSize: 9; weight: 600 }
                    }
                }
            }

            // ── Bottom row: 5 stat badges ─────────────────────────────────────
            Row {
                id: statBadgeRow
                anchors { top: tripComputer.bottom; left: parent.left; right: parent.right; topMargin: 6; leftMargin: 8; rightMargin: 8 }
                spacing: 6
                height: 62

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
                            font { family: "Roboto"; pixelSize: 12; weight: 600 }
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
                            font { family: "Roboto"; pixelSize: 12; weight: 600 }
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
                            font { family: "Roboto"; pixelSize: 12; weight: 600 }
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
                            font { family: "Roboto"; pixelSize: 12; weight: 600 }
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
                            font { family: "Roboto"; pixelSize: 12; weight: 600 }
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
                            color: VehicleService.driveMode === index ? "transparent" : Qt.rgba(1, 1, 1, 0.08)
                            width: 1
                        }

                        // Gradient for active
                        Rectangle {
                            anchors.fill: parent; radius: 12
                            visible: VehicleService.driveMode === index
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#0A84FF" }
                                GradientStop { position: 1.0; color: Qt.rgba(0.0392, 0.5176, 1, 0.6) }
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
                                font { family: "Roboto"; pixelSize: 13; weight: 600 }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData.desc
                                color: VehicleService.driveMode === index ? Qt.rgba(1, 1, 1, 0.85) : "#8E8E93"
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
                    font { family: "Roboto"; pixelSize: 12; weight: 600 }
                }
            }

            // Personal config panel (shown when Personal mode active)
            Rectangle {
                anchors { top: modeGrid.bottom; left: parent.left; right: parent.right; topMargin: 6; leftMargin: 8; rightMargin: 8 }
                height: 102; radius: 12; color: "#1C1C1E"
                visible: VehicleService.driveMode === 5

                Column {
                    anchors { fill: parent; margins: 8 }
                    spacing: 4

                    Repeater {
                        model: [
                            { label: "Throttle",     opts: ["Std","Sport","Eco"],   prop: "personalThrottle" },
                            { label: "Steering",     opts: ["Light","Normal","Heavy"], prop: "personalSteering" },
                            { label: "Trace Ctrl",   opts: ["Off","Light","Normal"],   prop: "personalTrace" },
                            { label: "Engine Brake", opts: ["Off","Light","Normal"],   prop: "personalEngineBrake" },
                            { label: "ASM",          opts: ["Off","Low","High"],       prop: "personalASM" }
                        ]

                        Row {
                            // outerRow captures the per-iteration modelData so the
                            // inner Repeater (whose modelData rebinds to the opts
                            // strings) can still reach .prop and .label.
                            id: outerRow
                            property var rowData: modelData
                            spacing: 6; height: 14

                            Text {
                                text: outerRow.rowData.label
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 10 }
                                width: 78
                                verticalAlignment: Text.AlignVCenter; height: parent.height
                            }

                            Repeater {
                                model: outerRow.rowData.opts

                                Rectangle {
                                    height: 14; radius: 7
                                    width: optLabel.width + 12
                                    color: root[outerRow.rowData.prop] === index ? "#0A84FF" : "#2C2C2E"

                                    Text {
                                        id: optLabel
                                        anchors.centerIn: parent
                                        text: modelData
                                        color: root[outerRow.rowData.prop] === index ? "#FFFFFF" : "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 9 }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        // Personal-mode tuning persists immediately —
                                        // user explicitly confirms by tapping; SettingsService
                                        // debounces the disk write 5s on its own.
                                        onClicked: {
                                            root[outerRow.rowData.prop] = index
                                            root._persistPersonalConfig()
                                        }
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
                    font { family: "Roboto"; pixelSize: 14; weight: 600 }
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
                        font { family: "Roboto"; pixelSize: 9; weight: 600 }
                    }
                }
            }

            // Hint banner (only while a hold is in progress)
            Rectangle {
                anchors { top: adasHeader.bottom; horizontalCenter: parent.horizontalCenter; topMargin: 2 }
                height: 18; radius: 9
                width: holdHintLbl.width + 16
                color: "#3A2000"
                visible: root.adasHoldLabel !== ""
                z: 10

                Text {
                    id: holdHintLbl
                    anchors.centerIn: parent
                    text: "Hold to disable " + root.adasHoldLabel + " — " +
                          Math.ceil((1.0 - root.adasHoldProgress) * 2) + "s"
                    color: "#FF9F0A"
                    font { family: "Roboto"; pixelSize: 10; weight: 600 }
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
                                        font { family: "Roboto"; pixelSize: 14; weight: 600 }
                                    }
                                    Text {
                                        text: modelData.full
                                        color: "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 10 }
                                    }
                                }

                                // Toggle switch — tap-to-enable / hold-to-disable.
                                Rectangle {
                                    id: toggleLeft
                                    width: 44; height: 24; radius: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: VehicleService[modelData.propR] ? "#0A84FF" : "#2C2C2E"
                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    // Hold-progress ring (only visible while disabling)
                                    Rectangle {
                                        anchors.fill: parent; radius: parent.radius
                                        border { color: "#FF9F0A"; width: 2 }
                                        color: "transparent"
                                        visible: root.adasHoldLabel === modelData.abbr
                                        opacity: root.adasHoldProgress
                                    }

                                    Rectangle {
                                        id: thumbLeft
                                        width: 20; height: 20; radius: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: VehicleService[modelData.propR] ? 22 : 2
                                        color: "#FFFFFF"
                                        Behavior on x { NumberAnimation { duration: 150 } }
                                    }

                                    Timer {
                                        id: holdTimerLeft
                                        interval: 50; repeat: true
                                        property real held: 0
                                        onTriggered: {
                                            held += interval
                                            root.adasHoldProgress = Math.min(1.0, held / 2000)
                                            if (held >= 2000) {
                                                stop()
                                                VehicleService[modelData.setter](false)
                                                root.adasHoldLabel = ""
                                                root.adasHoldProgress = 0
                                                held = 0
                                            }
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onPressed: {
                                            if (VehicleService[modelData.propR]) {
                                                // Currently ON → start the 2-sec disable hold.
                                                root.adasHoldLabel = modelData.abbr
                                                holdTimerLeft.held = 0
                                                holdTimerLeft.start()
                                            }
                                        }
                                        onReleased: {
                                            if (holdTimerLeft.running) holdTimerLeft.stop()
                                            holdTimerLeft.held = 0
                                            if (root.adasHoldLabel === modelData.abbr) {
                                                root.adasHoldLabel = ""
                                                root.adasHoldProgress = 0
                                            }
                                        }
                                        onClicked: {
                                            // Single-tap path — enable only.
                                            root._fireAdasToggle(modelData.setter,
                                                                 VehicleService[modelData.propR])
                                        }
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
                                        font { family: "Roboto"; pixelSize: 14; weight: 600 }
                                    }
                                    Text {
                                        text: modelData.full
                                        color: "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 10 }
                                    }
                                }

                                // Toggle — tap-to-enable / hold-to-disable.
                                Rectangle {
                                    width: 44; height: 24; radius: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: VehicleService[modelData.propR] ? "#0A84FF" : "#2C2C2E"
                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Rectangle {
                                        anchors.fill: parent; radius: parent.radius
                                        border { color: "#FF9F0A"; width: 2 }
                                        color: "transparent"
                                        visible: root.adasHoldLabel === modelData.abbr
                                        opacity: root.adasHoldProgress
                                    }

                                    Rectangle {
                                        width: 20; height: 20; radius: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: VehicleService[modelData.propR] ? 22 : 2
                                        color: "#FFFFFF"
                                        Behavior on x { NumberAnimation { duration: 150 } }
                                    }

                                    Timer {
                                        id: holdTimerRight
                                        interval: 50; repeat: true
                                        property real held: 0
                                        onTriggered: {
                                            held += interval
                                            root.adasHoldProgress = Math.min(1.0, held / 2000)
                                            if (held >= 2000) {
                                                stop()
                                                VehicleService[modelData.setter](false)
                                                root.adasHoldLabel = ""
                                                root.adasHoldProgress = 0
                                                held = 0
                                            }
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onPressed: {
                                            if (VehicleService[modelData.propR]) {
                                                root.adasHoldLabel = modelData.abbr
                                                holdTimerRight.held = 0
                                                holdTimerRight.start()
                                            }
                                        }
                                        onReleased: {
                                            if (holdTimerRight.running) holdTimerRight.stop()
                                            holdTimerRight.held = 0
                                            if (root.adasHoldLabel === modelData.abbr) {
                                                root.adasHoldLabel = ""
                                                root.adasHoldProgress = 0
                                            }
                                        }
                                        onClicked: {
                                            root._fireAdasToggle(modelData.setter,
                                                                 VehicleService[modelData.propR])
                                        }
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
                        font { family: "Roboto"; pixelSize: 12; weight: 600 }
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

                        // Car body (manual rounded rect — roundRect not available in software renderer)
                        var r = 10
                        ctx.beginPath()
                        ctx.moveTo(bodyX + r, bodyY)
                        ctx.lineTo(bodyX + bodyW - r, bodyY)
                        ctx.arcTo(bodyX + bodyW, bodyY, bodyX + bodyW, bodyY + r, r)
                        ctx.lineTo(bodyX + bodyW, bodyY + bodyH - r)
                        ctx.arcTo(bodyX + bodyW, bodyY + bodyH, bodyX + bodyW - r, bodyY + bodyH, r)
                        ctx.lineTo(bodyX + r, bodyY + bodyH)
                        ctx.arcTo(bodyX, bodyY + bodyH, bodyX, bodyY + bodyH - r, r)
                        ctx.lineTo(bodyX, bodyY + r)
                        ctx.arcTo(bodyX, bodyY, bodyX + r, bodyY, r)
                        ctx.closePath()
                        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.25)
                        ctx.lineWidth = 1.5
                        ctx.stroke()

                        // Front axle line
                        var frontY = bodyY + 22
                        ctx.beginPath()
                        ctx.moveTo(cx - 90, frontY)
                        ctx.lineTo(cx + 90, frontY)
                        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.15)
                        ctx.lineWidth = 1; ctx.stroke()

                        // Rear axle line
                        var rearY = bodyY + bodyH - 22
                        ctx.beginPath()
                        ctx.moveTo(cx - 90, rearY)
                        ctx.lineTo(cx + 90, rearY)
                        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.15)
                        ctx.lineWidth = 1; ctx.stroke()

                        // Driveshaft
                        ctx.beginPath()
                        ctx.moveTo(cx, frontY)
                        ctx.lineTo(cx, rearY)
                        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.1)
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
                            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.3)
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
                                font { family: "Roboto"; pixelSize: 20; weight: 700 }
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
                                font { family: "Roboto"; pixelSize: 20; weight: 700 }
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

                // Session peak — small caption stat just under the live %s.
                // "MAX FRONT" — pinned high-water mark since app start.
                Text {
                    anchors {
                        top: parent.top; horizontalCenter: parent.horizontalCenter
                        topMargin: attesaCanvas.height + attesaCanvas.anchors.topMargin + 48 + 8 + 4
                    }
                    text: "session peak front bias: " + root.atessaMaxFront.toFixed(0) + "%"
                    color: "#636366"
                    font { family: "Roboto"; pixelSize: 10 }
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

                            DiagCell {
                                label: "Gear"
                                value: {
                                    var g = VehicleService.gear
                                    return g === 1 ? "P" : g === 2 ? "R" : g === 3 ? "N" : g === 4 ? "D" : "—"
                                }
                            }
                            DiagCell { label: "Rev";   value: VehicleService.reverse ? "●" : "○"; valColor: VehicleService.reverse ? "#0A84FF" : "#8E8E93" }
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

                            DiagCell { label: "Speed"; value: ((VehicleService.speed || 0).toFixed(1)) + " mph" }
                            DiagCell { label: "RPM";   value: (VehicleService.rpm || 0).toString() }
                            DiagCell { label: "Steer"; value: ((VehicleService.steerAngle || 0) >= 0 ? "+" : "") + (VehicleService.steerAngle || 0).toFixed(1) + "°" }
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

                            DiagCell {
                                label: "Wipers"
                                value: {
                                    var w = VehicleService.wipersState
                                    return w === 1 ? "SLOW" : w === 2 ? "FAST" : w === 3 ? "1-SHOT" : "OFF"
                                }
                            }
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
                                        font { family: "Roboto"; pixelSize: 10; weight: 600 }
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

        // ────────────────────────────────────────────────────────────────────
        // TAB 5 — TRACK (VR30 telemetry + G-pad + 0-60 timer)
        // ────────────────────────────────────────────────────────────────────
        Item {
            id: tabTrack
            anchors.fill: parent
            visible: root.activeTab === 5

            // Display unit (0=imperial / 1=metric) — informs 0-60 vs 0-100 km/h label.
            // Logic is in the VehicleService (always 60 mph trigger); QML relabels.
            property int distUnit: typeof SettingsService !== "undefined" ? SettingsService.distanceUnit : 0
            property string speedTargetLabel: distUnit === 1 ? "0-100 km/h" : "0-60 mph"

            // ── Top half: 7-element mini-gauge grid (2 rows × 4 cols) ────────
            Grid {
                id: gaugeGrid
                anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 6 }
                columns: 4; rows: 2
                columnSpacing: 6
                rowSpacing: 4

                MiniGauge {
                    label: "Boost"; units: "psi"
                    value: VehicleService.boostPressurePsi
                    minValue: 0; maxValue: 25; decimals: 1
                    arcColor: "#0A84FF"
                    warning: value > 20
                }
                MiniGauge {
                    label: "Oil"; units: "°F"
                    value: VehicleService.oilTempF
                    minValue: 180; maxValue: 280
                    arcColor: "#FF9F0A"
                    warning: value > 260
                }
                MiniGauge {
                    label: "Trans"; units: "°F"
                    value: VehicleService.transTempF
                    minValue: 160; maxValue: 260
                    arcColor: "#FF9F0A"
                    warning: value > 240
                }
                MiniGauge {
                    label: "IAT"; units: "°F"
                    value: VehicleService.intakeAirTempF
                    minValue: 60; maxValue: 180
                    arcColor: "#30D158"
                    warning: value > 150
                }
                MiniGauge {
                    label: "Ign Adv"; units: "°"
                    value: VehicleService.ignitionAdvanceDeg
                    minValue: -10; maxValue: 30
                    arcColor: "#0A84FF"
                }
                MiniGauge {
                    label: "Knock"; units: "°"
                    value: VehicleService.knockRetardDeg
                    minValue: 0; maxValue: 10
                    arcColor: "#FF453A"
                    warning: value > 2
                }
                MiniGauge {
                    label: "WG"; units: "%"
                    value: VehicleService.wastegatePercent
                    minValue: 0; maxValue: 100
                    arcColor: "#30D158"
                }
                // Reserved 8th cell — empty for future (AFR / lambda)
                Item { width: 92; height: 86 }
            }

            // ── Middle: G-pad + readouts row ─────────────────────────────────
            Item {
                id: gPadRow
                anchors { top: gaugeGrid.bottom; left: parent.left; right: parent.right; topMargin: 4 }
                height: 80

                GPad {
                    id: gPad
                    width: 76; height: 76
                    anchors { verticalCenter: parent.verticalCenter; horizontalCenter: parent.horizontalCenter }
                }

                // Lateral G readout — left of pad
                Column {
                    anchors { right: gPad.left; verticalCenter: gPad.verticalCenter; rightMargin: 14 }
                    spacing: 0
                    Text {
                        anchors.right: parent.right
                        text: VehicleService.lateralG.toFixed(2) + " g"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 14; weight: 600 }
                    }
                    Text {
                        anchors.right: parent.right
                        text: "LAT"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                    }
                    Text {
                        anchors.right: parent.right
                        text: "peak " + Math.abs(VehicleService.peakLateralG).toFixed(2)
                        color: "#FF9F0A"
                        font { family: "Roboto"; pixelSize: 10 }
                    }
                }

                // Longitudinal G readout — right of pad
                Column {
                    anchors { left: gPad.right; verticalCenter: gPad.verticalCenter; leftMargin: 14 }
                    spacing: 0
                    Text {
                        text: VehicleService.longitudinalG.toFixed(2) + " g"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 14; weight: 600 }
                    }
                    Text {
                        text: "LONG"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                    }
                    Text {
                        text: "peak " + Math.abs(VehicleService.peakLongitudinalG).toFixed(2)
                        color: "#30D158"
                        font { family: "Roboto"; pixelSize: 10 }
                    }
                }
            }

            // ── Bottom: Performance timer card ───────────────────────────────
            Rectangle {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right
                          bottomMargin: 4; leftMargin: 8; rightMargin: 8 }
                height: 76; radius: 12; color: "#1C1C1E"

                Row {
                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                    spacing: 12

                    // 0-60 / 0-100 main readout
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 150; spacing: 2

                        Text {
                            text: tabTrack.speedTargetLabel
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }
                        Text {
                            text: VehicleService.zeroToSixtySec > 0
                                  ? VehicleService.zeroToSixtySec.toFixed(2) + "s"
                                  : VehicleService.perfRunActive
                                      ? VehicleService.perfRunElapsedSec.toFixed(2) + "s"
                                      : "—"
                            color: VehicleService.zeroToSixtySec > 0 ? "#30D158"
                                 : VehicleService.perfRunActive       ? "#0A84FF" : "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 28; weight: 700 }
                        }
                    }

                    // Divider
                    Rectangle { width: 1; height: parent.height * 0.6; anchors.verticalCenter: parent.verticalCenter; color: "#2C2C2E" }

                    // Quarter-mile time
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 110; spacing: 2
                        Text {
                            text: "1/4 MILE"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }
                        Text {
                            text: VehicleService.quarterMileSec > 0
                                  ? VehicleService.quarterMileSec.toFixed(2) + "s" : "—"
                            color: VehicleService.quarterMileSec > 0 ? "#30D158" : "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 18; weight: 600 }
                        }
                    }

                    // Divider
                    Rectangle { width: 1; height: parent.height * 0.6; anchors.verticalCenter: parent.verticalCenter; color: "#2C2C2E" }

                    // Trap speed
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 110; spacing: 2
                        Text {
                            text: "TRAP"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 9; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }
                        Text {
                            text: VehicleService.quarterMileTrapMph > 0
                                  ? VehicleService.quarterMileTrapMph.toFixed(0) + " mph" : "—"
                            color: VehicleService.quarterMileTrapMph > 0 ? "#30D158" : "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 18; weight: 600 }
                        }
                    }

                    // Reset button
                    Rectangle {
                        width: 70; height: 32; radius: 16
                        anchors.verticalCenter: parent.verticalCenter
                        color: "#2C2C2E"

                        Text {
                            anchors.centerIn: parent
                            text: "Reset"
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 11; weight: 600 }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: VehicleService.resetPerformanceTimer()
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
            font { family: "Roboto"; pixelSize: 11; weight: 600 }
        }
    }
}
