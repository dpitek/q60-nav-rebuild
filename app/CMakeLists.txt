cmake_minimum_required(VERSION 3.16)
project(q60nav VERSION 0.1.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Cross-compile flags for Atom E6xx (Bonnell i686)
if(DEFINED ENV{CROSS_COMPILE_I686})
    set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS}   -m32 -march=bonnell -mtune=bonnell")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -m32 -march=bonnell -mtune=bonnell")
    set(CMAKE_EXE_LINKER_FLAGS    "${CMAKE_EXE_LINKER_FLAGS} -m32")
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -m32")
endif()

# Qt6 — use i386 build when cross-compiling
if(DEFINED ENV{QT6_I386_PREFIX})
    set(CMAKE_PREFIX_PATH "$ENV{QT6_I386_PREFIX}")
endif()

find_package(Qt6 REQUIRED COMPONENTS
    Core Gui Quick QuickControls2 Network Positioning Qml DBus
)

# SocketCAN — system header, no pkg-config needed on Linux
# Qt6::SerialBus provides QCanBus but we use raw SocketCAN sockets directly

find_package(PkgConfig REQUIRED)

# MapLibre GL Native (available after Phase 2 build completes)
if(EXISTS "${CMAKE_SOURCE_DIR}/../output/maplibre-i386/lib/libmbgl-core.a")
    set(MAPLIBRE_FOUND TRUE)
    add_library(mbgl-core STATIC IMPORTED)
    set_target_properties(mbgl-core PROPERTIES
        IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/../output/maplibre-i386/lib/libmbgl-core.a"
        INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/../output/maplibre-i386/include"
    )
else()
    message(STATUS "MapLibre not yet built — nav map will use placeholder view")
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

qt6_add_qml_module(q60nav
    URI Q60Nav
    VERSION 1.0
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
    Qt6::Positioning
    Qt6::Qml
    Qt6::DBus
)

if(MAPLIBRE_FOUND)
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
