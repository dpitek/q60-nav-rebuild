// NavCompanionView — Lower screen nav companion
// Apple CarPlay aesthetic redesign
// All StatusBridge / NavigationService bindings preserved exactly.
// Expanded: destination entry (recents, favorites, search, route options sheet)
//           Active route: stop nav + route options inline expander
import QtQuick 6.6
import QtQuick.Controls 6.6
import "../components"

Item {
    id: root
    anchors.fill: parent

    property bool searchActive: false
    property string searchQuery: ""

    // On-screen keyboard handle (injected by ControlHubView)
    property var keyboard: null

    // Destination tapped — drives bottom sheet
    property string sheetDestName: ""
    property string sheetDestAddr: ""
    property bool   sheetVisible:  false

    // Active-route options expander
    property bool routeOptsExpanded: false
    property int  routeType: 0   // 0=Fastest 1=Shortest 2=Eco

    // Avoid toggles (route options)
    property bool avoidTolls:     false
    property bool avoidHighways:  false

    Rectangle { anchors.fill: parent; color: "#000000" }

    // ══════════════════════════════════════════════════════════════════════════
    // INACTIVE STATE — destination entry
    // ══════════════════════════════════════════════════════════════════════════
    Item {
        id: inactivePane
        anchors { fill: parent; margins: 12 }
        visible: !StatusBridge.navActive

        Flickable {
            anchors.fill: parent
            contentHeight: inactiveCol.implicitHeight
            clip: true

            Column {
                id: inactiveCol
                width: parent.width
                spacing: 10

                // ── Search bar ────────────────────────────────────────────────
                Rectangle {
                    width: parent.width; height: 48
                    radius: 24
                    color: "#1C1C1E"
                    border { color: searchActive ? "#0A84FF" : Qt.rgba(1, 1, 1, 0.1); width: 1 }

                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    Row {
                        anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                        spacing: 10

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "⌕"
                            color: "#8E8E93"
                            font { pixelSize: 20 }
                        }

                        TextField {
                            id: searchInput
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 50
                            color: "#FFFFFF"
                            selectionColor: "#0A84FF"
                            font { family: "Roboto"; pixelSize: 15 }
                            placeholderText: "Search destination…"
                            placeholderTextColor: "#8E8E93"
                            background: Item {}  // transparent — parent Row handles bg

                            onTextChanged: {
                                searchQuery = text
                            }
                            onActiveFocusChanged: {
                                searchActive = activeFocus
                                if (activeFocus && keyboard) keyboard.show(searchInput)
                            }
                        }

                        // Clear button — shown when text present
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "✕"
                            color: "#8E8E93"
                            font { pixelSize: 14 }
                            visible: searchQuery.length > 0

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    searchInput.text = ""
                                    searchQuery = ""
                                }
                            }
                        }
                    }
                }

                // ── Recents — shown when no search query ──────────────────────
                Column {
                    width: parent.width
                    spacing: 6
                    visible: searchQuery.length === 0

                    // Section header
                    Text {
                        text: "RECENT"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 10; weight: Font.Medium; letterSpacing: 1.2 }
                        leftPadding: 4
                    }

                    Repeater {
                        model: [
                            { name: "Home",   addr: "123 Kildaire Farm Rd, Cary",           dist: "2.3 mi" },
                            { name: "Work",   addr: "4001 E Chapel Hill Nelson, Durham",     dist: "18.4 mi" },
                            { name: "Target", addr: "1205 Walnut St, Cary",                 dist: "4.1 mi" },
                            { name: "Topsail Island", addr: "Surf City, NC",               dist: "123 mi" }
                        ]

                        delegate: Rectangle {
                            width: parent.width; height: 54
                            radius: 12
                            color: "#1C1C1E"
                            border { color: Qt.rgba(1, 1, 1, 0.07); width: 1 }

                            Row {
                                anchors { fill: parent; margins: 12 }
                                spacing: 12

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "📍"
                                    font { pixelSize: 18 }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 90
                                    spacing: 2

                                    Text {
                                        text: modelData.name
                                        color: "#FFFFFF"
                                        font { family: "Roboto"; pixelSize: 14; weight: Font.Medium }
                                        width: parent.width; elide: Text.ElideRight
                                    }
                                    Text {
                                        text: modelData.addr
                                        color: "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 11 }
                                        width: parent.width; elide: Text.ElideRight
                                    }
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.dist
                                    color: "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 12 }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    sheetDestName = modelData.name
                                    sheetDestAddr = modelData.addr
                                    sheetVisible  = true
                                }
                            }
                        }
                    }
                }

                // ── Search results — shown when query.length > 2 ──────────────
                Column {
                    width: parent.width
                    spacing: 6
                    visible: searchQuery.length > 2

                    Text {
                        text: "RESULTS"
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 10; weight: Font.Medium; letterSpacing: 1.2 }
                        leftPadding: 4
                    }

                    Repeater {
                        // Mock results derived from the query — SearchService integration deferred
                        model: [
                            { name: searchQuery + " Place",       addr: "1 Main St, Cary, NC",          dist: "1.2 mi" },
                            { name: searchQuery + " Center",      addr: "500 Crossroads Blvd, Cary, NC",dist: "3.4 mi" },
                            { name: searchQuery + " Drive",       addr: "700 NW Cary Pkwy, Cary, NC",   dist: "5.6 mi" },
                            { name: searchQuery + " Park",        addr: "200 Evans Rd, Cary, NC",       dist: "7.8 mi" },
                            { name: searchQuery + " Commons",     addr: "101 Chatham St, Cary, NC",     dist: "9.1 mi" }
                        ]

                        delegate: Rectangle {
                            width: parent.width; height: 54
                            radius: 12
                            color: "#1C1C1E"
                            border { color: Qt.rgba(1, 1, 1, 0.07); width: 1 }

                            Row {
                                anchors { fill: parent; margins: 12 }
                                spacing: 12

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "🔍"
                                    font { pixelSize: 18 }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 90
                                    spacing: 2

                                    Text {
                                        text: modelData.name
                                        color: "#FFFFFF"
                                        font { family: "Roboto"; pixelSize: 14; weight: Font.Medium }
                                        width: parent.width; elide: Text.ElideRight
                                    }
                                    Text {
                                        text: modelData.addr
                                        color: "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 11 }
                                        width: parent.width; elide: Text.ElideRight
                                    }
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.dist
                                    color: "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 12 }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    sheetDestName = modelData.name
                                    sheetDestAddr = modelData.addr
                                    sheetVisible  = true
                                }
                            }
                        }
                    }
                }

                // ── Favorites — shown when no search query ────────────────────
                Column {
                    width: parent.width
                    spacing: 6
                    visible: searchQuery.length === 0

                    Row {
                        width: parent.width
                        leftPadding: 4

                        Text {
                            text: "★ FAVORITES"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 10; weight: Font.Medium; letterSpacing: 1.2 }
                        }
                    }

                    Repeater {
                        model: [
                            { name: "Home", addr: "123 Kildaire Farm Rd, Cary", dist: "2.3 mi", icon: "🏠" },
                            { name: "Work", addr: "4001 E Chapel Hill Nelson, Durham", dist: "18.4 mi", icon: "🏢" }
                        ]

                        delegate: Rectangle {
                            width: parent.width; height: 54
                            radius: 12
                            color: "#1C1C1E"
                            border { color: Qt.rgba(1, 1, 1, 0.07); width: 1 }

                            Row {
                                anchors { fill: parent; margins: 12 }
                                spacing: 12

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.icon
                                    font { pixelSize: 18 }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 90
                                    spacing: 2

                                    Text {
                                        text: modelData.name
                                        color: "#FFFFFF"
                                        font { family: "Roboto"; pixelSize: 14; weight: Font.Medium }
                                        width: parent.width; elide: Text.ElideRight
                                    }
                                    Text {
                                        text: modelData.addr
                                        color: "#8E8E93"
                                        font { family: "Roboto"; pixelSize: 11 }
                                        width: parent.width; elide: Text.ElideRight
                                    }
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.dist
                                    color: "#8E8E93"
                                    font { family: "Roboto"; pixelSize: 12 }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    sheetDestName = modelData.name
                                    sheetDestAddr = modelData.addr
                                    sheetVisible  = true
                                }
                            }
                        }
                    }

                    // Add Favorite stub
                    Rectangle {
                        width: parent.width; height: 40
                        radius: 12
                        color: "transparent"
                        border { color: Qt.rgba(1, 1, 1, 0.12); width: 1 }

                        Row {
                            anchors.centerIn: parent
                            spacing: 8

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "+"
                                color: "#0A84FF"
                                font { pixelSize: 18; weight: Font.Light }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Add Favorite"
                                color: "#0A84FF"
                                font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
                            }
                        }

                        MouseArea { anchors.fill: parent; onClicked: { /* no-op */ } }
                    }
                }

            } // Column
        } // Flickable
    } // inactivePane

    // ══════════════════════════════════════════════════════════════════════════
    // ACTIVE ROUTE STATE
    // ══════════════════════════════════════════════════════════════════════════
    Column {
        anchors { fill: parent; margins: 12 }
        spacing: 10
        visible: StatusBridge.navActive

        // Turn card — full width
        Rectangle {
            id: turnCard
            width: parent.width; height: 96
            radius: 16
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }

            Row {
                anchors { fill: parent; margins: 12 }
                spacing: 14

                TurnArrow {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 60; height: 60
                    direction: {
                        var m = StatusBridge.nextManeuver.toLowerCase()
                        if (m.indexOf("right") >= 0 && m.indexOf("sharp") >= 0) return 5
                        if (m.indexOf("left")  >= 0 && m.indexOf("sharp") >= 0) return 6
                        if (m.indexOf("right") >= 0 && m.indexOf("slight") >= 0) return 3
                        if (m.indexOf("left")  >= 0 && m.indexOf("slight") >= 0) return 4
                        if (m.indexOf("right") >= 0) return 1
                        if (m.indexOf("left")  >= 0) return 2
                        if (m.indexOf("u-turn") >= 0) return 7
                        if (m.indexOf("arriv")  >= 0) return 8
                        return 0
                    }
                    arrowColor: StatusBridge.approachingTurn ? "#FF9F0A" : "#0A84FF"
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    width: parent.width - 74

                    Text {
                        text: StatusBridge.nextDistance < 0.1
                              ? "Now"
                              : (StatusBridge.nextDistance < 1.0
                                 ? Math.round(StatusBridge.nextDistance * 5280) + " ft"
                                 : StatusBridge.nextDistance.toFixed(1) + " mi")
                        color: StatusBridge.approachingTurn ? "#FF9F0A" : "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 26; weight: Font.Bold }
                    }
                    Text {
                        text: StatusBridge.nextStreet
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 15; weight: Font.Medium }
                        width: parent.width; elide: Text.ElideRight
                    }
                    Text {
                        text: StatusBridge.nextManeuver
                        color: "#8E8E93"
                        font { family: "Roboto"; pixelSize: 12 }
                        width: parent.width; elide: Text.ElideRight
                    }
                }
            }
        }

        // Approaching turn pulse accent
        Rectangle {
            width: parent.width; height: 3; radius: 1.5
            color: "#FF9F0A"
            opacity: StatusBridge.approachingTurn ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 200 } }

            SequentialAnimation on opacity {
                running: StatusBridge.approachingTurn
                loops: Animation.Infinite
                NumberAnimation { to: 0.2; duration: 600 }
                NumberAnimation { to: 1.0; duration: 600 }
            }
        }

        // ── Speed | ETA | Distance — three-cell row ───────────────────────────
        Rectangle {
            width: parent.width; height: 72
            radius: 16
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }

            Row {
                anchors.fill: parent

                Item {
                    width: parent.width / 3; height: parent.height

                    Column {
                        anchors.centerIn: parent
                        spacing: 2

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 5

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: StatusBridge.speed.toFixed(0)
                                color: StatusBridge.speed > StatusBridge.speedLimit + 5
                                       ? "#FF453A" : "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 26; weight: Font.Bold }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "/" + (StatusBridge.speedLimit > 0
                                             ? StatusBridge.speedLimit.toFixed(0) : "--")
                                color: "#8E8E93"
                                font { family: "Roboto"; pixelSize: 14 }
                            }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "MPH"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 10; capitalization: Font.AllUppercase; letterSpacing: 1 }
                        }
                    }
                }

                Rectangle { width: 1; height: 40; color: Qt.rgba(1, 1, 1, 0.12); anchors.verticalCenter: parent.verticalCenter }

                Item {
                    width: parent.width / 3; height: parent.height

                    Column {
                        anchors.centerIn: parent
                        spacing: 2

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: StatusBridge.eta.length > 0 ? StatusBridge.eta : "--:--"
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 22; weight: Font.SemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Arrive"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 10 }
                        }
                    }
                }

                Rectangle { width: 1; height: 40; color: Qt.rgba(1, 1, 1, 0.12); anchors.verticalCenter: parent.verticalCenter }

                Item {
                    width: parent.width / 3; height: parent.height

                    Column {
                        anchors.centerIn: parent
                        spacing: 2

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: NavigationService.remaining.toFixed(1)
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 22; weight: Font.SemiBold }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "mi left"
                            color: "#8E8E93"
                            font { family: "Roboto"; pixelSize: 10 }
                        }
                    }
                }
            }
        }

        // ── Rerouting banner ──────────────────────────────────────────────────
        Rectangle {
            width: parent.width; height: 40; radius: 12
            visible: NavigationService.rerouting
            color: "#FF9F0A"

            Row {
                anchors.centerIn: parent
                spacing: 8
                Text { anchors.verticalCenter: parent.verticalCenter; text: "⟳"; color: "#000000"; font { pixelSize: 18 } }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Recalculating route…"
                    color: "#000000"
                    font { family: "Roboto"; pixelSize: 14; weight: Font.SemiBold }
                }
            }
        }

        // ── Route options link + inline expander ──────────────────────────────
        Row {
            width: parent.width
            spacing: 10

            // Route options toggle link
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Route options " + (routeOptsExpanded ? "▴" : "▾")
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 12 }

                MouseArea {
                    anchors.fill: parent
                    onClicked: routeOptsExpanded = !routeOptsExpanded
                }
            }

            Item { width: 1; height: 1 } // spacer

            // Stop Navigation — red outline pill
            Rectangle {
                height: 36; width: stopNavLabel.implicitWidth + 28
                radius: 18
                color: "transparent"
                border { color: "#FF453A"; width: 1 }

                Text {
                    id: stopNavLabel
                    anchors.centerIn: parent
                    text: "Stop Navigation"
                    color: "#FF453A"
                    font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: NavigationService.stopRoute()
                }
            }
        }

        // Route options expander card
        Rectangle {
            width: parent.width
            height: routeOptsExpanded ? routeOptsCol.implicitHeight + 24 : 0
            radius: 12
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.08); width: 1 }
            clip: true
            visible: routeOptsExpanded

            Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            Column {
                id: routeOptsCol
                anchors { top: parent.top; left: parent.left; right: parent.right; margins: 12 }
                spacing: 10

                // Route type pills
                Row {
                    spacing: 8
                    anchors.horizontalCenter: parent.horizontalCenter

                    Repeater {
                        model: ["Fastest", "Shortest", "Eco"]

                        delegate: Rectangle {
                            height: 30; width: pillLabel.implicitWidth + 20
                            radius: 15
                            color: routeType === index ? "#0A84FF" : "#2C2C2E"

                            Text {
                                id: pillLabel
                                anchors.centerIn: parent
                                text: modelData
                                color: routeType === index ? "#FFFFFF" : "#8E8E93"
                                font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    routeType = index
                                    NavigationService.requestReroute(index)  // no-op stub
                                }
                            }
                        }
                    }
                }

                // Avoid toggles
                Row {
                    width: parent.width
                    spacing: 16

                    Repeater {
                        model: [
                            { label: "Tolls",     prop: "avoidTolls" },
                            { label: "Highways",  prop: "avoidHighways" }
                        ]

                        delegate: Row {
                            spacing: 8

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                color: "#FFFFFF"
                                font { family: "Roboto"; pixelSize: 13 }
                            }

                            Rectangle {
                                width: 38; height: 22; radius: 11
                                color: (index === 0 ? avoidTolls : avoidHighways) ? "#0A84FF" : "#3A3A3C"
                                Behavior on color { ColorAnimation { duration: 150 } }

                                Rectangle {
                                    width: 18; height: 18; radius: 9
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: (index === 0 ? avoidTolls : avoidHighways) ? 17 : 2
                                    color: "#FFFFFF"
                                    Behavior on x { NumberAnimation { duration: 150 } }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        if (index === 0) avoidTolls = !avoidTolls
                                        else             avoidHighways = !avoidHighways
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

    } // Active route Column

    // ══════════════════════════════════════════════════════════════════════════
    // ROUTE OPTIONS BOTTOM SHEET
    // ══════════════════════════════════════════════════════════════════════════

    // Scrim
    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: sheetVisible ? 0.5 : 0.0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 250 } }

        MouseArea {
            anchors.fill: parent
            onClicked: sheetVisible = false
        }
    }

    // Sheet itself
    Rectangle {
        id: routeSheet
        width: parent.width
        height: 210
        radius: 16
        color: "#1C1C1E"
        border { color: Qt.rgba(1, 1, 1, 0.1); width: 1 }

        // Slide from bottom
        y: sheetVisible ? parent.height - height : parent.height
        Behavior on y { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

        property int sheetRouteType: 0
        property bool sheetAvoidTolls:    false
        property bool sheetAvoidHighways: false

        Column {
            anchors { fill: parent; margins: 16 }
            spacing: 10

            // Destination header
            Column {
                width: parent.width
                spacing: 2

                Text {
                    text: sheetDestName
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 16; weight: Font.SemiBold }
                    width: parent.width; elide: Text.ElideRight
                }
                Text {
                    text: sheetDestAddr
                    color: "#8E8E93"
                    font { family: "Roboto"; pixelSize: 12 }
                    width: parent.width; elide: Text.ElideRight
                }
            }

            // Route type pills
            Row {
                spacing: 8

                Repeater {
                    model: ["Fastest", "Shortest", "Eco"]

                    delegate: Rectangle {
                        height: 30; width: sheetPillLabel.implicitWidth + 20
                        radius: 15
                        color: routeSheet.sheetRouteType === index ? "#0A84FF" : "#2C2C2E"

                        Text {
                            id: sheetPillLabel
                            anchors.centerIn: parent
                            text: modelData
                            color: routeSheet.sheetRouteType === index ? "#FFFFFF" : "#8E8E93"
                            font { family: "Roboto"; pixelSize: 13; weight: Font.Medium }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: routeSheet.sheetRouteType = index
                        }
                    }
                }
            }

            // Avoid toggles row
            Row {
                spacing: 20

                Repeater {
                    model: ["Tolls", "Highways"]

                    delegate: Row {
                        spacing: 8

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData
                            color: "#FFFFFF"
                            font { family: "Roboto"; pixelSize: 13 }
                        }

                        Rectangle {
                            width: 38; height: 22; radius: 11
                            color: (index === 0 ? routeSheet.sheetAvoidTolls : routeSheet.sheetAvoidHighways) ? "#0A84FF" : "#3A3A3C"
                            Behavior on color { ColorAnimation { duration: 150 } }

                            Rectangle {
                                width: 18; height: 18; radius: 9
                                anchors.verticalCenter: parent.verticalCenter
                                x: (index === 0 ? routeSheet.sheetAvoidTolls : routeSheet.sheetAvoidHighways) ? 17 : 2
                                color: "#FFFFFF"
                                Behavior on x { NumberAnimation { duration: 150 } }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (index === 0) routeSheet.sheetAvoidTolls = !routeSheet.sheetAvoidTolls
                                    else             routeSheet.sheetAvoidHighways = !routeSheet.sheetAvoidHighways
                                }
                            }
                        }
                    }
                }
            }

            // Start Navigation button
            Rectangle {
                width: parent.width; height: 44
                radius: 22
                color: "#0A84FF"

                Text {
                    anchors.centerIn: parent
                    text: "Start Navigation"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 15; weight: Font.SemiBold }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        // Simulate nav start — real impl wires to NavigationService.startRoute()
                        NavigationService.startRoute(sheetDestName)
                        sheetVisible = false
                    }
                }
            }

            // Cancel link
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Cancel"
                color: "#8E8E93"
                font { family: "Roboto"; pixelSize: 13 }

                MouseArea {
                    anchors.fill: parent
                    onClicked: sheetVisible = false
                }
            }
        }
    }

}
