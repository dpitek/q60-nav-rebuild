cmake_minimum_required(VERSION 3.16)
project(q60nav VERSION 0.1.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Qt6 requires AUTOMOC for metatype generation (Q_OBJECT macros)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Cross-compile flags for Atom E6xx (Bonnell i686)
# NOTE: use -march=i686 not -march=bonnell — GCC 11 generates SIGBUS on bonnell
#       with complex C++/QML code patterns. i686 base arch is correct and safe.
if(DEFINED ENV{CROSS_COMPILE_I686})
    set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS}   -m32 -march=i686 -mtune=bonnell")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -m32 -march=i686 -mtune=bonnell")
    set(CMAKE_EXE_LINKER_FLAGS    "${CMAKE_EXE_LINKER_FLAGS} -m32")
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -m32")
endif()

# Qt6 — use i386 build when cross-compiling
if(DEFINED ENV{QT6_I386_PREFIX})
    set(CMAKE_PREFIX_PATH "$ENV{QT6_I386_PREFIX}")
endif()

find_package(Qt6 REQUIRED COMPONENTS
    Core Gui Quick QuickControls2 Network Qml Positioning
)
# DBus: optional — disabled in embedded build (FEATURE_dbus=OFF)
# AudioService BlueZ AVRCP falls back to direct socket if unavailable
find_package(Qt6 OPTIONAL_COMPONENTS DBus)

# SocketCAN — system header, no pkg-config needed on Linux
# Qt6::SerialBus provides QCanBus but we use raw SocketCAN sockets directly

find_package(PkgConfig REQUIRED)

# MapLibre GL Native — Phase 3 only.
# Requires explicit -DWITH_MAPLIBRE=ON; defaults OFF so Phase 2 builds are clean
# regardless of what's in output/maplibre-i386/.
option(WITH_MAPLIBRE "Enable MapLibre GL Native map rendering (Phase 3)" OFF)

if(WITH_MAPLIBRE AND EXISTS "${CMAKE_SOURCE_DIR}/../output/maplibre-i386/lib/libmbgl-core.a")
    set(MAPLIBRE_FOUND TRUE)
    set(MAPLIBRE_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/../output/maplibre-i386/include")
    add_library(mbgl-core STATIC IMPORTED)
    set_target_properties(mbgl-core PROPERTIES
        IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/../output/maplibre-i386/lib/libmbgl-core.a"
        # Do NOT set INTERFACE_INCLUDE_DIRECTORIES here — it cascades mbgl headers
        # to every source file, triggering the mbgl/util/optional.hpp → optional.hpp
        # missing-file chain in files that don't even use MapLibre.
        # Include path is scoped to MapLibreItem.cpp only (see below).
    )
    message(STATUS "MapLibre enabled — Phase 3 map rendering active")
else()
    message(STATUS "MapLibre not enabled — nav map will use placeholder view (pass -DWITH_MAPLIBRE=ON to enable)")
    set(MAPLIBRE_FOUND FALSE)
endif()

set(SOURCES
    src/main.cpp
    src/services/navigation/NavigationService.cpp
    src/services/vehicle/VehicleService.cpp
    src/services/audio/AudioService.cpp
    src/services/search/SearchService.cpp
    src/ui/bridge/StatusBridge.cpp
    src/ui/map/MapLibreItem.cpp
)

qt6_add_executable(q60nav ${SOURCES})
# Qt6 QML module staging creates a directory named after the target (q60nav/) in
# CMAKE_BINARY_DIR, which conflicts with the executable output. Redirect the binary
# to bin/ to avoid the collision.
set_target_properties(q60nav PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

qt6_add_qml_module(q60nav
    URI Q60Nav
    VERSION 1.0
    NO_CACHEGEN    # Skip qmlcachegen — use interpreted QML (avoids strict syntax checks)
    OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/Q60Nav"  # Avoid name collision with q60nav executable
    QML_FILES
        src/qml/Main.qml
        src/qml/screens/NavigationView.qml
        src/qml/screens/ControlHubView.qml
        src/qml/screens/ClimateView.qml
        src/qml/screens/AudioView.qml
        src/qml/screens/NavCompanionView.qml
        src/qml/screens/PhoneView.qml
        src/qml/components/TurnArrow.qml
        src/qml/components/SpeedWidget.qml
        src/qml/components/FanControl.qml
        src/qml/components/TempZone.qml
        src/qml/components/TabBar.qml
)

target_include_directories(q60nav PRIVATE
    src/
    src/services/
    src/ui/
)

target_link_libraries(q60nav PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Network
    Qt6::Qml
    Qt6::Positioning
)

# Optional: DBus (BlueZ AVRCP in AudioService) — not available in embedded build
if(Qt6DBus_FOUND)
    target_link_libraries(q60nav PRIVATE Qt6::DBus)
    target_compile_definitions(q60nav PRIVATE HAVE_QT_DBUS)
endif()

if(MAPLIBRE_FOUND)
    # Phase 3 prerequisite: mbgl/util/optional.hpp uses the mapbox-base legacy header
    # <optional.hpp>. Copy the C++17 compat shim before building:
    #   cp deps/maplibre-compat/optional.hpp output/maplibre-i386/include/optional.hpp
    #
    # Scope mbgl include path ONLY to MapLibreItem.cpp — prevents the
    # mbgl/util/optional.hpp → optional.hpp cascade from breaking all other TUs.
    set_source_files_properties(src/ui/map/MapLibreItem.cpp PROPERTIES
        COMPILE_FLAGS "-I${MAPLIBRE_INCLUDE_DIR}")
    target_link_libraries(q60nav PRIVATE mbgl-core)
    target_compile_definitions(q60nav PRIVATE MAPLIBRE_AVAILABLE)
endif()

# Strip binary for embedded target
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    add_custom_command(TARGET q60nav POST_BUILD
        COMMAND ${CMAKE_STRIP} $<TARGET_FILE:q60nav>
        COMMENT "Stripping q60nav binary"
    )
endif()

install(TARGETS q60nav
    RUNTIME DESTINATION /opt/nav/bin
)
install(DIRECTORY src/qml/ DESTINATION /opt/nav/qml)
install(FILES ../rootfs/opt/nav/start.sh
    DESTINATION /opt/nav
    PERMISSIONS OWNER_EXECUTE OWNER_READ GROUP_READ WORLD_READ
)
