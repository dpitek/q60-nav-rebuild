// ContactsModel.qml — Shared contacts + recents data source for PhoneView and IncomingCallView.
//
// ─────────────────────────────────────────────────────────────────────────────
// Mock data — real PBAP binding pending BlueZ on hardware. See backlog.
// ─────────────────────────────────────────────────────────────────────────────
// When AudioService gains a PBAP integration (BlueZ AVRCP/PBAP profile on the
// real head-unit), this component will be swapped for a C++-backed model
// exposing the same `contacts`/`recents` roles and `lookupCallerName()`
// function. Until then, this fixture keeps the UI fully testable without
// hardware. All names below are fictional; all numbers use the US fictional
// `555-01XX` prefix range (NANP reserved for fiction/dramatization).
//
// Roles:
//   contacts: name (string), number (string), type ("mobile"|"home"|"work")
//   recents:  name (string), number (string), timestamp (string),
//             callType ("dialed"|"received"|"missed"), duration (string)
//
// Usage:
//   ContactsModel { id: contacts }
//   contacts.contacts        // ListModel for contact rows
//   contacts.recents         // ListModel for recent call rows
//   contacts.lookupCallerName("555-0142")  // -> "Alex Chen" or the raw number
//
import QtQuick 2.15

Item {
    id: root

    // ── Public API ───────────────────────────────────────────────────────────
    property alias contacts: contactsModel
    property alias recents:  recentsModel

    // Look up a contact name by phone number. Strips common separators so a raw
    // dial-string ("+15555550142") still matches "555-0142".
    function lookupCallerName(number) {
        if (!number || number.length === 0) return ""
        var normIn = _normalize(number)
        for (var i = 0; i < contactsModel.count; i++) {
            var c = contactsModel.get(i)
            if (_normalize(c.number) === normIn) return c.name
            // Also accept a tail-match so "+1 919 555 0142" lookups hit "555-0142"
            if (normIn.length >= 7 && _normalize(c.number).indexOf(normIn.slice(-7)) >= 0)
                return c.name
        }
        return number
    }

    function _normalize(s) {
        return String(s).replace(/[^0-9]/g, "")
    }

    // ── Contacts (15) ────────────────────────────────────────────────────────
    ListModel {
        id: contactsModel
        ListElement { name: "Alex Chen";        number: "555-0142"; type: "mobile" }
        ListElement { name: "Sarah Park";       number: "555-0118"; type: "mobile" }
        ListElement { name: "Marcus Reed";      number: "555-0167"; type: "work"   }
        ListElement { name: "Priya Patel";      number: "555-0123"; type: "mobile" }
        ListElement { name: "Jordan Blake";     number: "555-0109"; type: "home"   }
        ListElement { name: "Elena Rossi";      number: "555-0155"; type: "mobile" }
        ListElement { name: "Tomás Herrera";    number: "555-0188"; type: "work"   }
        ListElement { name: "Nadia Khan";       number: "555-0134"; type: "mobile" }
        ListElement { name: "Owen Caldwell";    number: "555-0171"; type: "home"   }
        ListElement { name: "Mira Sato";        number: "555-0196"; type: "mobile" }
        ListElement { name: "Daniel Okafor";    number: "555-0150"; type: "work"   }
        ListElement { name: "Hannah Lindgren";  number: "555-0103"; type: "mobile" }
        ListElement { name: "Rafael Mendes";    number: "555-0182"; type: "mobile" }
        ListElement { name: "Yuki Tanaka";      number: "555-0129"; type: "home"   }
        ListElement { name: "Connor Walsh";     number: "555-0164"; type: "work"   }
    }

    // ── Recent calls (12 across dialed / received / missed) ──────────────────
    ListModel {
        id: recentsModel
        // Dialed (4)
        ListElement { name: "Alex Chen";       number: "555-0142"; timestamp: "Today 2:14 PM";     callType: "dialed";   duration: "4:32"  }
        ListElement { name: "Marcus Reed";     number: "555-0167"; timestamp: "Today 10:07 AM";    callType: "dialed";   duration: "8:11"  }
        ListElement { name: "Priya Patel";     number: "555-0123"; timestamp: "Yesterday 6:44 PM"; callType: "dialed";   duration: "1:28"  }
        ListElement { name: "Mira Sato";       number: "555-0196"; timestamp: "May 11 3:22 PM";    callType: "dialed";   duration: "0:42"  }
        // Received (4)
        ListElement { name: "Sarah Park";      number: "555-0118"; timestamp: "Today 9:15 AM";     callType: "received"; duration: "3:17"  }
        ListElement { name: "Jordan Blake";    number: "555-0109"; timestamp: "Today 8:02 AM";     callType: "received"; duration: "6:50"  }
        ListElement { name: "Elena Rossi";     number: "555-0155"; timestamp: "Yesterday 7:30 PM"; callType: "received"; duration: "2:05"  }
        ListElement { name: "Daniel Okafor";   number: "555-0150"; timestamp: "May 10 9:00 AM";    callType: "received"; duration: "15:33" }
        // Missed (4)
        ListElement { name: "Nadia Khan";      number: "555-0134"; timestamp: "Today 7:44 AM";     callType: "missed";   duration: ""      }
        ListElement { name: "Tomás Herrera";   number: "555-0188"; timestamp: "Yesterday 5:20 PM"; callType: "missed";   duration: ""      }
        ListElement { name: "Unknown";         number: "555-0177"; timestamp: "May 10 8:00 PM";    callType: "missed";   duration: ""      }
        ListElement { name: "Connor Walsh";    number: "555-0164"; timestamp: "May 9 8:45 AM";     callType: "missed";   duration: ""      }
    }
}
