// Q60 Nav Rebuild — Main Entry Point
// Dual-screen Qt 6 application for Clarion QY5092 DCU
// Upper screen (8"): Navigation | Lower screen (7"): Control Hub

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QtQml>
#include <QScreen>
#include <QDebug>
#include <QLoggingCategory>
#include <QTimer>
#include <QFile>
#include <algorithm>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/watchdog.h>

#include "services/navigation/NavigationService.h"
#include "services/vehicle/VehicleService.h"
#include "services/audio/AudioService.h"
#include "services/search/SearchService.h"
#include "services/profile/ProfileService.h"
#include "services/network/NetworkService.h"
#include "services/weather/WeatherService.h"
#include "services/fuel/FuelService.h"
#include "services/settings/SettingsService.h"
#include "services/trip/TripLoggerService.h"
#include "services/parking/ParkingService.h"
#include "ui/bridge/StatusBridge.h"
#include "ui/map/MapLibreItem.h"

Q_LOGGING_CATEGORY(lcMain, "q60nav.main")

int main(int argc, char *argv[])
{
    // Platform defaults — only set if not already provided by the environment.
    // The simulator overrides QT_QPA_PLATFORM=vnc; start.sh sets wayland.
    // qputenv is unconditional, so we guard with qgetenv first.
    if (qgetenv("QT_QPA_PLATFORM").isEmpty())
        qputenv("QT_QPA_PLATFORM", "wayland");           // Wayland for dual LVDS on DCU
    if (qgetenv("QT_QUICK_BACKEND").isEmpty())
        qputenv("QT_QUICK_BACKEND", "software");         // Mesa swrast — no PowerVR driver
    if (qgetenv("QSG_RENDER_LOOP").isEmpty())
        qputenv("QSG_RENDER_LOOP", "basic");             // Single-threaded render on Atom
    if (qgetenv("QT_QUICK_CONTROLS_STYLE").isEmpty())
        qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");     // Embedded build: only Basic style present

    QGuiApplication app(argc, argv);
    app.setApplicationName("Q60 Nav");
    app.setApplicationVersion("0.1.0");
    app.setOrganizationName("Q60Rebuild");

    // Qt 5.15: register MapLibreItem as Q60Nav.MapLibreMap explicitly.
    // (Qt 6 used QML_NAMED_ELEMENT + qt6_add_qml_module; Qt 5.15 needs the call.)
    qmlRegisterType<MapLibreItem>("Q60Nav", 1, 0, "MapLibreMap");

    // ── Services ──────────────────────────────────────────────────────────
    VehicleService  vehicleSvc;   // SocketCAN: Vehicle CAN + CAN2
    AudioService    audioSvc;     // ALSA + Bose CAN + SXM/FM proxies
    NavigationService navSvc;     // Valhalla + MapLibre
    SearchService   searchSvc;    // Pelias/Nominatim offline
    ProfileService  profileSvc;   // Driver profiles — CAN key detect + JSON persistence
    NetworkService  networkSvc;   // LTE modem — sysfs + mmcli polling
    WeatherService  weatherSvc;   // OpenWeatherMap current + 5-day forecast
    FuelService     fuelSvc;      // EIA weekly regional gas prices
    SettingsService settingsSvc;  // System + vehicle preference persistence
    TripLoggerService tripSvc;    // Per-ignition GPX traces + trip computer A/B
    ParkingService    parkingSvc; // "Where did I park?" — saved on ignition-off

    // StatusBridge — shared state between both screens
    StatusBridge bridge(&navSvc, &vehicleSvc, &audioSvc, &networkSvc, &parkingSvc);

    // ── QML Engine ────────────────────────────────────────────────────────
    QQmlApplicationEngine engine;

    // Expose services to QML
    engine.rootContext()->setContextProperty("NavigationService", &navSvc);
    engine.rootContext()->setContextProperty("VehicleService",    &vehicleSvc);
    engine.rootContext()->setContextProperty("AudioService",      &audioSvc);
    engine.rootContext()->setContextProperty("SearchService",     &searchSvc);
    engine.rootContext()->setContextProperty("ProfileService",    &profileSvc);
    engine.rootContext()->setContextProperty("NetworkService",    &networkSvc);
    engine.rootContext()->setContextProperty("WeatherService",    &weatherSvc);
    engine.rootContext()->setContextProperty("FuelService",       &fuelSvc);
    engine.rootContext()->setContextProperty("SettingsService",   &settingsSvc);
    engine.rootContext()->setContextProperty("TripLoggerService", &tripSvc);
    engine.rootContext()->setContextProperty("ParkingService",    &parkingSvc);
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
        // Single screen (simulator / dev) — show all windows.
        // In Q60_SIM mode, position them side-by-side on the VNC virtual screen:
        //   upper (800×480) at (0, 0), lower (800×420) at (860, 30)
        qCWarning(lcMain) << "Single screen — dev/simulator layout";
        const bool simMode = !qgetenv("Q60_SIM").isEmpty();
        for (int i = 0; i < windows.size(); ++i) {
            if (simMode && windows.size() >= 2) {
                // windows[0] = upperScreen, windows[1] = lowerScreen (after sort+reverse)
                windows[i]->setX(i == 0 ? 0   : 860);
                windows[i]->setY(i == 0 ? 0   : 30);   // 30px = (480-420)/2 vertical centre
            }
            windows[i]->show();
        }
    }

    // Start services
    vehicleSvc.setSettingsService(&settingsSvc);  // BCM-unlock comfort feature gates
    vehicleSvc.start();
    audioSvc.start();
    navSvc.start();
    profileSvc.start(&vehicleSvc);  // subscribes to keySlotDetected + ignitionOff
    networkSvc.start();             // LTE polling — non-blocking sysfs + mmcli
    weatherSvc.start();             // OWM fetch; graceful no-op without API key
    fuelSvc.start();                // EIA fetch; hardcoded fallback if no API key
    settingsSvc.start(&profileSvc); // JSON persistence + profile-linked overlay
    tripSvc.start(&vehicleSvc, &navSvc);    // GPX traces + trip A/B accumulators
    parkingSvc.start(&vehicleSvc, &navSvc); // Save GPS on ignition-off

    // AudioService depends on Settings (preset persistence) and Vehicle (SSV speed).
    // Wire AFTER settingsSvc.start() so audioPresets blob is already loaded.
    audioSvc.wireDependencies(&settingsSvc, &vehicleSvc);

    // ── Simulator-mode initial location ──────────────────────────────────
    // In Q60_SIM mode the launcher resolves the host's IP-based location
    // (or accepts --lat/--lon overrides) and exports Q60_SIM_LAT/LON. We
    // seed NavigationService's position so the upper-screen map opens
    // centered where the user actually is, not on central NC.
    // On real DCU hardware these env vars are unset and GPSD takes over.
    if (!qgetenv("Q60_SIM").isEmpty()) {
        bool latOk = false, lonOk = false;
        const double simLat = QString::fromLocal8Bit(qgetenv("Q60_SIM_LAT")).toDouble(&latOk);
        const double simLon = QString::fromLocal8Bit(qgetenv("Q60_SIM_LON")).toDouble(&lonOk);
        if (latOk && lonOk && simLat != 0.0 && simLon != 0.0) {
            navSvc.setSimulatorPosition(simLat, simLon);
            const QByteArray city = qgetenv("Q60_SIM_CITY");
            qCInfo(lcMain) << "Simulator initial location:" << simLat << simLon
                           << (city.isEmpty() ? "" : QString("(%1)").arg(QString::fromLocal8Bit(city)).toLocal8Bit().constData());
        }
    }

    // ── Network availability fan-out ─────────────────────────────────────
    // Without these wires, Weather/Fuel never fire even when the user later
    // tethers a phone — both stay in their offline-default state forever.
    QObject::connect(&networkSvc, &NetworkService::onlineChanged,
                     &weatherSvc, &WeatherService::setNetworkOnline);
    QObject::connect(&networkSvc, &NetworkService::onlineChanged,
                     &fuelSvc,    &FuelService::setNetworkOnline);

    // ── Hardware watchdog (iTCO/ie6xx_wdt) ──────────────────────────────
    // Open /dev/watchdog and feed it on a 5s QTimer. Kernel default timeout
    // is configured at module load (typically 30s); we feed every 5s so we
    // have plenty of slack for transient hiccups (long GC pause, tile load).
    // If the device isn't available (bench / simulator), the open returns
    // -1 and we skip — the system runs without watchdog protection.
    const int wdFd = ::open("/dev/watchdog", O_WRONLY | O_CLOEXEC);
    if (wdFd >= 0) {
        // Try to set a 30s timeout (some platforms refuse — that's fine).
        int timeout = 30;
        ::ioctl(wdFd, WDIOC_SETTIMEOUT, &timeout);
        qCInfo(lcMain) << "Watchdog armed, timeout=" << timeout << "s, fd=" << wdFd;

        QTimer *wdTimer = new QTimer(&app);
        wdTimer->setInterval(5000);
        QObject::connect(wdTimer, &QTimer::timeout, [wdFd]() {
            // KEEPALIVE ioctl is the canonical "feed" — works on every Linux
            // watchdog driver. Writing any byte also feeds but the ioctl is
            // explicit. Failure is non-fatal — kernel will reset us anyway
            // if real trouble, which is the whole point.
            ::ioctl(wdFd, WDIOC_KEEPALIVE, 0);
        });
        wdTimer->start();
    } else {
        qCInfo(lcMain) << "Watchdog device not available — proceeding without HW watchdog";
    }

    return app.exec();
}
