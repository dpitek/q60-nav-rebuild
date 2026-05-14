// IncomingCallView.qml — Full-screen incoming call modal overlay
// Shown over upper or lower screen when an incoming call arrives
import QtQuick
import "../components"

Item {
    id: root
    anchors.fill: parent

    // Set callerNumber when the overlay is shown. If callerName is also
    // provided by the caller it wins; otherwise the name is resolved from the
    // shared ContactsModel (mock data today; PBAP-backed later).
    property string callerNumber: ""
    property string callerName:   ""

    signal answered()
    signal declined()

    // ── Caller ID lookup ─────────────────────────────────────────────────────
    // Local ContactsModel instance — the model itself is a static mock until
    // PBAP lands, so duplicating it across screens is cheap and keeps this
    // overlay self-contained when invoked from anywhere in the QML tree.
    ContactsModel { id: contacts }

    // Display name: explicit callerName overrides, else look up by number.
    // lookupCallerName() returns the raw number when no match is found, so we
    // detect that and treat it as "unresolved" for the secondary number row.
    readonly property string _lookupResult: callerNumber.length > 0
                                            ? contacts.lookupCallerName(callerNumber)
                                            : ""
    readonly property bool   _hasContactMatch: callerNumber.length > 0
                                               && _lookupResult !== callerNumber
                                               && _lookupResult.length > 0
    readonly property string displayName: callerName.length > 0
                                          ? callerName
                                          : (_hasContactMatch ? _lookupResult : callerNumber)

    // ── Dark scrim ──────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: 0.92
    }

    // ── Content ─────────────────────────────────────────────────────────────
    Column {
        anchors {
            horizontalCenter: parent.horizontalCenter
            verticalCenter: parent.verticalCenter
            verticalCenterOffset: -30
        }
        spacing: 16

        // Avatar circle with caller initials
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 80; height: 80; radius: 40
            color: "#1C1C1E"
            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1.5 }

            Text {
                anchors.centerIn: parent
                text: root.displayName.length > 0 && /[A-Za-z]/.test(root.displayName.charAt(0))
                      ? root.displayName.charAt(0).toUpperCase()
                      : "?"
                color: "#0A84FF"
                font { family: "Roboto"; pixelSize: 32; weight: 700 }
            }
        }

        // Pulsing "Incoming Call" label
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Incoming Call"
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 13 }

            SequentialAnimation on opacity {
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 700 }
                NumberAnimation { to: 1.0; duration: 700 }
            }
        }

        // Caller name (resolved from contacts when possible, else number)
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.displayName.length > 0 ? root.displayName : "Unknown"
            color: "#FFFFFF"
            font { family: "Roboto"; pixelSize: 28; weight: 700 }
            width: 320
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
        }

        // Caller number (shown beneath the name when we resolved to a contact
        // or when an explicit callerName was supplied alongside the number)
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.callerNumber
            color: "#8E8E93"
            font { family: "Roboto"; pixelSize: 17 }
            visible: root.callerNumber.length > 0
                     && root.displayName !== root.callerNumber
                     && root.displayName.length > 0
        }
    }

    // ── Action Buttons ───────────────────────────────────────────────────────
    Row {
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 44
        }
        spacing: 48

        // Decline
        Rectangle {
            width: 160; height: 56; radius: 28
            color: declineArea.pressed ? "#CC1A1A" : "#FF453A"

            Behavior on color { ColorAnimation { duration: 100 } }

            Row {
                anchors.centerIn: parent
                spacing: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✆"
                    color: "#FFFFFF"
                    font { pixelSize: 18; }
                    rotation: 135
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Decline"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 17; weight: 600 }
                }
            }

            MouseArea {
                id: declineArea
                anchors.fill: parent
                onClicked: root.declined()
            }
        }

        // Answer
        Rectangle {
            width: 160; height: 56; radius: 28
            color: answerArea.pressed ? "#1E9E45" : "#30D158"

            Behavior on color { ColorAnimation { duration: 100 } }

            Row {
                anchors.centerIn: parent
                spacing: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✆"
                    color: "#FFFFFF"
                    font { pixelSize: 18 }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Answer"
                    color: "#FFFFFF"
                    font { family: "Roboto"; pixelSize: 17; weight: 600 }
                }
            }

            MouseArea {
                id: answerArea
                anchors.fill: parent
                onClicked: root.answered()
            }
        }
    }
}
