// SettingsView — Lower 7" settings screen.
// Top level: sub-page selector list (Display / Clock / Units / Bluetooth /
// System / Language / + the existing Vehicle/Lights/etc rolled into "Vehicle").
// Tap a row to push a sub-page; back-arrow pops it. Persistence is automatic
// via SettingsService's 5s debounced save — no Save button.
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Settings state — backed by C++ SettingsService (JSON persistence) ───────
    property var settings: SettingsService

    // Overlay flags
    property bool pairingSheetVisible: false
    property bool resetWarningVisible: false
    property bool resetConfirmVisible: false
    property bool profileViewVisible: false

    // ── Top-level: shown when stack is empty ─────────────────────────────
    Item {
        id: rootPage
        anchors.fill: parent
        visible: pageStack.depth === 0

        Rectangle {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 48
            color: "#000000"

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Qt.rgba(1, 1, 1, 0.1)
            }

            Text {
                anchors.centerIn: parent
                text: "Settings"
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 18; weight: Font.SemiBold }
            }
        }

        Flickable {
            id: rootScroller
            anchors {
                top: header.bottom
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            clip: true
            contentHeight: rootCol.implicitHeight + 24
            contentWidth: width
            boundsMovement: Flickable.StopAtBounds

            Column {
                id: rootCol
                width: rootScroller.width
                spacing: 0

                // Active profile summary card — tap to open ProfileView
                SectionHeader { label: "DRIVER PROFILES" }

                Rectangle {
                    width: rootCol.width - 32
                    height: 56
                    radius: 14
                    color: "#1C1C1E"
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        width: 4; radius: 2
                        color: ProfileService.activeAccentColor
                    }

                    Row {
                        anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
                        spacing: 10

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: ProfileService.profileLoaded ? ProfileService.activeProfileAvatar : "👤"
                            font.pixelSize: 28
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Text {
                                text: ProfileService.profileLoaded ? ProfileService.activeProfileName : "No Profile"
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                            }
                            Text {
                                text: ProfileService.profileLoaded
                                      ? (ProfileService.lastSessionSummary !== "" ? ProfileService.lastSessionSummary : "Active profile")
                                      : "Tap to set up driver profiles"
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 11 }
                                elide: Text.ElideRight
                                width: 240
                            }
                        }
                    }

                    Text {
                        anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                        text: "›"
                        color: "#8E8E93"
                        font { pixelSize: 22 }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.profileViewVisible = true
                    }
                }

                Item { width: 1; height: 8 }

                // ── Sub-page entry rows ───────────────────────────────────
                SectionHeader { label: "SETTINGS" }

                SubPageRow { label: "Display";    icon: "☀";  onClicked: pageStack.push(displayPage) }
                SubPageRow { label: "Clock";      icon: "🕐";  onClicked: pageStack.push(clockPage) }
                SubPageRow { label: "Units";      icon: "⚖";  onClicked: pageStack.push(unitsPage) }
                SubPageRow { label: "Bluetooth";  icon: "⑂";  onClicked: pageStack.push(bluetoothPage) }
                SubPageRow { label: "Navigation"; icon: "➤";  onClicked: pageStack.push(navigationPage) }
                SubPageRow { label: "Audio";      icon: "♫";  onClicked: pageStack.push(audioPage) }
                SubPageRow { label: "Vehicle";    icon: "🚗"; onClicked: pageStack.push(vehiclePage) }
                SubPageRow { label: "Vehicle Unlocks"; icon: "🔓"; onClicked: pageStack.push(vehicleUnlocksPage) }
                SubPageRow { label: "Language";   icon: "🌐"; onClicked: pageStack.push(languagePage) }
                SubPageRow { label: "System";     icon: "ⓘ";  onClicked: pageStack.push(systemPage) }

                Item { width: 1; height: 24 }
            }
        }
    }

    // ── Sub-page host ────────────────────────────────────────────────────
    StackView {
        id: pageStack
        anchors.fill: parent
        visible: depth > 0

        pushEnter: Transition {
            NumberAnimation { property: "x"; from: width; to: 0; duration: 180; easing.type: Easing.OutCubic }
        }
        pushExit: Transition {
            NumberAnimation { property: "x"; from: 0; to: -width/4; duration: 180; easing.type: Easing.OutCubic }
        }
        popEnter: Transition {
            NumberAnimation { property: "x"; from: -width/4; to: 0; duration: 180; easing.type: Easing.OutCubic }
        }
        popExit: Transition {
            NumberAnimation { property: "x"; from: 0; to: width; duration: 180; easing.type: Easing.OutCubic }
        }
    }

    // ================================================================
    // SUB-PAGES — declared as Component so StackView can instantiate
    // ================================================================

    // ── DISPLAY ──────────────────────────────────────────────────────
    Component {
        id: displayPage
        SubPage {
            title: "Display"

            Column {
                width: parent.width
                spacing: 0

                SliderRow {
                    label: "Upper Screen Brightness"
                    minValue: 20; maxValue: 100
                    value: settings.upperBrightness
                    onValueChanged: settings.upperBrightness = value
                }
                SliderRow {
                    label: "Lower Screen Brightness"
                    minValue: 20; maxValue: 100
                    value: settings.lowerBrightness
                    onValueChanged: settings.lowerBrightness = value
                }
                SettingsRow {
                    label: "Day / Night Mode"
                    control: PillGroup {
                        options: ["Auto", "Day", "Night"]
                        selected: settings.dayNightMode
                        onSelectedChanged: settings.dayNightMode = selected
                    }
                }
                SliderRow {
                    label: "Auto-Dim Threshold"
                    suffix: " lux"
                    minValue: 0; maxValue: 500
                    value: settings.autoDimThreshold
                    enabled: settings.dayNightMode === 0
                    onValueChanged: settings.autoDimThreshold = value
                }
                Text {
                    width: parent.width - 32
                    x: 16
                    text: settings.dayNightMode === 0
                          ? "Day mode engages when ambient light drops below this threshold."
                          : "Auto-dim only applies in Auto mode."
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 11 }
                    wrapMode: Text.WordWrap
                    topPadding: 8; bottomPadding: 12
                }
            }
        }
    }

    // ── CLOCK ────────────────────────────────────────────────────────
    Component {
        id: clockPage
        SubPage {
            title: "Clock"

            Column {
                width: parent.width
                spacing: 0

                SettingsRow {
                    label: "Time Format"
                    control: PillGroup {
                        options: ["12h", "24h"]
                        selected: settings.timeFormat
                        onSelectedChanged: settings.timeFormat = selected
                    }
                }
                SettingsRow {
                    label: "GPS Sync"
                    labelSecondary: "Auto-set time from GPS"
                    control: ToggleSwitch {
                        checked: settings.gpsSync
                        onCheckedChanged: settings.gpsSync = checked
                    }
                }

                // Manual time set — disabled when GPS sync is ON
                Rectangle {
                    width: parent.width
                    height: 64
                    color: "transparent"
                    opacity: settings.gpsSync ? 0.4 : 1.0

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width; height: 1
                        color: Qt.rgba(1, 1, 1, 0.06)
                    }

                    Text {
                        anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                        text: "Manual Time"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 15 }
                    }

                    Row {
                        anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                        spacing: 6
                        enabled: !settings.gpsSync

                        SpinBox {
                            id: hrSpinner
                            value: settings.clockHour
                            from: 0; to: 23
                            width: 72; height: 36
                            background: Rectangle { color: "#2C2C2E"; radius: 8 }
                            contentItem: Text {
                                text: hrSpinner.value < 10 ? "0" + hrSpinner.value : hrSpinner.value
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 15 }
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            up.indicator: Rectangle {
                                x: hrSpinner.mirrored ? 0 : hrSpinner.width - width
                                y: 0; width: 24; height: hrSpinner.height / 2
                                color: "transparent"
                                Text { anchors.centerIn: parent; text: "▲"; color: "#0A84FF"; font.pixelSize: 10 }
                            }
                            down.indicator: Rectangle {
                                x: hrSpinner.mirrored ? 0 : hrSpinner.width - width
                                y: hrSpinner.height / 2; width: 24; height: hrSpinner.height / 2
                                color: "transparent"
                                Text { anchors.centerIn: parent; text: "▼"; color: "#0A84FF"; font.pixelSize: 10 }
                            }
                            onValueModified: settings.clockHour = value
                        }
                        Text { text: ":"; color: "#FFFFFF"; font { pixelSize: 18; weight: Font.Bold } anchors.verticalCenter: parent.verticalCenter }
                        SpinBox {
                            id: minSpinner
                            value: settings.clockMinute
                            from: 0; to: 59
                            width: 72; height: 36
                            background: Rectangle { color: "#2C2C2E"; radius: 8 }
                            contentItem: Text {
                                text: minSpinner.value < 10 ? "0" + minSpinner.value : minSpinner.value
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 15 }
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            up.indicator: Rectangle {
                                x: minSpinner.mirrored ? 0 : minSpinner.width - width
                                y: 0; width: 24; height: minSpinner.height / 2
                                color: "transparent"
                                Text { anchors.centerIn: parent; text: "▲"; color: "#0A84FF"; font.pixelSize: 10 }
                            }
                            down.indicator: Rectangle {
                                x: minSpinner.mirrored ? 0 : minSpinner.width - width
                                y: minSpinner.height / 2; width: 24; height: minSpinner.height / 2
                                color: "transparent"
                                Text { anchors.centerIn: parent; text: "▼"; color: "#0A84FF"; font.pixelSize: 10 }
                            }
                            onValueModified: settings.clockMinute = value
                        }
                    }
                }

                // Timezone — stepper with ±
                Rectangle {
                    width: parent.width
                    height: 56
                    color: "transparent"

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width; height: 1
                        color: Qt.rgba(1, 1, 1, 0.06)
                    }

                    Text {
                        anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                        text: "Timezone"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 15 }
                    }

                    Row {
                        anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                        spacing: 10

                        Rectangle {
                            width: 36; height: 36; radius: 8; color: "#2C2C2E"
                            Text { anchors.centerIn: parent; text: "−"; color: "#0A84FF"; font { pixelSize: 20; weight: Font.Bold } }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: if (settings.timezoneOffset > -12) settings.timezoneOffset = settings.timezoneOffset - 1
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: (settings.timezoneOffset >= 0 ? "UTC+" : "UTC")
                                  + settings.timezoneOffset
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 15; weight: Font.SemiBold }
                            width: 72; horizontalAlignment: Text.AlignHCenter
                        }
                        Rectangle {
                            width: 36; height: 36; radius: 8; color: "#2C2C2E"
                            Text { anchors.centerIn: parent; text: "+"; color: "#0A84FF"; font { pixelSize: 18; weight: Font.Bold } }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: if (settings.timezoneOffset < 14) settings.timezoneOffset = settings.timezoneOffset + 1
                            }
                        }
                    }
                }
            }
        }
    }

    // ── UNITS ────────────────────────────────────────────────────────
    Component {
        id: unitsPage
        SubPage {
            title: "Units"

            Column {
                width: parent.width
                spacing: 0

                SettingsRow {
                    label: "Distance"
                    control: PillGroup {
                        options: ["mi", "km"]
                        selected: settings.distanceUnit
                        onSelectedChanged: settings.distanceUnit = selected
                    }
                }
                SettingsRow {
                    label: "Temperature"
                    control: PillGroup {
                        options: ["°F", "°C"]
                        selected: settings.tempUnit
                        onSelectedChanged: settings.tempUnit = selected
                    }
                }
                SettingsRow {
                    label: "Fuel Economy"
                    control: PillGroup {
                        options: ["MPG", "L/100km", "km/L"]
                        selected: settings.fuelUnit
                        onSelectedChanged: settings.fuelUnit = selected
                    }
                }
            }
        }
    }

    // ── BLUETOOTH ────────────────────────────────────────────────────
    Component {
        id: bluetoothPage
        SubPage {
            title: "Bluetooth"

            Column {
                width: parent.width
                spacing: 0

                // Paired devices list
                SectionHeader { label: "PAIRED DEVICES" }

                Repeater {
                    model: settings.btDevices
                    delegate: Rectangle {
                        width: parent.width
                        height: 64
                        color: "transparent"

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width; height: 1
                            color: Qt.rgba(1, 1, 1, 0.06)
                        }

                        Row {
                            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                            spacing: 10

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "⑂"
                                color: modelData.connected ? "#0A84FF" : "#8E8E93"
                                font.pixelSize: 18
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                Text {
                                    text: modelData.name
                                    color: "#FFFFFF"
                                    font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                                }
                                Text {
                                    text: modelData.connected ? "Connected" : "Saved"
                                    color: modelData.connected ? "#30D158" : "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 11 }
                                }
                            }
                        }

                        // Right-hand actions: priority up/down, connect, forget
                        Row {
                            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                            spacing: 6

                            Rectangle {
                                width: 30; height: 30; radius: 8; color: "#2C2C2E"
                                Text { anchors.centerIn: parent; text: "▲"; color: "#0A84FF"; font.pixelSize: 10 }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: settings.btSetPriority(modelData.mac, +1)
                                }
                            }
                            Rectangle {
                                width: 30; height: 30; radius: 8; color: "#2C2C2E"
                                Text { anchors.centerIn: parent; text: "▼"; color: "#0A84FF"; font.pixelSize: 10 }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: settings.btSetPriority(modelData.mac, -1)
                                }
                            }
                            Rectangle {
                                width: 78; height: 30; radius: 8
                                color: modelData.connected ? "transparent" : "#0A84FF22"
                                border { color: modelData.connected ? "#FF453A" : "#0A84FF"; width: 1 }
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.connected ? "Disconnect" : "Connect"
                                    color: modelData.connected ? "#FF453A" : "#0A84FF"
                                    font { family: "Roboto"; pixelSize: 11; weight: Font.SemiBold }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: settings.btToggleConnect(modelData.mac)
                                }
                            }
                            Rectangle {
                                width: 30; height: 30; radius: 8; color: "transparent"
                                Text { anchors.centerIn: parent; text: "🗑"; font.pixelSize: 14 }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: settings.btForgetDevice(modelData.mac)
                                }
                            }
                        }
                    }
                }

                Item { width: 1; height: 12 }

                // Add new device
                Rectangle {
                    width: parent.width - 32
                    height: 44
                    radius: 12
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "#0A84FF22"
                    border { color: "#0A84FF"; width: 1 }

                    Text {
                        anchors.centerIn: parent
                        text: "+ Add New Device"
                        color: "#0A84FF"
                        font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.pairingSheetVisible = true
                    }
                }

                Item { width: 1; height: 16 }
            }
        }
    }

    // ── NAVIGATION ───────────────────────────────────────────────────
    Component {
        id: navigationPage
        SubPage {
            title: "Navigation"

            Column {
                width: parent.width
                spacing: 0

                SettingsRow {
                    label: "Voice Guidance"
                    control: ToggleSwitch {
                        checked: settings.voiceGuidance
                        onCheckedChanged: settings.voiceGuidance = checked
                    }
                }
                SliderRow {
                    label: "Voice Volume"
                    value: settings.voiceVolume
                    onValueChanged: settings.voiceVolume = value
                }
                SettingsRow {
                    label: "Route Preference"
                    control: PillGroup {
                        options: ["Fastest", "Shortest", "Eco"]
                        selected: settings.routePref
                        onSelectedChanged: settings.routePref = selected
                    }
                }
                SettingsRow {
                    label: "Avoid Tolls"
                    control: ToggleSwitch {
                        checked: settings.avoidTolls
                        onCheckedChanged: settings.avoidTolls = checked
                    }
                }
                SettingsRow {
                    label: "Avoid Highways"
                    control: ToggleSwitch {
                        checked: settings.avoidHighways
                        onCheckedChanged: settings.avoidHighways = checked
                    }
                }
                SettingsRow {
                    label: "POI Icons on Map"
                    control: ToggleSwitch {
                        checked: settings.poiIconsOnMap
                        onCheckedChanged: settings.poiIconsOnMap = checked
                    }
                }
                SettingsRow {
                    label: "Map Orientation"
                    control: PillGroup {
                        options: ["Heading", "North", "3D"]
                        selected: settings.mapOrientation
                        onSelectedChanged: settings.mapOrientation = selected
                    }
                }
                SettingsRow {
                    label: "Speed Limit Display"
                    control: ToggleSwitch {
                        checked: settings.speedLimitDisplay
                        onCheckedChanged: settings.speedLimitDisplay = checked
                    }
                }
                SettingsRow {
                    label: "Map Detail Level"
                    control: PillGroup {
                        options: ["Low", "Med", "High"]
                        selected: settings.mapDetailLevel
                        onSelectedChanged: settings.mapDetailLevel = selected
                    }
                }
            }
        }
    }

    // ── AUDIO ────────────────────────────────────────────────────────
    Component {
        id: audioPage
        SubPage {
            title: "Audio"

            Column {
                width: parent.width
                spacing: 0

                SettingsRow {
                    label: "Button Click Sounds"
                    control: ToggleSwitch {
                        checked: settings.clickSounds
                        onCheckedChanged: settings.clickSounds = checked
                    }
                }
                SliderRow {
                    label: "Nav Prompt Volume"
                    value: settings.navPromptVolume
                    onValueChanged: settings.navPromptVolume = value
                }
            }
        }
    }

    // ── VEHICLE (lights / locks / mirrors / wipers / comfort / maintenance) ──
    Component {
        id: vehiclePage
        SubPage {
            title: "Vehicle"

            Column {
                width: parent.width
                spacing: 0

                SectionHeader { label: "STABILITY" }
                SettingsRow {
                    label: "Rain Sensor"
                    control: ToggleSwitch {
                        checked: VehicleService.rainSensorEnabled
                        onCheckedChanged: if (checked !== VehicleService.rainSensorEnabled) VehicleService.setRainSensor(checked)
                    }
                }
                Column {
                    width: parent.width
                    spacing: 0
                    SettingsRow {
                        label: "VDC (Traction Control)"
                        control: ToggleSwitch {
                            checked: settings.vdcEnabled
                            onCheckedChanged: settings.vdcEnabled = checked
                        }
                    }
                    Rectangle {
                        width: parent.width
                        height: settings.vdcEnabled ? 0 : 36
                        clip: true
                        color: Qt.rgba(1, 0.2706, 0.2275, 0.08)
                        visible: !settings.vdcEnabled
                        Behavior on height { NumberAnimation { duration: 150 } }
                        Text {
                            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                            text: "⚠  Disabling VDC reduces vehicle stability"
                            color: "#FF453A"
                            font { family: "Roboto"; pixelSize: 12 }
                        }
                    }
                }

                SectionHeader { label: "LIGHTS" }
                SettingsRow {
                    label: "Auto Light Shutoff"
                    control: PillGroup {
                        options: ["Off", "30s", "45s", "60s", "90s", "2m", "3m"]
                        selected: settings.lightShutoff
                        onSelectedChanged: settings.lightShutoff = selected
                    }
                }
                SettingsRow {
                    label: "Auto Headlight Sensitivity"
                    control: PillGroup {
                        options: ["Low", "Med", "High"]
                        selected: settings.headlightSensitivity
                        onSelectedChanged: settings.headlightSensitivity = selected
                    }
                }
                SettingsRow {
                    label: "Daytime Running Lights"
                    control: ToggleSwitch {
                        checked: settings.drlEnabled
                        onCheckedChanged: settings.drlEnabled = checked
                    }
                }
                SettingsRow {
                    label: "Approach Lighting"
                    control: ToggleSwitch {
                        checked: settings.approachLighting
                        onCheckedChanged: settings.approachLighting = checked
                    }
                }
                SettingsRow {
                    label: "Approach Light Duration"
                    control: PillGroup {
                        options: ["30s", "60s", "90s"]
                        selected: settings.approachLightDuration
                        onSelectedChanged: settings.approachLightDuration = selected
                    }
                }
                SettingsRow {
                    label: "Welcome Lighting"
                    control: ToggleSwitch {
                        checked: settings.welcomeLighting
                        onCheckedChanged: settings.welcomeLighting = checked
                    }
                }
                SettingsRow {
                    label: "Interior Light Timer"
                    control: PillGroup {
                        options: ["15s", "30s", "45s", "60s"]
                        selected: settings.interiorLightTimer
                        onSelectedChanged: settings.interiorLightTimer = selected
                    }
                }

                SectionHeader { label: "DOOR LOCKS" }
                SettingsRow {
                    label: "Auto-Lock When Driving"
                    control: PillGroup {
                        options: ["Off", "15 mph", "25 mph"]
                        selected: settings.autoLockSpeed
                        onSelectedChanged: settings.autoLockSpeed = selected
                    }
                }
                SettingsRow {
                    label: "Auto-Unlock in Park"
                    control: ToggleSwitch {
                        checked: settings.autoUnlockPark
                        onCheckedChanged: settings.autoUnlockPark = checked
                    }
                }
                SettingsRow {
                    label: "Auto-Unlock on Key Removal"
                    control: ToggleSwitch {
                        checked: settings.autoUnlockKeyRemoval
                        onCheckedChanged: settings.autoUnlockKeyRemoval = checked
                    }
                }
                SettingsRow {
                    label: "Lock All with Key Fob"
                    control: ToggleSwitch {
                        checked: settings.fobLockAll
                        onCheckedChanged: settings.fobLockAll = checked
                    }
                }

                SectionHeader { label: "MIRRORS" }
                SettingsRow {
                    label: "Auto-Tilt in Reverse"
                    control: ToggleSwitch {
                        checked: settings.mirrorTiltReverse
                        onCheckedChanged: settings.mirrorTiltReverse = checked
                    }
                }
                SettingsRow {
                    label: "Fold Mirrors with Door Lock"
                    control: ToggleSwitch {
                        checked: settings.mirrorFoldLock
                        onCheckedChanged: settings.mirrorFoldLock = checked
                    }
                }

                SectionHeader { label: "WIPERS" }
                SettingsRow {
                    label: "Rain Sensor Sensitivity"
                    control: PillGroup {
                        options: ["1", "2", "3", "4", "5"]
                        selected: settings.rainSensorSensitivity - 1
                        onSelectedChanged: settings.rainSensorSensitivity = selected + 1
                    }
                }
                SettingsRow {
                    label: "Intermittent Wiper Delay"
                    control: PillGroup {
                        options: ["1", "2", "3", "4", "5"]
                        selected: settings.wiperDelay - 1
                        onSelectedChanged: settings.wiperDelay = selected + 1
                    }
                }

                SectionHeader { label: "COMFORT" }
                SettingsRow {
                    label: "Seat Memory on Unlock"
                    control: ToggleSwitch {
                        checked: settings.seatMemoryOnUnlock
                        onCheckedChanged: settings.seatMemoryOnUnlock = checked
                    }
                }
                SettingsRow {
                    label: "Power Window Auto-Open"
                    control: ToggleSwitch {
                        checked: settings.powerWindowAutoOpen
                        onCheckedChanged: settings.powerWindowAutoOpen = checked
                    }
                }
                SettingsRow {
                    label: "Comfort Window Close (Lock Hold)"
                    control: ToggleSwitch {
                        checked: settings.fobLockHoldCloses
                        onCheckedChanged: settings.fobLockHoldCloses = checked
                    }
                }
                SettingsRow {
                    label: "One-Touch Up/Down — All Windows"
                    control: ToggleSwitch {
                        checked: settings.allWindowsOneTouch
                        onCheckedChanged: settings.allWindowsOneTouch = checked
                    }
                }
                SettingsRow {
                    label: "Seat Belt Reminder"
                    control: ToggleSwitch {
                        checked: settings.seatbeltReminder
                        onCheckedChanged: settings.seatbeltReminder = checked
                    }
                }
                SettingsRow {
                    label: "Park Assist Chime Volume"
                    control: PillGroup {
                        options: ["Off", "Low", "Med", "High"]
                        selected: settings.parkAssistChimeVolume
                        onSelectedChanged: settings.parkAssistChimeVolume = selected
                    }
                }

                SectionHeader { label: "MAINTENANCE" }
                SettingsRow {
                    label: "Oil Life"
                    control: Text {
                        text: VehicleService.oilLife + "%"
                        color: VehicleService.oilLife > 30 ? "#30D158" : VehicleService.oilLife > 15 ? "#FF9F0A" : "#FF453A"
                        font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                    }
                }
                SettingsRow {
                    label: "Maintenance Interval"
                    control: PillGroup {
                        options: ["3k mi", "5k mi", "7.5k", "10k mi"]
                        selected: settings.maintenanceInterval
                        onSelectedChanged: settings.maintenanceInterval = selected
                    }
                }
                SettingsRow {
                    label: "TPMS Calibration"
                    control: Rectangle {
                        width: 88; height: 30; radius: 8
                        color: "#0A84FF22"
                        border { color: "#0A84FF"; width: 1 }
                        Text {
                            anchors.centerIn: parent; text: "Calibrate"
                            color: "#0A84FF"
                            font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                        }
                        MouseArea { anchors.fill: parent; onClicked: console.log("TPMS calibration started") }
                    }
                }
            }
        }
    }

    // ── LANGUAGE ─────────────────────────────────────────────────────
    Component {
        id: languagePage
        SubPage {
            title: "Language"

            Column {
                width: parent.width
                spacing: 0

                Repeater {
                    model: [
                        { label: "English",  index: 0 },
                        { label: "Spanish",  index: 1 },
                        { label: "French",   index: 2 },
                        { label: "Japanese", index: 3 }
                    ]
                    delegate: Rectangle {
                        width: parent.width
                        height: 48
                        color: "transparent"

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width; height: 1
                            color: Qt.rgba(1, 1, 1, 0.06)
                        }

                        Text {
                            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                            text: modelData.label
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 15 }
                        }

                        // Selected checkmark
                        Text {
                            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                            text: "✓"
                            color: "#0A84FF"
                            font { family: "Roboto"; pixelSize: 18; weight: Font.Bold }
                            visible: settings.language === modelData.index
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: settings.language = modelData.index
                        }
                    }
                }

                Item { width: 1; height: 16 }

                Rectangle {
                    width: parent.width - 32
                    height: 56
                    radius: 10
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: Qt.rgba(1, 0.62, 0.04, 0.12)
                    border { color: "#FF9F0A"; width: 1 }

                    Row {
                        anchors.centerIn: parent
                        spacing: 10
                        Text { text: "⚠"; color: "#FF9F0A"; font.pixelSize: 16; anchors.verticalCenter: parent.verticalCenter }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Restart required to apply language."
                            color: "#FF9F0A"
                            font { family: "Roboto"; pixelSize: 12 }
                        }
                    }
                }
            }
        }
    }

    // ── SYSTEM ───────────────────────────────────────────────────────
    Component {
        id: systemPage
        SubPage {
            title: "System"

            Column {
                width: parent.width
                spacing: 0

                SectionHeader { label: "BUILD" }
                InfoRow { label: "Software Version"; value: settings.softwareVersion }
                InfoRow { label: "Map Data";         value: settings.mapDataVersion }
                InfoRow { label: "Build Date";       value: settings.buildDate }

                SectionHeader { label: "RUNTIME" }

                // CAN status — VehicleService has no canStatus prop; ignitionOn
                // is the practical liveness signal on the SocketCAN bus.
                InfoRow {
                    label: "CAN Bus"
                    value: VehicleService.ignitionOn ? "Active" : "Idle"
                    valueColor: VehicleService.ignitionOn ? "#30D158" : "#8E8E93"
                }

                // GPS fix — QGeoCoordinate::isValid() is a method, not a property.
                // Without the parens it returns the function reference (always truthy)
                // so the "No fix" branch never showed pre-2026-05-13 audit fix.
                InfoRow {
                    label: "GPS Fix"
                    value: NavigationService.position.isValid()
                           ? (NavigationService.position.latitude.toFixed(4)
                              + ", " + NavigationService.position.longitude.toFixed(4))
                           : "No fix"
                    valueColor: NavigationService.position.isValid() ? "#30D158" : "#FF9F0A"
                }

                InfoRow {
                    label: "Uptime"
                    value: {
                        var ms = settings.uptimeMs
                        var s = Math.floor(ms / 1000)
                        var h = Math.floor(s / 3600)
                        var m = Math.floor((s % 3600) / 60)
                        var sec = s % 60
                        if (h > 0)  return h + "h " + m + "m " + sec + "s"
                        if (m > 0)  return m + "m " + sec + "s"
                        return sec + "s"
                    }
                }

                Item { width: 1; height: 16 }

                // Factory reset
                Rectangle {
                    width: parent.width - 32
                    height: 44
                    radius: 12
                    color: "transparent"
                    border { color: "#FF453A"; width: 1.5 }
                    anchors.horizontalCenter: parent.horizontalCenter

                    Text {
                        anchors.centerIn: parent
                        text: "Factory Reset"
                        color: "#FF453A"
                        font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.resetWarningVisible = true
                    }
                }

                Item { width: 1; height: 16 }
            }
        }
    }

    // ── Pairing modal sheet ───────────────────────────────────────────────────
    Rectangle {
        id: pairingSheet
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.72)
        visible: root.pairingSheetVisible
        opacity: root.pairingSheetVisible ? 1 : 0
        z: 100
        Behavior on opacity { NumberAnimation { duration: 200 } }

        Rectangle {
            anchors {
                bottom: parent.bottom
                left: parent.left
                right: parent.right
            }
            height: 220; radius: 20
            color: "#1C1C1E"

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 20 }
                spacing: 12

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "⑂"
                    color: "#0A84FF"
                    font { pixelSize: 36 }
                    SequentialAnimation on opacity {
                        running: root.pairingSheetVisible
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Tap a device on your phone…"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 15; weight: Font.SemiBold }
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Searching for 'Q60 Nav' nearby…"
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 12 }
                    horizontalAlignment: Text.AlignHCenter
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12

                    // Cancel
                    Rectangle {
                        width: 120; height: 36; radius: 10
                        color: "#2C2C2E"
                        Text {
                            anchors.centerIn: parent; text: "Cancel"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.pairingSheetVisible = false
                        }
                    }
                    // Simulate pairing complete (no real device flow yet)
                    // TODO: wire to BlueZ pairing accept handler
                    Rectangle {
                        width: 140; height: 36; radius: 10
                        color: "#0A84FF22"
                        border { color: "#0A84FF"; width: 1 }
                        Text {
                            anchors.centerIn: parent; text: "Simulate Pair"
                            color: "#0A84FF"
                            font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                settings.btAddMockDevice("Paired Device " + (settings.btDevices.length + 1))
                                root.pairingSheetVisible = false
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Factory-reset warning (step 1 of 2) ──────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.72)
        visible: root.resetWarningVisible
        opacity: root.resetWarningVisible ? 1 : 0
        z: 100
        Behavior on opacity { NumberAnimation { duration: 200 } }

        Rectangle {
            anchors.centerIn: parent
            width: 340; height: 200; radius: 20
            color: "#1C1C1E"
            border { color: "#FF453A"; width: 1 }

            Column {
                anchors { fill: parent; margins: 20 }
                spacing: 14

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "⚠  Factory Reset"
                    color: "#FF453A"
                    font { family: "Roboto"; pixelSize: 16; weight: Font.Bold }
                }
                Text {
                    width: parent.width
                    text: "This will erase every preference on this head unit, including paired devices and clock manual time. Vehicle data is unaffected."
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 13 }
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12
                    Rectangle {
                        width: 130; height: 38; radius: 10
                        color: "#2C2C2E"
                        Text {
                            anchors.centerIn: parent; text: "Cancel"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.resetWarningVisible = false
                        }
                    }
                    Rectangle {
                        width: 150; height: 38; radius: 10
                        color: "#FF453A22"
                        border { color: "#FF453A"; width: 1 }
                        Text {
                            anchors.centerIn: parent; text: "Continue"
                            color: "#FF453A"
                            font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                root.resetWarningVisible = false
                                root.resetConfirmVisible = true
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Factory-reset confirm (step 2 of 2) — the only step that fires ─────
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.72)
        visible: root.resetConfirmVisible
        opacity: root.resetConfirmVisible ? 1 : 0
        z: 100
        Behavior on opacity { NumberAnimation { duration: 200 } }

        Rectangle {
            anchors.centerIn: parent
            width: 340; height: 180; radius: 20
            color: "#1C1C1E"
            border { color: "#FF453A"; width: 2 }

            Column {
                anchors { fill: parent; margins: 20 }
                spacing: 16

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Are you absolutely sure?"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 16; weight: Font.Bold }
                }
                Text {
                    width: parent.width
                    text: "All preferences will be wiped immediately. This cannot be undone."
                    color: "#FF453A"
                    font { family: "Roboto"; pixelSize: 12 }
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12
                    Rectangle {
                        width: 130; height: 38; radius: 10
                        color: "#2C2C2E"
                        Text {
                            anchors.centerIn: parent; text: "Cancel"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 13; weight: Font.SemiBold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.resetConfirmVisible = false
                        }
                    }
                    Rectangle {
                        width: 150; height: 38; radius: 10
                        color: "#FF453A"
                        Text {
                            anchors.centerIn: parent; text: "Confirm Reset"
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 13; weight: Font.Bold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                settings.resetToDefaults()
                                root.resetConfirmVisible = false
                                // Pop any open sub-page so user lands on the
                                // sub-page selector with fresh defaults visible
                                while (pageStack.depth > 0) pageStack.pop()
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Profile View (full-screen overlay) ───────────────────────────────────
    ProfileView {
        anchors.fill: parent
        visible: root.profileViewVisible
        z: 101
        onVisibleChanged: {
            if (!visible) root.profileViewVisible = false
        }
    }

    // ── VEHICLE UNLOCKS (BCM Work Support + DTCs + maintenance resets) ───────
    // The full-screen VehicleSettingsView replaces the SubPage chrome since it
    // owns its own header. Pushed as a bare wrapper so StackView still drives
    // the in/out transitions.
    Component {
        id: vehicleUnlocksPage
        Item {
            anchors.fill: parent
            VehicleSettingsView {
                anchors.fill: parent
                onClosed: pageStack.pop()
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Inline component definitions — reused by sub-pages
    // ────────────────────────────────────────────────────────────────────────

    // SubPage — title bar + back arrow + content slot, lives inside StackView
    component SubPage: Item {
        id: sp
        property string title: ""
        default property alias contentData: spContent.data

        anchors.fill: parent

        Rectangle { anchors.fill: parent; color: "#000000" }

        Rectangle {
            id: spTitleBar
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 48
            color: "#000000"

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Qt.rgba(1, 1, 1, 0.1)
            }

            Rectangle {
                width: 48; height: 48
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                color: spBackArea.pressed ? "#1C1C1E" : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "‹"
                    color: "#0A84FF"
                    font { family: "Roboto"; pixelSize: 30; weight: Font.Light }
                }
                MouseArea {
                    id: spBackArea
                    anchors.fill: parent
                    onClicked: pageStack.pop()
                }
            }

            Text {
                anchors.centerIn: parent
                text: sp.title
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 18; weight: Font.SemiBold }
            }
        }

        Flickable {
            id: spScroller
            anchors {
                top: spTitleBar.bottom
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            clip: true
            contentHeight: spContent.childrenRect.height + 24
            contentWidth: width
            boundsMovement: Flickable.StopAtBounds

            Item {
                id: spContent
                width: spScroller.width
                height: childrenRect.height
            }
        }
    }

    // Sub-page selector row — large tap target on root list
    component SubPageRow: Rectangle {
        id: sprBase
        property string label: ""
        property string icon: ""
        signal clicked()

        width: rootCol.width
        height: 56
        color: sprArea.pressed ? "#1C1C1E" : "transparent"

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }

        Row {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            spacing: 12

            Rectangle {
                width: 32; height: 32; radius: 8
                color: "#0A84FF22"
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    anchors.centerIn: parent
                    text: sprBase.icon
                    color: "#0A84FF"
                    font.pixelSize: 16
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: sprBase.label
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 15 }
            }
        }

        Text {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            text: "›"
            color: "#8E8E93"
            font { pixelSize: 22 }
        }

        MouseArea {
            id: sprArea
            anchors.fill: parent
            onClicked: sprBase.clicked()
        }
    }

    // Section header label
    component SectionHeader: Item {
        id: shBase
        property string label: ""
        width: parent ? parent.width : 0
        height: 36

        Text {
            anchors { left: parent.left; leftMargin: 16; bottom: parent.bottom; bottomMargin: 4 }
            text: shBase.label
            color: "#8E8E93"
            font {
                family: "Roboto"
                pixelSize: 11
                capitalization: Font.AllUppercase
                letterSpacing: 1.5
            }
        }
    }

    // Standard settings row
    component SettingsRow: Rectangle {
        id: rowBase
        property string label: ""
        property string labelSecondary: ""
        property alias control: controlSlot.data
        signal rowClicked()

        width: parent ? parent.width : 0
        height: labelSecondary !== "" ? 56 : 48
        color: "transparent"

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }

        Column {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            spacing: 2
            Text {
                text: rowBase.label
                color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 15 }
            }
            Text {
                text: rowBase.labelSecondary
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 12 }
                visible: rowBase.labelSecondary !== ""
            }
        }

        Item {
            id: controlSlot
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: rowBase.rowClicked()
            propagateComposedEvents: true
        }
    }

    // Info row (read-only value)
    component InfoRow: Rectangle {
        id: infoRowBase
        property string label: ""
        property string value: ""
        property color  valueColor: "#8E8E93"

        width: parent ? parent.width : 0
        height: 48
        color: "transparent"

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }

        Text {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            text: infoRowBase.label
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 15 }
        }

        Text {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            text: infoRowBase.value
            color: infoRowBase.valueColor
            font { family: "Roboto"; pixelSize: 13 }
        }
    }

    // Slider row
    component SliderRow: Rectangle {
        id: sliderRowBase
        property string label: ""
        property int value: 0
        property int minValue: 0
        property int maxValue: 100
        property string suffix: "%"

        width: parent ? parent.width : 0
        height: 56
        color: "transparent"

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }

        Text {
            anchors { left: parent.left; leftMargin: 16; top: parent.top; topMargin: 8 }
            text: sliderRowBase.label
            color: sliderRowBase.enabled ? "#FFFFFF" : "#555"
            font { family: "Roboto"; pixelSize: 14 }
        }

        Text {
            anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 8 }
            text: sliderRowBase.value + sliderRowBase.suffix
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }
        }

        Slider {
            id: sl
            anchors {
                left: parent.left; leftMargin: 16
                right: parent.right; rightMargin: 16
                bottom: parent.bottom; bottomMargin: 8
            }
            height: 24
            from: sliderRowBase.minValue; to: sliderRowBase.maxValue
            value: sliderRowBase.value
            stepSize: 1
            enabled: sliderRowBase.enabled

            background: Rectangle {
                x: sl.leftPadding; y: sl.topPadding + sl.availableHeight / 2 - height / 2
                width: sl.availableWidth; height: 4; radius: 2
                color: "#3A3A3C"
                Rectangle {
                    width: sl.visualPosition * parent.width; height: parent.height; radius: 2
                    color: sl.enabled ? "#0A84FF" : "#555"
                }
            }

            handle: Rectangle {
                x: sl.leftPadding + sl.visualPosition * (sl.availableWidth - width)
                y: sl.topPadding + sl.availableHeight / 2 - height / 2
                width: 20; height: 20; radius: 10
                color: sl.enabled ? "#FFFFFF" : "#888"
            }

            onMoved: sliderRowBase.valueChanged(Math.round(sl.value))
        }
    }

    // Toggle switch
    component ToggleSwitch: Rectangle {
        id: toggleBase
        property bool checked: false

        width: 44; height: 24; radius: 12
        color: checked ? "#0A84FF" : "#2C2C2E"
        Behavior on color { ColorAnimation { duration: 150 } }

        Rectangle {
            id: thumb
            width: 20; height: 20; radius: 10
            color: "#FFFFFF"
            x: toggleBase.checked ? 22 : 2
            anchors.verticalCenter: parent.verticalCenter
            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: toggleBase.checked = !toggleBase.checked
        }
    }

    // Pill group — horizontal segmented selector
    component PillGroup: Row {
        id: pillGroupBase
        property var options: []
        property int selected: 0

        spacing: 4

        Repeater {
            model: pillGroupBase.options
            delegate: Rectangle {
                width: Math.max(52, pillLabel.implicitWidth + 16)
                height: 28; radius: 14
                color: pillGroupBase.selected === index ? "#0A84FF" : "#2C2C2E"
                Behavior on color { ColorAnimation { duration: 150 } }
                Text {
                    id: pillLabel
                    anchors.centerIn: parent
                    text: modelData
                    color: pillGroupBase.selected === index ? "#FFFFFF" : "#8E8E93"
                    // numeric weight: avoids "Font.SemiBold undefined" warning from
                    // QML init ordering inside Repeater delegates within inline components
                    font { family: "Roboto"; pixelSize: 12; weight: 600 }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: pillGroupBase.selectedChanged(index)
                }
            }
        }
    }
}
