// QmlKeyboard — touchscreen on-screen keyboard
// Qt VirtualKeyboard isn't built for the i386 target — this is the custom replacement.
// Slide-up overlay, Q60 dark theme, 44px+ key targets, QWERTY + numeric/symbols layouts.
// Usage:
//   QmlKeyboard { id: kb; anchors.fill: parent }
//   TextField { onActiveFocusChanged: if (activeFocus) kb.show(this) }
import QtQuick 2.15

Item {
    id: kb
    // Span the entire parent so the tap-outside backdrop covers everything.
    // The keyboard panel itself is positioned at the bottom inside this Item.
    anchors.fill: parent
    z: 200

    property var target: null
    property bool open: false
    property string layout: "qwerty"   // qwerty | numeric | symbols
    property bool shift: false
    property bool capsLock: false
    // Idle timeout (seconds). After this many seconds of no key activity the
    // keyboard auto-closes. 0 = disabled.
    property int idleTimeoutSec: 30

    // The keyboard panel height — matches the visual band at the bottom.
    readonly property int panelHeight: 232

    visible: open || kbPanel.y < height

    function show(t) {
        target = t
        open = true
        idleTimer.restart()
        if (t && t.forceActiveFocus) t.forceActiveFocus()
    }
    function hide() {
        open = false
        idleTimer.stop()
        // Releasing focus from the target makes the screen feel "done" — any
        // visible cursor on the original field disappears.
        if (target && target.focus !== undefined) target.focus = false
        target = null
    }

    function _kick() { idleTimer.restart() }

    function _insertText(s) {
        if (!target) return
        if (target.insert && target.cursorPosition !== undefined) {
            target.insert(target.cursorPosition, s)
        } else if (target.text !== undefined) {
            target.text = (target.text || "") + s
        }
        if (shift && !capsLock) shift = false
        _kick()
    }
    function _backspace() {
        if (!target || target.text === undefined) return
        var pos = target.cursorPosition !== undefined ? target.cursorPosition : target.text.length
        if (pos <= 0) return
        if (target.remove) target.remove(pos - 1, pos)
        else target.text = target.text.slice(0, -1)
        _kick()
    }
    function _enter() {
        if (target && target.accepted) target.accepted()
        hide()
    }

    // Idle auto-close
    Timer {
        id: idleTimer
        interval: kb.idleTimeoutSec * 1000
        running: kb.open && kb.idleTimeoutSec > 0
        repeat: false
        onTriggered: kb.hide()
    }

    // ── Backdrop: tap anywhere outside the keyboard panel to dismiss ───────
    MouseArea {
        anchors.fill: parent
        // Only active when keyboard is open; lets clicks through otherwise.
        enabled: kb.open
        visible: kb.open
        onClicked: kb.hide()
        // Don't block scroll; the keyboard is for one-shot input only.
    }

    // The keyboard panel itself — pinned to the bottom, slides up when open.
    Item {
        id: kbPanel
        anchors { left: parent.left; right: parent.right }
        height: kb.panelHeight
        y: kb.open ? (kb.height - height) : kb.height
        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        // Eat clicks so taps on the keyboard panel itself don't dismiss it
        // (the backdrop above sees them first via Z-order, but a sibling Item
        // with its own MouseArea wins because we explicitly capture here).
        MouseArea { anchors.fill: parent; onPressed: function(m) { m.accepted = true } }

    Rectangle {
        anchors.fill: parent
        color: "#1C1C1E"
        border { color: Qt.rgba(1, 1, 1, 0.1); width: 1 }

        // ── Top bar ───────────────────────────────────────────────────────────
        Row {
            id: topBar
            anchors { top: parent.top; left: parent.left; margins: 6 }
            height: 24
            spacing: 6

            Repeater {
                model: [
                    { id: "qwerty",  label: "ABC" },
                    { id: "numeric", label: "123" },
                    { id: "symbols", label: "#+=" }
                ]
                delegate: Rectangle {
                    width: 50; height: 22; radius: 6
                    color: kb.layout === modelData.id ? "#0A84FF" : "#2C2C2E"
                    Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        color: "#FFFFFF"
                        font { family: "Roboto"; pixelSize: 11; weight: 500 }
                    }
                    MouseArea { anchors.fill: parent; onClicked: { kb.layout = modelData.id; kb.shift = false } }
                }
            }
        }
        // Done / close button — sized to Apple HIG minimum (44pt) so it's
        // actually tappable. Reachable AT ALL TIMES — the prior 22x22 ✕ was
        // below-threshold and Doug couldn't dismiss the keyboard.
        Rectangle {
            id: doneBtn
            width: 56; height: 32; radius: 6
            color: doneArea.pressed ? "#0A84FF" : "#2C2C2E"
            border { color: Qt.rgba(1, 1, 1, 0.15); width: 1 }
            anchors { top: parent.top; right: parent.right; topMargin: 4; rightMargin: 6 }
            Text {
                anchors.centerIn: parent
                text: "Done"; color: "#FFFFFF"
                font { family: "Roboto"; pixelSize: 12; weight: 600 }
            }
            MouseArea { id: doneArea; anchors.fill: parent; onClicked: kb.hide() }
        }

        // ── Key area ──────────────────────────────────────────────────────────
        Loader {
            id: keyArea
            anchors { top: topBar.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; topMargin: 4; leftMargin: 6; rightMargin: 6; bottomMargin: 6 }
            sourceComponent: kb.layout === "qwerty" ? qwertyLayout
                           : kb.layout === "numeric" ? numericLayout : symbolsLayout
        }

        // ── QWERTY layout ─────────────────────────────────────────────────────
        Component {
            id: qwertyLayout
            Column {
                spacing: 5

                // Row 1: q w e r t y u i o p
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    Repeater {
                        model: ["q","w","e","r","t","y","u","i","o","p"]
                        delegate: KeyCap {
                            text: kb.shift || kb.capsLock ? modelData.toUpperCase() : modelData
                            keyWidth: 70
                            onPressed: kb._insertText(text)
                        }
                    }
                }
                // Row 2: a s d f g h j k l
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    Repeater {
                        model: ["a","s","d","f","g","h","j","k","l"]
                        delegate: KeyCap {
                            text: kb.shift || kb.capsLock ? modelData.toUpperCase() : modelData
                            keyWidth: 70
                            onPressed: kb._insertText(text)
                        }
                    }
                }
                // Row 3: shift z x c v b n m ⌫
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    KeyCap {
                        text: kb.capsLock ? "⇪" : "⇧"
                        keyWidth: 80
                        active: kb.shift || kb.capsLock
                        onPressed: {
                            if (kb.capsLock) { kb.capsLock = false; kb.shift = false }
                            else if (kb.shift) { kb.capsLock = true }
                            else { kb.shift = true }
                        }
                    }
                    Repeater {
                        model: ["z","x","c","v","b","n","m"]
                        delegate: KeyCap {
                            text: kb.shift || kb.capsLock ? modelData.toUpperCase() : modelData
                            keyWidth: 70
                            onPressed: kb._insertText(text)
                        }
                    }
                    KeyCap { text: "⌫"; keyWidth: 80; onPressed: kb._backspace() }
                }
                // Row 4: 123  space  .  return
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    KeyCap { text: "123"; keyWidth: 60; onPressed: kb.layout = "numeric" }
                    KeyCap { text: " "; keyWidth: 380; onPressed: kb._insertText(" ") }
                    KeyCap { text: "."; keyWidth: 60; onPressed: kb._insertText(".") }
                    KeyCap { text: "return"; keyWidth: 100; active: true; onPressed: kb._enter() }
                }
            }
        }

        // ── Numeric layout ────────────────────────────────────────────────────
        Component {
            id: numericLayout
            Column {
                spacing: 5
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    Repeater {
                        model: ["1","2","3","4","5","6","7","8","9","0"]
                        delegate: KeyCap {
                            text: modelData; keyWidth: 70
                            onPressed: kb._insertText(modelData)
                        }
                    }
                }
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    Repeater {
                        model: ["-","/",":",";","(",")","$","&","@","\""]
                        delegate: KeyCap {
                            text: modelData; keyWidth: 70
                            onPressed: kb._insertText(modelData)
                        }
                    }
                }
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    KeyCap { text: "#+="; keyWidth: 80; onPressed: kb.layout = "symbols" }
                    Repeater {
                        model: [".",",","?","!","'"]
                        delegate: KeyCap {
                            text: modelData; keyWidth: 70
                            onPressed: kb._insertText(modelData)
                        }
                    }
                    KeyCap { text: "⌫"; keyWidth: 80; onPressed: kb._backspace() }
                }
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    KeyCap { text: "ABC"; keyWidth: 60; onPressed: kb.layout = "qwerty" }
                    KeyCap { text: " "; keyWidth: 380; onPressed: kb._insertText(" ") }
                    KeyCap { text: "return"; keyWidth: 100; active: true; onPressed: kb._enter() }
                }
            }
        }

        // ── Symbols layout ────────────────────────────────────────────────────
        Component {
            id: symbolsLayout
            Column {
                spacing: 5
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    Repeater {
                        model: ["[","]","{","}","#","%","^","*","+","="]
                        delegate: KeyCap {
                            text: modelData; keyWidth: 70
                            onPressed: kb._insertText(modelData)
                        }
                    }
                }
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    Repeater {
                        model: ["_","\\","|","~","<",">","€","£","¥","•"]
                        delegate: KeyCap {
                            text: modelData; keyWidth: 70
                            onPressed: kb._insertText(modelData)
                        }
                    }
                }
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    KeyCap { text: "123"; keyWidth: 80; onPressed: kb.layout = "numeric" }
                    Repeater {
                        model: [".",",","?","!","'"]
                        delegate: KeyCap {
                            text: modelData; keyWidth: 70
                            onPressed: kb._insertText(modelData)
                        }
                    }
                    KeyCap { text: "⌫"; keyWidth: 80; onPressed: kb._backspace() }
                }
                Row {
                    spacing: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    KeyCap { text: "ABC"; keyWidth: 60; onPressed: kb.layout = "qwerty" }
                    KeyCap { text: " "; keyWidth: 380; onPressed: kb._insertText(" ") }
                    KeyCap { text: "return"; keyWidth: 100; active: true; onPressed: kb._enter() }
                }
            }
        }
    }   // close Rectangle (keyboard background)
    }   // close kbPanel Item

    // ── KeyCap inline component ───────────────────────────────────────────────
    component KeyCap: Rectangle {
        property string text: ""
        property real keyWidth: 70
        property bool active: false
        signal pressed()

        width: keyWidth
        height: 44
        radius: 6
        color: active ? "#0A84FF" : (capMouse.pressed ? "#3A3A3C" : "#2C2C2E")
        Behavior on color { ColorAnimation { duration: 80 } }

        Text {
            anchors.centerIn: parent
            text: parent.text
            color: "#FFFFFF"
            font {
                family: "Roboto"
                pixelSize: parent.text.length > 1 ? 13 : 17
                weight: 500
            }
        }
        MouseArea {
            id: capMouse
            anchors.fill: parent
            onClicked: parent.pressed()
        }
    }
}
