// SettingsView — Full settings screen for lower 7" display
// Scrollable, grouped sections; pure QML local state — C++ SettingsService bindings stubbed.
import QtQuick 6.6
import QtQuick.Controls 6.6

Item {
    id: root
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ── Local settings state (bind to C++ SettingsService when available) ─────
    QtObject {
        id: settings

        // Display
        property int upperBrightness: 80
        property int lowerBrightness: 80
        property int dayNightMode: 0   // 0=Auto 1=Day 2=Night

        // Clock
        property int timeFormat: 0    // 0=12h 1=24h
        property bool gpsSync: true
        property int clockHour: 12
        property int clockMinute: 0

        // Units
        property int distanceUnit: 0  // 0=mi 1=km
        property int tempUnit: 0      // 0=°F 1=°C
        property int fuelUnit: 0      // 0=MPG 1=L/100km

        // Navigation
        property bool voiceGuidance: true
        property int voiceVolume: 70
        property int routePref: 0     // 0=Fastest 1=Shortest 2=Eco
        property bool avoidTolls: false
        property bool avoidHighways: false
        property bool poiIconsOnMap: true

        // Audio
        property bool clickSounds: true
        property int navPromptVolume: 80

        // Bluetooth (mock)
        property string connectedDevice: "Doug's iPhone"
        property int connectedBattery: 82

        // Vehicle
        property bool vdcEnabled: true

        // Lights
        property int lightShutoff: 2         // index: 0=Off 1=30s 2=45s 3=60s 4=90s 5=2m 6=3m
        property int headlightSensitivity: 1  // 0=Low 1=Med 2=High
        property bool drlEnabled: true
        property bool approachLighting: true
        property int approachLightDuration: 1  // 0=30s 1=60s 2=90s
        property bool welcomeLighting: true
        property int interiorLightTimer: 1    // 0=15s 1=30s 2=45s 3=60s

        // Door Locks
        property int autoLockSpeed: 1         // 0=Off 1=15mph 2=25mph
        property bool autoUnlockPark: true
        property bool autoUnlockKeyRemoval: false
        property bool fobLockAll: true

        // Mirrors
        property bool mirrorTiltReverse: true
        property bool mirrorFoldLock: false

        // Wipers
        property int rainSensorSensitivity: 3  // 1-5
        property int wiperDelay: 3             // 1-5

        // Comfort
        property bool seatMemoryOnUnlock: true
        property bool powerWindowAutoOpen: true
        property bool seatbeltReminder: true
        property int parkAssistChimeVolume: 2   // 0=Off 1=Low 2=Med 3=High

        // Map
        property int mapOrientation: 0        // 0=Heading 1=North 2=3D
        property bool speedLimitDisplay: true
        property int mapDetailLevel: 1        // 0=Low 1=Med 2=High

        // Maintenance
        property int maintenanceInterval: 1    // 0=3k 1=5k 2=7.5k 3=10k
    }

    // Pairing sheet visible flag
    property bool pairingSheetVisible: false
    // Factory reset dialog visible flag
    property bool resetDialogVisible: false
    // Profile view visible flag
    property bool profileViewVisible: false

    // ── Header ────────────────────────────────────────────────────────────────
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 48
        color: "#000000"

        // Bottom divider
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

    // ── Scrollable content ────────────────────────────────────────────────────
    Flickable {
        id: scroller
        anchors {
            top: header.bottom
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        clip: true
        contentHeight: contentCol.implicitHeight + 24
        contentWidth: width
        boundsMovement: Flickable.StopAtBounds

        Column {
            id: contentCol
            width: scroller.width
            spacing: 0

            // ================================================================
            // DRIVER PROFILES  (pinned to top)
            // ================================================================
            SectionHeader { label: "DRIVER PROFILES" }

            // Active profile summary card — tap to open ProfileView
            Rectangle {
                width: contentCol.width - 32
                height: 56
                radius: 14
                color: "#1C1C1E"
                anchors.horizontalCenter: parent.horizontalCenter

                // Accent color left bar
                Rectangle {
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width: 4; radius: 2
                    color: ProfileService.activeAccentColor
                }

                Row {
                    anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
                    spacing: 10

                    // Avatar
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

                // Chevron
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

            // ================================================================
            // DISPLAY
            // ================================================================
            SectionHeader { label: "DISPLAY" }

            // Upper Screen Brightness
            SliderRow {
                label: "Upper Screen Brightness"
                value: settings.upperBrightness
                onValueChanged: settings.upperBrightness = value
            }

            // Lower Screen Brightness
            SliderRow {
                label: "Lower Screen Brightness"
                value: settings.lowerBrightness
                onValueChanged: settings.lowerBrightness = value
            }

            // Day/Night Mode
            SettingsRow {
                label: "Day/Night Mode"
                control: PillGroup {
                    options: ["Auto", "Day", "Night"]
                    selected: settings.dayNightMode
                    onSelectedChanged: settings.dayNightMode = selected
                }
            }

            // ================================================================
            // CLOCK
            // ================================================================
            SectionHeader { label: "CLOCK" }

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
                control: ToggleSwitch {
                    checked: settings.gpsSync
                    onCheckedChanged: settings.gpsSync = checked
                }
            }

            // Time picker — only shown when GPS sync is off
            Rectangle {
                width: contentCol.width
                height: settings.gpsSync ? 0 : 56
                clip: true
                color: "transparent"
                visible: !settings.gpsSync

                Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                // Bottom divider
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 1
                    color: Qt.rgba(1, 1, 1, 0.06)
                }

                Row {
                    anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Set Time"
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 15 }
                    }

                    // Hour spinner
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

                    // Minute spinner
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

            // ================================================================
            // UNITS
            // ================================================================
            SectionHeader { label: "UNITS" }

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
                    options: ["MPG", "L/100km"]
                    selected: settings.fuelUnit
                    onSelectedChanged: settings.fuelUnit = selected
                }
            }

            // ================================================================
            // BLUETOOTH
            // ================================================================
            SectionHeader { label: "BLUETOOTH" }

            // Connected device card
            Rectangle {
                width: contentCol.width - 32
                height: 56
                radius: 12
                color: "#1C1C1E"
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 1
                    color: Qt.rgba(1, 1, 1, 0.06)
                    visible: false
                }

                Row {
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    spacing: 8

                    Text { text: "⑂"; color: "#0A84FF"; font { pixelSize: 18 } }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            text: settings.connectedDevice
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                        }
                        Text {
                            text: "🔋 " + settings.connectedBattery + "%"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 11 }
                        }
                    }
                }

                Rectangle {
                    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    width: 88; height: 30; radius: 8
                    color: "#2C2C2E"
                    border { color: "#FF453A"; width: 1 }
                    Text {
                        anchors.centerIn: parent; text: "Disconnect"
                        color: "#FF453A"
                        font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: settings.connectedDevice = ""
                    }
                }
            }

            Item { width: 1; height: 8 }

            // Pair new device
            SettingsRow {
                label: "Pair New Device"
                control: Text {
                    text: "›"
                    color: "#8E8E93"
                    font { pixelSize: 18 }
                }
                onRowClicked: root.pairingSheetVisible = true
            }

            // Stored devices
            Repeater {
                model: ["Doug's iPhone", "KellyAnne's iPhone"]
                delegate: SettingsRow {
                    label: modelData
                    labelSecondary: "Saved device"
                    control: Rectangle {
                        width: 28; height: 28; radius: 8; color: "transparent"
                        Text { anchors.centerIn: parent; text: "🗑"; font.pixelSize: 15 }
                        MouseArea { anchors.fill: parent; onClicked: console.log("Forget", modelData) }
                    }
                }
            }

            // ================================================================
            // NAVIGATION
            // ================================================================
            SectionHeader { label: "NAVIGATION" }

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

            // ================================================================
            // AUDIO
            // ================================================================
            SectionHeader { label: "AUDIO" }

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

            // ================================================================
            // VEHICLE
            // ================================================================
            SectionHeader { label: "VEHICLE" }

            SettingsRow {
                label: "Rain Sensor"
                control: ToggleSwitch {
                    checked: VehicleService.rainSensorEnabled
                    onCheckedChanged: if (checked !== VehicleService.rainSensorEnabled) VehicleService.setRainSensor(checked)
                }
            }

            // VDC
            Column {
                width: contentCol.width
                spacing: 0

                SettingsRow {
                    label: "VDC (Traction Control)"
                    control: ToggleSwitch {
                        checked: settings.vdcEnabled
                        onCheckedChanged: settings.vdcEnabled = checked
                    }
                }

                Rectangle {
                    width: contentCol.width
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

            // ================================================================
            // LIGHTS
            // ================================================================
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

            // ================================================================
            // DOOR LOCKS
            // ================================================================
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

            // ================================================================
            // MIRRORS
            // ================================================================
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

            // ================================================================
            // WIPERS
            // ================================================================
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

            // ================================================================
            // COMFORT & CONVENIENCE
            // ================================================================
            SectionHeader { label: "COMFORT & CONVENIENCE" }

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

            // ================================================================
            // MAP
            // ================================================================
            SectionHeader { label: "MAP" }

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

            // ================================================================
            // MAINTENANCE
            // ================================================================
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

            // ================================================================
            // SYSTEM
            // ================================================================
            SectionHeader { label: "SYSTEM" }

            InfoRow { label: "Software Version"; value: "q60nav v0.1.0" }
            InfoRow { label: "Map Data";         value: "NC OSM 2026-05-12" }
            InfoRow { label: "Geocoder DB";      value: "743,535 places — NC" }
            InfoRow { label: "Build";            value: "Qt 6.6.3 i386/Bonnell" }

            // Factory Reset button
            Rectangle {
                width: contentCol.width - 32
                height: 44
                radius: 12
                color: "transparent"
                border { color: "#FF453A"; width: 1.5 }
                anchors.horizontalCenter: parent.horizontalCenter

                Text {
                    anchors.centerIn: parent
                    text: "Reset All Settings"
                    color: "#FF453A"
                    font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.resetDialogVisible = true
                }
            }

            Item { width: 1; height: 24 }
        }
    }

    // ── Pairing modal sheet ───────────────────────────────────────────────────
    Rectangle {
        id: pairingSheet
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.72)
        visible: root.pairingSheetVisible
        opacity: root.pairingSheetVisible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }

        Rectangle {
            anchors {
                bottom: parent.bottom
                left: parent.left
                right: parent.right
            }
            height: 200; radius: 20
            color: "#1C1C1E"

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 24 }
                spacing: 12

                // Pulsing BT icon
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
                    text: "Put your device in pairing mode, then\nsearch for 'Q60 Nav' on your device"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 14 }
                    horizontalAlignment: Text.AlignHCenter
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 120; height: 36; radius: 10
                    color: "#2C2C2E"
                    Text {
                        anchors.centerIn: parent; text: "Cancel"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.pairingSheetVisible = false
                    }
                }
            }
        }
    }

    // ── Factory Reset confirmation dialog ─────────────────────────────────────
    Rectangle {
        id: resetDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.72)
        visible: root.resetDialogVisible
        opacity: root.resetDialogVisible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }

        Rectangle {
            anchors.centerIn: parent
            width: 300; height: 160; radius: 20
            color: "#1C1C1E"

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 24 }
                spacing: 16

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "This will reset all preferences.\nAre you sure?"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 14 }
                    horizontalAlignment: Text.AlignHCenter
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12

                    Rectangle {
                        width: 110; height: 38; radius: 10; color: "#2C2C2E"
                        Text {
                            anchors.centerIn: parent; text: "Cancel"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.resetDialogVisible = false
                        }
                    }

                    Rectangle {
                        width: 110; height: 38; radius: 10
                        color: "transparent"
                        border { color: "#FF453A"; width: 1.5 }
                        Text {
                            anchors.centerIn: parent; text: "Reset"
                            color: "#FF453A"
                            font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                // TODO: call SettingsService.factoryReset() when C++ backend wired
                                root.resetDialogVisible = false
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
        z: 10
        onVisibleChanged: {
            if (!visible) root.profileViewVisible = false
        }
    }

    // ── Inline component definitions ──────────────────────────────────────────

    // Section header label
    component SectionHeader: Item {
        property string label: ""
        width: contentCol.width
        height: 36

        Text {
            anchors { left: parent.left; leftMargin: 16; bottom: parent.bottom; bottomMargin: 4 }
            text: label
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

        width: contentCol.width
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
        property string label: ""
        property string value: ""

        width: contentCol.width
        height: 48
        color: "transparent"

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }

        Text {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            text: label
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 15 }
        }

        Text {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            text: value
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }
        }
    }

    // Slider row
    component SliderRow: Rectangle {
        id: sliderRowBase
        property string label: ""
        property int value: 0

        width: contentCol.width
        height: 56
        color: "transparent"

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }

        Text {
            id: sliderLabel
            anchors { left: parent.left; leftMargin: 16; top: parent.top; topMargin: 8 }
            text: sliderRowBase.label
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 14 }
        }

        Text {
            anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 8 }
            text: sliderRowBase.value + "%"
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
            from: 0; to: 100
            value: sliderRowBase.value
            stepSize: 1

            background: Rectangle {
                x: sl.leftPadding; y: sl.topPadding + sl.availableHeight / 2 - height / 2
                width: sl.availableWidth; height: 4; radius: 2
                color: "#3A3A3C"
                Rectangle {
                    width: sl.visualPosition * parent.width; height: parent.height; radius: 2
                    color: "#0A84FF"
                }
            }

            handle: Rectangle {
                x: sl.leftPadding + sl.visualPosition * (sl.availableWidth - width)
                y: sl.topPadding + sl.availableHeight / 2 - height / 2
                width: 20; height: 20; radius: 10
                color: "#FFFFFF"
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
                    font { family: "Roboto"; pixelSize: 12; weight: Font.SemiBold }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: pillGroupBase.selectedChanged(index)
                }
            }
        }
    }
}
