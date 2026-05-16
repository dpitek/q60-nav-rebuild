#!/bin/bash
# Mechanical Qt 6 → Qt 5.15 QML port.
# Idempotent: re-running on already-ported tree is a no-op.
#
# Scope (per /tmp/q60-overnight/plan-b-qt515-pivot.md §2):
#   - 44 versionless QML imports → versioned forms
#   - QtMultimedia 6.6 → QtMultimedia 5.15 in CameraFeed.qml
#   - VideoOutput player: → source: in CameraFeed.qml
#   - MediaPlayer onErrorOccurred → onError in CameraFeed.qml
#
# Out of scope (C++ edits done by hand):
#   - QML_NAMED_ELEMENT → qmlRegisterType (MapLibreItem.h, main.cpp)
#   - geometryChange → geometryChanged (MapLibreItem.h, .cpp)
#   - QStringConverter::Utf8 → setCodec("UTF-8") (ButtonLogger.cpp:40)
#   - CMakeLists.txt: qt6_add_qml_module → qrc-based
#   - find_package(Qt6) → find_package(Qt5)

set -e

QML_DIR="${1:-app/src/qml}"
if [ ! -d "$QML_DIR" ]; then
    echo "ERROR: QML dir not found: $QML_DIR"
    echo "Usage: $0 [path/to/qml]"
    exit 1
fi

echo "=== Qt 6 → Qt 5.15 QML port ==="
echo "Target: $QML_DIR"

# Versioned imports (sed is POSIX; works on macOS BSD sed and GNU sed).
# Using -i'' '' for cross-platform safety: the '' arg is the in-place backup extension.
SED_INPLACE=(-i '')
if [ "$(uname)" = "Linux" ]; then
    SED_INPLACE=(-i)
fi

find "$QML_DIR" -name "*.qml" -print0 | xargs -0 sed "${SED_INPLACE[@]}" \
    -e 's|^import QtQuick$|import QtQuick 2.15|' \
    -e 's|^import QtQuick\.Controls$|import QtQuick.Controls 2.15|' \
    -e 's|^import QtQuick\.Window$|import QtQuick.Window 2.15|' \
    -e 's|^import QtQuick\.Layouts$|import QtQuick.Layouts 1.15|' \
    -e 's|^import QtQuick\.Shapes$|import QtQuick.Shapes 1.15|' \
    -e 's|^import QtPositioning$|import QtPositioning 5.15|' \
    -e 's|^import Qt\.labs\.platform$|import Qt.labs.platform 1.1|' \
    -e 's|^import QtMultimedia 6\.6$|import QtMultimedia 5.15|' \
    -e 's|^import QtMultimedia 6\.[0-9]\+$|import QtMultimedia 5.15|'

# CameraFeed.qml specifics — only run if the file exists.
CAMERA="$QML_DIR/components/CameraFeed.qml"
if [ -f "$CAMERA" ]; then
    echo "--- CameraFeed.qml: MediaPlayer/VideoOutput Qt 6 → Qt 5.15 ---"
    sed "${SED_INPLACE[@]}" \
        -e 's|onErrorOccurred:|onError:|g' \
        -e 's|^\(\s*\)player: player$|\1source: player|' \
        "$CAMERA"
fi

echo "--- Verifying versionless imports remain (should be zero) ---"
REMAINING=$(grep -rE '^import (QtQuick|QtQuick\.Controls|QtQuick\.Window|QtPositioning|QtMultimedia 6)' "$QML_DIR" 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
    echo "WARNING: still found versionless / Qt 6-only imports:"
    echo "$REMAINING"
    exit 1
fi

echo "=== Port complete ==="
