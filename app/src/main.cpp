// Q60 Nav Rebuild — Main Entry Point
// Dual-screen Qt 6 application for Clarion QY5092 DCU
// Upper screen (8"): Navigation | Lower screen (7"): Control Hub

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QScreen>
#include <QDebug>
#include <QLoggingCategory>

#include "services/navigation/NavigationService.h"
#include "services/vehicle/VehicleService.h"
#include "services/audio/AudioService.h"
#include "services/search/SearchService.h"
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

    // Register MapLibre QML type (no-op if MAPLIBRE_AVAILABLE not defined)
    qmlRegisterType<MapLibreItem>("Q60Nav.Map", 1, 0, "MapLibreMap");

    // ── Services ──────────────────────────────────────────────────────────
    VehicleService  vehicleSvc;   // SocketCAN: Vehicle CAN + CAN2
    AudioService    audioSvc;     // ALSA + Bose CAN + SXM/FM proxies
    NavigationService navSvc;     // Valhalla + MapLibre
    SearchService   searchSvc;    // Pelias/Nominatim offline

    // StatusBridge — shared state between both screens
    StatusBridge bridge(&navSvc, &vehicleSvc, &audioSvc);

    // ── QML Engine ────────────────────────────────────────────────────────
    QQmlApplicationEngine engine;

    // Expose services to QML
    engine.rootContext()->setContextProperty("NavigationService", &navSvc);
    engine.rootContext()->setContextProperty("VehicleService",    &vehicleSvc);
    engine.rootContext()->setContextProperty("AudioService",      &audioSvc);
    engine.rootContext()->setContextProperty("SearchService",     &searchSvc);
    engine.rootContext()->setContextProperty("StatusBridge",      &bridge);

    engine.load(QUrl(QStringLiteral("qrc:/Q60Nav/src/qml/Main.qml")));

    if (engine.rootObjects().isEmpty()) {
        qCCritical(lcMain) << "Failed to load QML root";
        return -1;
    }

    // ── Dual-screen window assignment ──────────────────────────────────────
    QList<QScreen*> screens = QGuiApplication::screens();
    qCInfo(lcMain) << "Detected screens:" << screens.size();

    auto rootObjects = engine.rootObjects();
    if (screens.size() >= 2 && rootObjects.size() >= 2) {
        // Upper 8" = screen 0 → NavigationView
        if (auto *win = qobject_cast<QQuickWindow*>(rootObjects[0])) {
            win->setScreen(screens[0]);
            win->setGeometry(screens[0]->geometry());
            win->showFullScreen();
            qCInfo(lcMain) << "Upper screen: NavigationView on" << screens[0]->name();
        }
        // Lower 7" = screen 1 → ControlHubView
        if (auto *win = qobject_cast<QQuickWindow*>(rootObjects[1])) {
            win->setScreen(screens[1]);
            win->setGeometry(screens[1]->geometry());
            win->showFullScreen();
            qCInfo(lcMain) << "Lower screen: ControlHubView on" << screens[1]->name();
        }
    } else {
        // Single screen dev mode — stack both views
        qCWarning(lcMain) << "Single screen detected — dev layout mode";
        for (auto *obj : rootObjects) {
            if (auto *win = qobject_cast<QQuickWindow*>(obj))
                win->show();
        }
    }

    // Start services
    vehicleSvc.start();
    audioSvc.start();
    navSvc.start();

    return app.exec();
}
