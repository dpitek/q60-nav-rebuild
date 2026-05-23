cmake_minimum_required(VERSION 3.16)
project(q60nav VERSION 0.1.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

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

# Plan B''' uses Qt 6 (already built at output/qt6-i386). Qt 5.15 was the old
# Plan B and won't work — its build excluded EGL/GL (deps/build-qt515-i386.sh
# has -no-opengl -no-egl). The May-16 Qt5 port commit (1ae703a) is reverted
# below.
if(DEFINED ENV{QT6_I386_PREFIX})
    set(CMAKE_PREFIX_PATH "$ENV{QT6_I386_PREFIX}" ${CMAKE_PREFIX_PATH})
endif()

find_package(Qt6 6.6 REQUIRED COMPONENTS
    Core Gui Quick QuickControls2 Network Qml Positioning
)
find_package(Qt6 6.6 OPTIONAL_COMPONENTS DBus)

find_package(PkgConfig REQUIRED)

# MapLibre GL Native — Phase 3 only.
option(WITH_MAPLIBRE "Enable MapLibre GL Native map rendering (Phase 3)" OFF)

if(WITH_MAPLIBRE AND EXISTS "${CMAKE_SOURCE_DIR}/../output/maplibre-i386/lib/libmbgl-core.a")
    set(MAPLIBRE_FOUND TRUE)
    set(MAPLIBRE_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/../output/maplibre-i386/include")
    set(MAPLIBRE_LIB_DIR     "${CMAKE_SOURCE_DIR}/../output/maplibre-i386/lib")
    set(SYSROOT_LIB_DIR      "${CMAKE_SOURCE_DIR}/../deps/sysroot-i386/lib")

    set(MAPLIBRE_VENDOR_BASE "${CMAKE_SOURCE_DIR}/../deps/maplibre-gl-native/vendor/mapbox-base")
    set(MAPLIBRE_VENDOR_INCLUDES
        "${MAPLIBRE_VENDOR_BASE}/include"
        "${MAPLIBRE_VENDOR_BASE}/deps/geometry.hpp/include"
        "${MAPLIBRE_VENDOR_BASE}/deps/variant/include"
        "${MAPLIBRE_VENDOR_BASE}/deps/geojson.hpp/include"
        "${MAPLIBRE_VENDOR_BASE}/deps/cheap-ruler-cpp/include"
    )

    add_library(mbgl-core STATIC IMPORTED)
    set_target_properties(mbgl-core PROPERTIES
        IMPORTED_LOCATION "${MAPLIBRE_LIB_DIR}/libmbgl-core.a")

    foreach(_vlib csscolorparser nunicode parsedate sqlite)
        add_library(mbgl-vendor-${_vlib} STATIC IMPORTED)
        set_target_properties(mbgl-vendor-${_vlib} PROPERTIES
            IMPORTED_LOCATION "${MAPLIBRE_LIB_DIR}/libmbgl-vendor-${_vlib}.a")
    endforeach()

    add_library(sysroot-curl   STATIC IMPORTED)
    set_target_properties(sysroot-curl   PROPERTIES IMPORTED_LOCATION "${SYSROOT_LIB_DIR}/libcurl.a")
    add_library(sysroot-sqlite STATIC IMPORTED)
    set_target_properties(sysroot-sqlite PROPERTIES IMPORTED_LOCATION "${SYSROOT_LIB_DIR}/libsqlite3.a")
    add_library(sysroot-z      STATIC IMPORTED)
    set_target_properties(sysroot-z      PROPERTIES IMPORTED_LOCATION "${SYSROOT_LIB_DIR}/libz.a")

    message(STATUS "MapLibre enabled — Phase 3 map rendering active")
else()
    message(STATUS "MapLibre not enabled — nav map will use placeholder view (pass -DWITH_MAPLIBRE=ON to enable)")
    set(MAPLIBRE_FOUND FALSE)
endif()

# QML resources — Qt 6 path. Use qt_add_qml_module if available; otherwise fall
# back to a hand-built qml.qrc (this is also what the Qt 5.15 port did, and it
# still works in Qt 6 — Qt 6 is a strict superset for QRC handling).
file(WRITE ${CMAKE_BINARY_DIR}/qml.qrc "<RCC><qresource prefix=\"/Q60Nav\">\n")
file(GLOB_RECURSE _qml_files RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} src/qml/*.qml)
foreach(_q ${_qml_files})
    file(APPEND ${CMAKE_BINARY_DIR}/qml.qrc
         "<file alias=\"${_q}\">${CMAKE_CURRENT_SOURCE_DIR}/${_q}</file>\n")
endforeach()
file(APPEND ${CMAKE_BINARY_DIR}/qml.qrc "</qresource></RCC>\n")

set(SOURCES
    src/main.cpp
    src/services/navigation/NavigationService.cpp
    src/services/vehicle/VehicleService.cpp
    src/services/vehicle/ButtonLogger.cpp
    src/services/audio/AudioService.cpp
    src/services/search/SearchService.cpp
    src/services/profile/ProfileService.cpp
    src/services/network/NetworkService.cpp
    src/services/weather/WeatherService.cpp
    src/services/fuel/FuelService.cpp
    src/services/settings/SettingsService.cpp
    src/services/trip/TripLoggerService.cpp
    src/services/parking/ParkingService.cpp
    src/ui/bridge/StatusBridge.cpp
    src/ui/map/MapLibreItem.cpp
    ${CMAKE_BINARY_DIR}/qml.qrc
)

add_executable(q60nav ${SOURCES})

target_include_directories(q60nav PRIVATE
    src/
    src/services/
    src/services/profile/
    src/services/vehicle/
    src/services/trip/
    src/services/parking/
    src/ui/
    src/ui/map/
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

if(Qt6DBus_FOUND)
    target_link_libraries(q60nav PRIVATE Qt6::DBus)
    target_compile_definitions(q60nav PRIVATE HAVE_QT_DBUS)
endif()

if(MAPLIBRE_FOUND)
    target_include_directories(q60nav PRIVATE "${MAPLIBRE_INCLUDE_DIR}" ${MAPLIBRE_VENDOR_INCLUDES})
    target_link_libraries(q60nav PRIVATE
        mbgl-core
        mbgl-vendor-csscolorparser
        mbgl-vendor-nunicode
        mbgl-vendor-parsedate
        mbgl-vendor-sqlite
        sysroot-curl
        sysroot-z
        png
        jpeg
        uv
        icuuc icudata icui18n
    )
    target_compile_definitions(q60nav PRIVATE MAPLIBRE_AVAILABLE)
endif()

if(CMAKE_BUILD_TYPE STREQUAL "Release")
    add_custom_command(TARGET q60nav POST_BUILD
        COMMAND ${CMAKE_STRIP} $<TARGET_FILE:q60nav>
        COMMENT "Stripping q60nav binary"
    )
endif()

# ─────────────────────────────────────────────────────────────────────────────
# Plan B''' eglfs device-integration plugin — the surgical wrap that lets
# Qt's eglfs paint into an EMGD HMI pixmap visible on LVDS upper.
# ─────────────────────────────────────────────────────────────────────────────
add_subdirectory(src/eglfs_emgdhmi)

install(TARGETS q60nav
    RUNTIME DESTINATION /opt/q60qt
)
install(FILES ../app/src/planb_qt/run-q60qt.sh
    DESTINATION /opt/q60qt
    PERMISSIONS OWNER_EXECUTE OWNER_READ OWNER_WRITE
                GROUP_EXECUTE GROUP_READ
                WORLD_EXECUTE WORLD_READ
)
