# EGLFS device-integration plugin for the EMGD HMI pixmap contract.
# Output: libqeglfs-emgdhmi-integration.so — installed into the Qt prefix's
# plugins/egldeviceintegrations/ dir so Qt's eglfs platform plugin can
# auto-discover it via QT_QPA_EGLFS_INTEGRATION=eglfs_emgdhmi.

# Need Qt6's EglFSDeviceIntegrationPrivate cmake module — it ships private
# headers + the Q_EGLFS_EXPORT symbol the base class uses.
find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui)
find_package(Qt6 6.6 REQUIRED COMPONENTS EglFSDeviceIntegrationPrivate)

# Plugin sources. Keep qeglfsemgdhmi_main.cpp tiny — it exists only to
# guarantee the plugin entry symbol is emitted in a non-AUTOMOC TU even
# if a future refactor moves things around.
set(PLUGIN_SOURCES
    qeglfsemgdhmi.cpp
    qeglfsemgdhmi.h
)

# Qt6 plugin add. The plugin "TYPE" tells Qt's deployment tooling where to
# put it — egldeviceintegrations/ — so QT_QPA_EGLFS_INTEGRATION can find it.
qt_add_plugin(qeglfs-emgdhmi-integration
    SHARED
    CLASS_NAME QEglFSEmgdHmiIntegrationPlugin
    ${PLUGIN_SOURCES}
)

# Use the Qt6 PRIVATE module — gives access to the base class header
# (qeglfsdeviceintegration_p.h).
target_link_libraries(qeglfs-emgdhmi-integration PRIVATE
    Qt6::CorePrivate
    Qt6::GuiPrivate
    Qt6::EglFSDeviceIntegrationPrivate
    dl
)

# The plugin needs to know its JSON metadata file is in the source dir
# (Q_PLUGIN_METADATA's FILE keyword resolves relative to the cpp containing
# Q_PLUGIN_METADATA).
target_include_directories(qeglfs-emgdhmi-integration PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# Install into Qt's plugin dir so Qt's eglfs can dlopen it. On the deploy
# target (eMMC Slot A) this lands at <qt-runtime-prefix>/plugins/egldeviceintegrations/.
install(TARGETS qeglfs-emgdhmi-integration
    LIBRARY DESTINATION /opt/q60qt/plugins/egldeviceintegrations
)
