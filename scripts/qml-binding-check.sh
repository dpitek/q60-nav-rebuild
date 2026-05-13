#!/bin/bash
# qml-binding-check.sh — Static QML ↔ C++ binding sanity check.
#
# For each service exposed to QML, scan every QML file for `Service.xxx`
# references and verify `xxx` is declared as a Q_PROPERTY / Q_INVOKABLE /
# signal / slot in the matching C++ header.
#
# Catches: typos, deleted properties still referenced from QML, signal
# handlers with the wrong service.
#
# Returns non-zero if any unresolved reference is found.

set -u

WORKTREE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QML_DIR="$WORKTREE_ROOT/app/src/qml"

# Parallel arrays — bash 3.x compatible (macOS default).
SERVICES=(
  SettingsService
  VehicleService
  NavigationService
  AudioService
  ProfileService
  NetworkService
  WeatherService
  FuelService
  TripLoggerService
  ParkingService
  StatusBridge
  SearchService
)
HEADERS=(
  "$WORKTREE_ROOT/app/src/services/settings/SettingsService.h"
  "$WORKTREE_ROOT/app/src/services/vehicle/VehicleService.h"
  "$WORKTREE_ROOT/app/src/services/navigation/NavigationService.h"
  "$WORKTREE_ROOT/app/src/services/audio/AudioService.h"
  "$WORKTREE_ROOT/app/src/services/profile/ProfileService.h"
  "$WORKTREE_ROOT/app/src/services/network/NetworkService.h"
  "$WORKTREE_ROOT/app/src/services/weather/WeatherService.h"
  "$WORKTREE_ROOT/app/src/services/fuel/FuelService.h"
  "$WORKTREE_ROOT/app/src/services/trip/TripLoggerService.h"
  "$WORKTREE_ROOT/app/src/services/parking/ParkingService.h"
  "$WORKTREE_ROOT/app/src/ui/bridge/StatusBridge.h"
  "$WORKTREE_ROOT/app/src/services/search/SearchService.h"
)

FAIL=0
TOTAL_CHECKED=0

# Allowed identifiers from a C++ header: Q_PROPERTY name, Q_INVOKABLE method
# names, names listed under `signals:` and `public slots:`, plus standard
# `bool name() const { ... }` getter shortcuts. Intentionally permissive —
# false negatives are worse than false positives.
collect_allowed() {
    local header="$1"
    {
        # Q_PROPERTY( type name READ ... )  — 2nd identifier is the property name
        grep -E "Q_PROPERTY\(" "$header" \
          | sed -E 's/.*Q_PROPERTY\([[:space:]]*[A-Za-z0-9_<>:]+[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*$/\1/' \
          | grep -E '^[A-Za-z_][A-Za-z0-9_]*$'
        # Q_INVOKABLE return-type foo( ... )
        grep -E "Q_INVOKABLE" "$header" \
          | sed -E 's/.*Q_INVOKABLE[[:space:]]+[A-Za-z0-9_<>:&*]+[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*$/\1/' \
          | grep -E '^[A-Za-z_][A-Za-z0-9_]*$'
        # signals: blocks — any `void name(`
        awk '/signals:/{flag=1;next} /private:|public:|protected:|^\};/{flag=0} flag' "$header" \
          | sed -E 's/.*void[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*$/\1/' \
          | grep -E '^[A-Za-z_][A-Za-z0-9_]*$'
        # public slots:
        awk '/public slots:/{flag=1;next} /private:|signals:|protected:|^\};/{flag=0} flag' "$header" \
          | sed -E 's/.*void[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*$/\1/' \
          | grep -E '^[A-Za-z_][A-Za-z0-9_]*$'
        # Plain getter signatures: `bool name() const`, `QString name() const`, etc.
        grep -E "^[[:space:]]*(bool|int|double|float|qint64|QString|QGeoCoordinate|QVariantList|QVariantMap|QStringList)[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]+const" "$header" \
          | sed -E 's/.*[[:space:]]([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]+const.*$/\1/'
    } | sort -u
}

# Tokens to never warn about (Qt built-in QObject properties, accessor methods
# that aren't declared in our headers, etc.)
SKIP_TOKENS="objectName destroyed deleteLater parent children metaObject"

# Identifiers off NavigationService.position are QGeoCoordinate properties /
# methods — we don't try to validate that chain (would need to know the type).
# Just skip when the parent is a known compound property.
SKIP_COMPOUND_PARENTS="position"

for i in "${!SERVICES[@]}"; do
    SVC="${SERVICES[$i]}"
    HEADER="${HEADERS[$i]}"
    if [ ! -f "$HEADER" ]; then
        echo "  ! $SVC header missing at $HEADER — skipping"
        continue
    fi
    ALLOWED=$(collect_allowed "$HEADER")

    # Find every Service.token reference in QML
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        FILE=$(echo "$line" | cut -d: -f1)
        LINENO=$(echo "$line" | cut -d: -f2)

        # Could be multiple `Svc.X` on a line; iterate them all
        echo "$line" | grep -oE "${SVC}\.[a-zA-Z_][a-zA-Z0-9_]*" \
          | sort -u | while read -r match; do
            TOKEN="${match#${SVC}.}"
            [ -z "$TOKEN" ] && continue

            # skip known stop-words
            case " $SKIP_TOKENS " in
                *" $TOKEN "*) continue ;;
            esac
            case " $SKIP_COMPOUND_PARENTS " in
                *" $TOKEN "*) continue ;;
            esac

            if echo "$ALLOWED" | grep -qx "$TOKEN"; then
                :  # OK
            else
                # Sanity: maybe it's a property access on Service.compound.X form.
                # If the prefix is in SKIP_COMPOUND_PARENTS we already skipped.
                echo "BAD::$FILE:$LINENO::$SVC.$TOKEN"
            fi
        done
    done < <(grep -RnE "\\b${SVC}\\.[a-zA-Z_][a-zA-Z0-9_]*" "$QML_DIR" 2>/dev/null \
              | grep -v 'typeof ' \
              | grep -v '^Binary')
done | sort -u | while read -r row; do
    [ -z "$row" ] && continue
    case "$row" in
        BAD::*) echo "  ✗ ${row#BAD::}"; echo BAD >> /tmp/qml-binding-fail ;;
    esac
done

# Reconcile fail counter (we wrote tags to a tmpfile because the while-loop
# above runs in a subshell and can't update FAIL directly).
if [ -f /tmp/qml-binding-fail ]; then
    FAIL=$(wc -l < /tmp/qml-binding-fail | tr -d ' ')
    rm -f /tmp/qml-binding-fail
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "qml-binding-check: $FAIL unresolved reference(s) — fix before flashing"
    exit 1
fi
echo "qml-binding-check: all QML → C++ references resolve"
exit 0
