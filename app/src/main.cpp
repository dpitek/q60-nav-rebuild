// Q60 Nav Rebuild — Main Entry Point
// Dual-screen Qt 6 application for Clarion QY5092 DCU
// Upper screen (8"): Navigation | Lower screen (7"): Control Hub

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QScreen>
#include <QDebug>
#include <QLoggingCategory>
#include <algorithm>

#include "services/navigation/NavigationService.h"
#include "services/vehicle/VehicleService.h"
#include "services/audio/AudioService.h"
#include "services/search/SearchService.h"
#include "services/profile/ProfileService.h"
#include "ui/bridge/StatusBridge.h"
#include "ui/map/MapLibreItem.h"

Q_LOGGING_CATEGORY(lcMain, "q60nav.main")

int main(int argc, char *argv[])
{
    // Wayland backend for dual LVDS output
    qputenv("QT_QPA_PLATFORM", "wayland");
    qputenv("QT_QUICK_BACKEND", "software"); // Mesa swrast — no PowerVR driver
    qputenv("QSG_RENDER_LOOP", "basic");     // Single-threaded render on Atom

    QGuiApplication app(argc, argv);
    app.setApplicationName("Q60 Nav");
    app.setApplicationVersion("0.1.0");
    app.setOrganizationName("Q60Rebuild");

    // MapLibreItem is registered as "MapLibreMap" in the "Q60Nav" QML module via
    // QML_ELEMENT + qt6_add_qml_module (CMakeLists.txt). No manual qmlRegisterType
    // needed — the auto-registration covers both WITH_MAPLIBRE=ON and OFF builds
    // (stub rendering when MAPLIBRE_AVAILABLE is not defined).

    // ── Services ──────────────────────────────────────────────────────────
    VehicleService  vehicleSvc;   // SocketCAN: Vehicle CAN + CAN2
    AudioService    audioSvc;     // ALSA + Bose CAN + SXM/FM proxies
    NavigationService navSvc;     // Valhalla + MapLibre
    SearchService   searchSvc;    // Pelias/Nominatim offline
    ProfileService  profileSvc;   // Driver profiles — CAN key detect + JSON persistence

    // StatusBridge — shared state between both screens
    StatusBridge bridge(&navSvc, &vehicleSvc, &audioSvc);

    // ── QML Engine ────────────────────────────────────────────────────────
    QQmlApplicationEngine engine;

    // Expose services to QML
    engine.rootContext()->setContextProperty("NavigationService", &navSvc);
    engine.rootContext()->setContextProperty("VehicleService",    &vehicleSvc);
    engine.rootContext()->setContextProperty("AudioService",      &audioSvc);
    engine.rootContext()->setContextProperty("SearchService",     &searchSvc);
    engine.rootContext()->setContextProperty("ProfileService",    &profileSvc);
    engine.rootContext()->setContextProperty("StatusBridge",      &bridge);

    engine.load(QUrl(QStringLiteral("qrc:/Q60Nav/src/qml/Main.qml")));

    // ── Dual-screen window assignment ──────────────────────────────────────
    // Main.qml uses QtObject root (required by qmlcachegen — one root per file).
    // The two Window items are declared as properties and found via findChildren.
    QList<QScreen*> screens = QGuiApplication::screens();
    qCInfo(lcMain) << "Detected screens:" << screens.size();

    auto rootObjects = engine.rootObjects();
    if (rootObjects.isEmpty()) {
        qCCritical(lcMain) << "No root QML objects — engine load failed";
        return -1;
    }

    // Collect all QQuickWindow children from the QtObject root
    QList<QQuickWindow*> windows = rootObjects[0]->findChildren<QQuickWindow*>();
    qCInfo(lcMain) << "Found" << windows.size() << "windows";

    // Sort by objectName: upperScreen first, lowerScreen second
    std::sort(windows.begin(), windows.end(), [](QQuickWindow *a, QQuickWindow *b) {
        return a->objectName() < b->objectName();  // "lowerScreen" < "upperScreen" alphabetically
    });
    // Reverse so upperScreen (index 1 alpha) is first
    if (windows.size() >= 2)
        std::reverse(windows.begin(), windows.end());

    if (screens.size() >= 2 && windows.size() >= 2) {
        // Upper 8" = screen 0 → NavigationView (objectName: "upperScreen")
        windows[0]->setScreen(screens[0]);
        windows[0]->setGeometry(screens[0]->geometry());
        windows[0]->showFullScreen();
        qCInfo(lcMain) << "Upper screen:" << windows[0]->objectName() << "on" << screens[0]->name();

        // Lower 7" = screen 1 → ControlHubView (objectName: "lowerScreen")
        windows[1]->setScreen(screens[1]);
        windows[1]->setGeometry(screens[1]->geometry());
        windows[1]->showFullScreen();
        qCInfo(lcMain) << "Lower screen:" << windows[1]->objectName() << "on" << screens[1]->name();
    } else {
        // Single screen dev mode — show all windows
        qCWarning(lcMain) << "Single screen detected — dev layout mode";
        for (auto *win : windows)
            win->show();
    }

    // Start services
    vehicleSvc.start();
    audioSvc.start();
    navSvc.start();
    profileSvc.start(&vehicleSvc);  // subscribes to keySlotDetected + ignitionOff

    return app.exec();
}
