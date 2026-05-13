#include "SettingsService.h"
#include "../profile/ProfileService.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTextStream>
#include <QVariantMap>

Q_LOGGING_CATEGORY(lcSettings, "q60nav.settings")

// 5-second debounce before writing to disk
static constexpr int SAVE_DEBOUNCE_MS = 5000;

// Uptime ticks 1 Hz — drives QML "Uptime: 1h 23m" label
static constexpr int UPTIME_TICK_MS = 1000;

// Hardcoded build identity — bumped per release
static const char *kSoftwareVersion = "0.2.0-dev";

// Map data version is read from this file at startup, if present
static const char *kMapVersionFile = "/opt/nav/tiles/version.txt";

// ---------------------------------------------------------------------------
SettingsService::SettingsService(QObject *parent)
    : QObject(parent)
    , m_saveTimer(new QTimer(this))
    , m_uptimeTimer(new QTimer(this))
{
    m_saveTimer->setSingleShot(true);
    m_saveTimer->setInterval(SAVE_DEBOUNCE_MS);
    connect(m_saveTimer, &QTimer::timeout, this, &SettingsService::onSaveTimerFired);

    // System metadata — frozen at construct time
    m_softwareVersion = QString::fromLatin1(kSoftwareVersion);
    m_mapDataVersion  = readMapDataVersion();
    m_buildDate       = QStringLiteral(__DATE__ " " __TIME__);
    m_bootTime        = QDateTime::currentMSecsSinceEpoch();

    // Seed fictional bluetooth device list — UI shell pending BlueZ wire-up
    seedDefaultBtDevices();

    // Live uptime tick — 1 Hz emit so the System sub-page label updates
    m_uptimeTimer->setInterval(UPTIME_TICK_MS);
    connect(m_uptimeTimer, &QTimer::timeout, this, &SettingsService::onUptimeTimerFired);
    m_uptimeTimer->start();
}

// ---------------------------------------------------------------------------
void SettingsService::start(ProfileService *profileSvc)
{
    m_profileSvc = profileSvc;

    // Load persisted device-level settings (or stay at compiled defaults)
    loadFromDisk();

    // If a profile is already active at start time, overlay its preferences
    if (profileSvc && profileSvc->profileLoaded()) {
        const QVariantMap p = profileSvc->activeProfile();
        if (!p.isEmpty())
            applyFromProfile(p);
    }

    // Whenever the profile switches, pull profile-linked settings in
    if (profileSvc) {
        connect(profileSvc, &ProfileService::profileChanged, this, [this]() {
            if (!m_profileSvc || !m_profileSvc->profileLoaded())
                return;
            const QVariantMap p = m_profileSvc->activeProfile();
            if (!p.isEmpty())
                applyFromProfile(p);
        });
    }

    qCInfo(lcSettings) << "Started — settings file:" << settingsFilePath();
}

// ---------------------------------------------------------------------------
// applyFromProfile — overlay profile-linked prefs on top of device settings.
// Only the keys the profile schema actually carries are touched; everything
// else stays as-is (device-level).
// ---------------------------------------------------------------------------
void SettingsService::applyFromProfile(const QVariantMap &profile)
{
    // nav section
    const QVariantMap nav = profile.value(QStringLiteral("nav")).toMap();
    if (!nav.isEmpty()) {
        // routeType: "fastest"=0 "shortest"=1 "eco"=2
        const QString rt = nav.value(QStringLiteral("routeType")).toString();
        if (rt == QStringLiteral("shortest"))      setRoutePref(1);
        else if (rt == QStringLiteral("eco"))      setRoutePref(2);
        else                                       setRoutePref(0);

        if (nav.contains(QStringLiteral("avoidTolls")))
            setAvoidTolls(nav.value(QStringLiteral("avoidTolls")).toBool());
        if (nav.contains(QStringLiteral("avoidHighways")))
            setAvoidHighways(nav.value(QStringLiteral("avoidHighways")).toBool());
    }

    // display section
    const QVariantMap disp = profile.value(QStringLiteral("display")).toMap();
    if (!disp.isEmpty()) {
        if (disp.contains(QStringLiteral("brightness")))
            setUpperBrightness(disp.value(QStringLiteral("brightness")).toInt());

        // clockFormat: "12h"=0 "24h"=1
        const QString cf = disp.value(QStringLiteral("clockFormat")).toString();
        if (cf == QStringLiteral("24h")) setTimeFormat(1);
        else                             setTimeFormat(0);

        // units: "imperial"=0 "metric"=1
        const QString units = disp.value(QStringLiteral("units")).toString();
        if (units == QStringLiteral("metric")) {
            setDistanceUnit(1);
            setTempUnit(1);
            setFuelUnit(1);
        } else {
            setDistanceUnit(0);
            setTempUnit(0);
            setFuelUnit(0);
        }
    }

    // drive section
    const QVariantMap drive = profile.value(QStringLiteral("drive")).toMap();
    if (!drive.isEmpty()) {
        if (drive.contains(QStringLiteral("vdcOff")))
            setVdcEnabled(!drive.value(QStringLiteral("vdcOff")).toBool());
    }

    qCInfo(lcSettings) << "Applied profile-linked settings from active profile";
}

// ---------------------------------------------------------------------------
// writeToProfile — push profile-linked settings back to ProfileService.
// Only called when a profile is loaded; profile-less / guest sessions skip.
// ---------------------------------------------------------------------------
void SettingsService::writeToProfile()
{
    if (!m_profileSvc || !m_profileSvc->profileLoaded())
        return;

    // nav section
    const QString routeStr = (m_routePref == 1) ? QStringLiteral("shortest")
                           : (m_routePref == 2) ? QStringLiteral("eco")
                           :                      QStringLiteral("fastest");
    m_profileSvc->setProfileField(QStringLiteral("nav"), QStringLiteral("routeType"),    routeStr);
    m_profileSvc->setProfileField(QStringLiteral("nav"), QStringLiteral("avoidTolls"),   m_avoidTolls);
    m_profileSvc->setProfileField(QStringLiteral("nav"), QStringLiteral("avoidHighways"),m_avoidHighways);

    // display section
    m_profileSvc->setProfileField(QStringLiteral("display"), QStringLiteral("brightness"),
                                  m_upperBrightness);
    m_profileSvc->setProfileField(QStringLiteral("display"), QStringLiteral("clockFormat"),
                                  (m_timeFormat == 1) ? QStringLiteral("24h") : QStringLiteral("12h"));
    m_profileSvc->setProfileField(QStringLiteral("display"), QStringLiteral("units"),
                                  (m_distanceUnit == 1) ? QStringLiteral("metric") : QStringLiteral("imperial"));

    // drive section
    m_profileSvc->setProfileField(QStringLiteral("drive"), QStringLiteral("vdcOff"), !m_vdcEnabled);

    qCInfo(lcSettings) << "Wrote profile-linked settings back to active profile";
}

// ---------------------------------------------------------------------------
// saveNow / onSaveTimerFired
// ---------------------------------------------------------------------------
void SettingsService::saveNow()
{
    m_saveTimer->stop();
    saveToDisk();
}

void SettingsService::onSaveTimerFired()
{
    saveToDisk();
    writeToProfile();
}

void SettingsService::onUptimeTimerFired()
{
    emit uptimeChanged();
}

qint64 SettingsService::uptimeMs() const
{
    return QDateTime::currentMSecsSinceEpoch() - m_bootTime;
}

// ---------------------------------------------------------------------------
// armSaveTimer — restart debounce on every property change
// ---------------------------------------------------------------------------
void SettingsService::armSaveTimer()
{
    m_saveTimer->start();
}

// ---------------------------------------------------------------------------
// settingsFilePath
// ---------------------------------------------------------------------------
QString SettingsService::settingsFilePath() const
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    return dir + QStringLiteral("/settings.json");
}

// ---------------------------------------------------------------------------
// readMapDataVersion — read /opt/nav/tiles/version.txt if present
// ---------------------------------------------------------------------------
QString SettingsService::readMapDataVersion() const
{
    QFile f(QString::fromLatin1(kMapVersionFile));
    if (!f.exists() || !f.open(QIODevice::ReadOnly))
        return QStringLiteral("unknown");
    QTextStream ts(&f);
    const QString v = ts.readLine().trimmed();
    return v.isEmpty() ? QStringLiteral("unknown") : v;
}

// ---------------------------------------------------------------------------
// seedDefaultBtDevices — fictional pairing-list shim
// Names mirror the phone-agent contact style: "Phone (Driver)", etc.
// ---------------------------------------------------------------------------
void SettingsService::seedDefaultBtDevices()
{
    m_btDevices.clear();

    auto makeDev = [](const QString &name, const QString &mac, int prio, bool connected) {
        QVariantMap m;
        m["name"]      = name;
        m["mac"]       = mac;
        m["priority"]  = prio;
        m["connected"] = connected;
        return m;
    };

    m_btDevices.append(makeDev(QStringLiteral("Phone (Driver)"),    QStringLiteral("AA:BB:CC:00:00:01"), 0, true));
    m_btDevices.append(makeDev(QStringLiteral("Phone (Passenger)"), QStringLiteral("AA:BB:CC:00:00:02"), 1, false));
    m_btDevices.append(makeDev(QStringLiteral("AirPods Pro"),       QStringLiteral("AA:BB:CC:00:00:03"), 2, false));
}

// ---------------------------------------------------------------------------
// loadFromDisk — read settings.json, overlay values onto defaults
// ---------------------------------------------------------------------------
void SettingsService::loadFromDisk()
{
    const QString path = settingsFilePath();
    QFile f(path);
    if (!f.exists()) {
        qCInfo(lcSettings) << "No settings file — using defaults";
        return;
    }
    if (!f.open(QIODevice::ReadOnly)) {
        qCWarning(lcSettings) << "Cannot open settings file:" << path;
        return;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (doc.isNull() || !doc.isObject()) {
        qCWarning(lcSettings) << "settings.json is corrupt — using defaults";
        return;
    }

    const QJsonObject root = doc.object();

    auto iget  = [&](const QString &k, int  def)  { return root.contains(k) ? root.value(k).toInt(def)  : def; };
    auto bget  = [&](const QString &k, bool def)  { return root.contains(k) ? root.value(k).toBool(def) : def; };
    auto sget  = [&](const QString &k, const QString &def) {
        return root.contains(k) ? root.value(k).toString(def) : def;
    };

    m_upperBrightness       = iget("upperBrightness",       80);
    m_lowerBrightness       = iget("lowerBrightness",       80);
    m_dayNightMode          = iget("dayNightMode",           0);
    m_autoDimThreshold      = iget("autoDimThreshold",     100);
    m_timeFormat            = iget("timeFormat",             0);
    m_gpsSync               = bget("gpsSync",             true);
    m_clockHour             = iget("clockHour",             12);
    m_clockMinute           = iget("clockMinute",            0);
    m_timezoneOffset        = iget("timezoneOffset",        -5);
    m_distanceUnit          = iget("distanceUnit",           0);
    m_tempUnit              = iget("tempUnit",               0);
    m_fuelUnit              = iget("fuelUnit",               0);
    m_voiceGuidance         = bget("voiceGuidance",       true);
    m_voiceVolume           = iget("voiceVolume",           70);
    m_routePref             = iget("routePref",              0);
    m_avoidTolls            = bget("avoidTolls",         false);
    m_avoidHighways         = bget("avoidHighways",      false);
    m_poiIconsOnMap         = bget("poiIconsOnMap",       true);
    m_clickSounds           = bget("clickSounds",         true);
    m_navPromptVolume       = iget("navPromptVolume",       80);
    m_vdcEnabled            = bget("vdcEnabled",          true);
    m_ascEnabled            = bget("ascEnabled",          true);
    if (root.contains("trackModeConfig"))
        m_trackModeConfig   = root.value("trackModeConfig").toString(m_trackModeConfig);
    m_speedAlertThreshold   = iget("speedAlertThreshold",    5);
    m_lightShutoff          = iget("lightShutoff",           2);
    m_headlightSensitivity  = iget("headlightSensitivity",   1);
    m_drlEnabled            = bget("drlEnabled",          true);
    m_approachLighting      = bget("approachLighting",    true);
    m_approachLightDuration = iget("approachLightDuration",  1);
    m_welcomeLighting       = bget("welcomeLighting",     true);
    m_interiorLightTimer    = iget("interiorLightTimer",     1);
    m_autoLockSpeed         = iget("autoLockSpeed",          1);
    m_autoUnlockPark        = bget("autoUnlockPark",      true);
    m_autoUnlockKeyRemoval  = bget("autoUnlockKeyRemoval",false);
    m_fobLockAll            = bget("fobLockAll",          true);
    m_mirrorTiltReverse     = bget("mirrorTiltReverse",   true);
    m_mirrorFoldLock        = bget("mirrorFoldLock",     false);
    m_rainSensorSensitivity = iget("rainSensorSensitivity",  3);
    m_wiperDelay            = iget("wiperDelay",             3);
    m_seatMemoryOnUnlock    = bget("seatMemoryOnUnlock",  true);
    m_powerWindowAutoOpen   = bget("powerWindowAutoOpen", true);
    m_seatbeltReminder      = bget("seatbeltReminder",    true);
    m_parkAssistChimeVolume = iget("parkAssistChimeVolume",  2);
    m_mapOrientation        = iget("mapOrientation",         0);
    m_speedLimitDisplay     = bget("speedLimitDisplay",   true);
    m_mapDetailLevel        = iget("mapDetailLevel",         1);
    m_maintenanceInterval   = iget("maintenanceInterval",    1);
    m_language              = iget("language",               0);
    m_driveModePersonalConfig = sget("driveModePersonalConfig", QString());

    // Bluetooth — replace seeded list if persisted one is present
    if (root.contains(QStringLiteral("btDevices")) && root.value(QStringLiteral("btDevices")).isArray()) {
        const QJsonArray arr = root.value(QStringLiteral("btDevices")).toArray();
        QVariantList loaded;
        for (const QJsonValue &v : arr) {
            const QJsonObject o = v.toObject();
            QVariantMap m;
            m["name"]      = o.value("name").toString();
            m["mac"]       = o.value("mac").toString();
            m["priority"]  = o.value("priority").toInt(0);
            m["connected"] = o.value("connected").toBool(false);
            loaded.append(m);
        }
        if (!loaded.isEmpty()) {
            m_btDevices = loaded;
            emit btDevicesChanged();
        }
    }

    // Audio presets — JSON string blob (may be stored as either a raw string
    // field or a nested object that we serialize back to a string).
    if (root.contains("audioPresets")) {
        const QJsonValue v = root.value("audioPresets");
        if (v.isString()) {
            m_audioPresets = v.toString();
        } else if (v.isObject()) {
            m_audioPresets = QString::fromUtf8(
                QJsonDocument(v.toObject()).toJson(QJsonDocument::Compact));
        }
    }

    qCInfo(lcSettings) << "Loaded settings from disk";
}

// ---------------------------------------------------------------------------
// saveToDisk — atomic write via QSaveFile
// ---------------------------------------------------------------------------
void SettingsService::saveToDisk()
{
    QJsonObject root;
    root["upperBrightness"]       = m_upperBrightness;
    root["lowerBrightness"]       = m_lowerBrightness;
    root["dayNightMode"]          = m_dayNightMode;
    root["autoDimThreshold"]      = m_autoDimThreshold;
    root["timeFormat"]            = m_timeFormat;
    root["gpsSync"]               = m_gpsSync;
    root["clockHour"]             = m_clockHour;
    root["clockMinute"]           = m_clockMinute;
    root["timezoneOffset"]        = m_timezoneOffset;
    root["distanceUnit"]          = m_distanceUnit;
    root["tempUnit"]              = m_tempUnit;
    root["fuelUnit"]              = m_fuelUnit;
    root["voiceGuidance"]         = m_voiceGuidance;
    root["voiceVolume"]           = m_voiceVolume;
    root["routePref"]             = m_routePref;
    root["avoidTolls"]            = m_avoidTolls;
    root["avoidHighways"]         = m_avoidHighways;
    root["poiIconsOnMap"]         = m_poiIconsOnMap;
    root["clickSounds"]           = m_clickSounds;
    root["navPromptVolume"]       = m_navPromptVolume;
    root["vdcEnabled"]            = m_vdcEnabled;
    root["ascEnabled"]            = m_ascEnabled;
    root["trackModeConfig"]       = m_trackModeConfig;
    root["speedAlertThreshold"]   = m_speedAlertThreshold;
    root["lightShutoff"]          = m_lightShutoff;
    root["headlightSensitivity"]  = m_headlightSensitivity;
    root["drlEnabled"]            = m_drlEnabled;
    root["approachLighting"]      = m_approachLighting;
    root["approachLightDuration"] = m_approachLightDuration;
    root["welcomeLighting"]       = m_welcomeLighting;
    root["interiorLightTimer"]    = m_interiorLightTimer;
    root["autoLockSpeed"]         = m_autoLockSpeed;
    root["autoUnlockPark"]        = m_autoUnlockPark;
    root["autoUnlockKeyRemoval"]  = m_autoUnlockKeyRemoval;
    root["fobLockAll"]            = m_fobLockAll;
    root["mirrorTiltReverse"]     = m_mirrorTiltReverse;
    root["mirrorFoldLock"]        = m_mirrorFoldLock;
    root["rainSensorSensitivity"] = m_rainSensorSensitivity;
    root["wiperDelay"]            = m_wiperDelay;
    root["seatMemoryOnUnlock"]    = m_seatMemoryOnUnlock;
    root["powerWindowAutoOpen"]   = m_powerWindowAutoOpen;
    root["seatbeltReminder"]      = m_seatbeltReminder;
    root["parkAssistChimeVolume"] = m_parkAssistChimeVolume;
    root["mapOrientation"]        = m_mapOrientation;
    root["speedLimitDisplay"]     = m_speedLimitDisplay;
    root["mapDetailLevel"]        = m_mapDetailLevel;
    root["maintenanceInterval"]     = m_maintenanceInterval;
    root["language"]                = m_language;
    root["driveModePersonalConfig"] = m_driveModePersonalConfig;

    // Bluetooth list
    QJsonArray bt;
    for (const QVariant &v : m_btDevices) {
        const QVariantMap d = v.toMap();
        QJsonObject o;
        o["name"]      = d.value("name").toString();
        o["mac"]       = d.value("mac").toString();
        o["priority"]  = d.value("priority").toInt();
        o["connected"] = d.value("connected").toBool();
        bt.append(o);
    }
    root["btDevices"] = bt;

    // Audio presets — stored as a nested object when possible (more readable)
    if (!m_audioPresets.isEmpty()) {
        const QJsonDocument apDoc = QJsonDocument::fromJson(m_audioPresets.toUtf8());
        if (apDoc.isObject())
            root["audioPresets"] = apDoc.object();
        else
            root["audioPresets"] = m_audioPresets;  // fall back to raw string
    }

    const QJsonDocument doc(root);
    const QString path = settingsFilePath();

    // Ensure directory exists
    QDir().mkpath(QFileInfo(path).absolutePath());

    QSaveFile sf(path);
    if (!sf.open(QIODevice::WriteOnly)) {
        qCWarning(lcSettings) << "Cannot open QSaveFile for settings:" << path;
        return;
    }
    sf.write(doc.toJson(QJsonDocument::Indented));
    if (!sf.commit()) {
        qCWarning(lcSettings) << "QSaveFile commit failed — settings not saved";
        return;
    }

    qCInfo(lcSettings) << "Settings saved to" << path;
}

// ---------------------------------------------------------------------------
// resetToDefaults — wipe state, delete JSON, re-emit all Changed signals
// ---------------------------------------------------------------------------
void SettingsService::resetToDefaults()
{
    qCInfo(lcSettings) << "Factory reset requested — wiping settings";

    // Cancel any pending debounced save before we nuke state
    m_saveTimer->stop();

    // Reassign to compiled defaults (mirrors header initializers)
    m_upperBrightness       = 80;
    m_lowerBrightness       = 80;
    m_dayNightMode          = 0;
    m_autoDimThreshold      = 100;
    m_timeFormat            = 0;
    m_gpsSync               = true;
    m_clockHour             = 12;
    m_clockMinute           = 0;
    m_timezoneOffset        = -5;
    m_distanceUnit          = 0;
    m_tempUnit              = 0;
    m_fuelUnit              = 0;
    m_voiceGuidance         = true;
    m_voiceVolume           = 70;
    m_routePref             = 0;
    m_avoidTolls            = false;
    m_avoidHighways         = false;
    m_poiIconsOnMap         = true;
    m_clickSounds           = true;
    m_navPromptVolume       = 80;
    m_vdcEnabled            = true;
    m_lightShutoff          = 2;
    m_headlightSensitivity  = 1;
    m_drlEnabled            = true;
    m_approachLighting      = true;
    m_approachLightDuration = 1;
    m_welcomeLighting       = true;
    m_interiorLightTimer    = 1;
    m_autoLockSpeed         = 1;
    m_autoUnlockPark        = true;
    m_autoUnlockKeyRemoval  = false;
    m_fobLockAll            = true;
    m_mirrorTiltReverse     = true;
    m_mirrorFoldLock        = false;
    m_rainSensorSensitivity = 3;
    m_wiperDelay            = 3;
    m_seatMemoryOnUnlock    = true;
    m_powerWindowAutoOpen   = true;
    m_seatbeltReminder      = true;
    m_parkAssistChimeVolume = 2;
    m_mapOrientation        = 0;
    m_speedLimitDisplay     = true;
    m_mapDetailLevel        = 1;
    m_maintenanceInterval   = 1;
    m_language              = 0;
    seedDefaultBtDevices();

    // Delete settings.json — preferring AppDataLocation copy; also wipe
    // the legacy /opt/nav/config/settings.json mentioned in the spec if
    // it exists. Failure to remove either is logged, not fatal.
    const QString primary = settingsFilePath();
    QFile primaryFile(primary);
    if (primaryFile.exists() && !primaryFile.remove())
        qCWarning(lcSettings) << "Could not delete" << primary;

    QFile legacyFile(QStringLiteral("/opt/nav/config/settings.json"));
    if (legacyFile.exists() && !legacyFile.remove())
        qCWarning(lcSettings) << "Could not delete /opt/nav/config/settings.json";

    // Re-emit every group signal so QML rebinds to fresh defaults
    emitAllChanged();

    qCInfo(lcSettings) << "Factory reset complete";
}

void SettingsService::emitAllChanged()
{
    emit displayChanged();
    emit clockChanged();
    emit unitsChanged();
    emit navChanged();
    emit audioSettingsChanged();
    emit vehicleChanged();
    emit lightsChanged();
    emit locksChanged();
    emit mirrorsChanged();
    emit wipersChanged();
    emit comfortChanged();
    emit mapSettingsChanged();
    emit maintenanceChanged();
    emit btDevicesChanged();
    emit languageChanged();
    emit uptimeChanged();
}

// ============================================================================
// Setters — guard (no-op if unchanged), update member, emit signal, arm timer
// ============================================================================

#define SETTER_INT(name, member, signal)         \
void SettingsService::set##name(int v) {         \
    if (m_##member == v) return;                 \
    m_##member = v;                              \
    emit signal();                               \
    armSaveTimer();                              \
}

#define SETTER_BOOL(name, member, signal)        \
void SettingsService::set##name(bool v) {        \
    if (m_##member == v) return;                 \
    m_##member = v;                              \
    emit signal();                               \
    armSaveTimer();                              \
}

// Display
SETTER_INT (UpperBrightness,       upperBrightness,       displayChanged)
SETTER_INT (LowerBrightness,       lowerBrightness,       displayChanged)
SETTER_INT (DayNightMode,          dayNightMode,          displayChanged)
SETTER_INT (AutoDimThreshold,      autoDimThreshold,      displayChanged)

// Clock
SETTER_INT (TimeFormat,            timeFormat,            clockChanged)
SETTER_BOOL(GpsSync,               gpsSync,               clockChanged)
SETTER_INT (ClockHour,             clockHour,             clockChanged)
SETTER_INT (ClockMinute,           clockMinute,           clockChanged)
SETTER_INT (TimezoneOffset,        timezoneOffset,        clockChanged)

// Units
SETTER_INT (DistanceUnit,          distanceUnit,          unitsChanged)
SETTER_INT (TempUnit,              tempUnit,              unitsChanged)
SETTER_INT (FuelUnit,              fuelUnit,              unitsChanged)

// Navigation
SETTER_BOOL(VoiceGuidance,         voiceGuidance,         navChanged)
SETTER_INT (VoiceVolume,           voiceVolume,           navChanged)
SETTER_INT (RoutePref,             routePref,             navChanged)
SETTER_BOOL(AvoidTolls,            avoidTolls,            navChanged)
SETTER_BOOL(AvoidHighways,         avoidHighways,         navChanged)
SETTER_BOOL(PoiIconsOnMap,         poiIconsOnMap,         navChanged)

// Audio
SETTER_BOOL(ClickSounds,           clickSounds,           audioSettingsChanged)
SETTER_INT (NavPromptVolume,       navPromptVolume,       audioSettingsChanged)

// Vehicle
SETTER_BOOL(VdcEnabled,            vdcEnabled,            vehicleChanged)

// Speed alert — routed through navChanged() since the badge lives in NavigationView
SETTER_INT (SpeedAlertThreshold,   speedAlertThreshold,   navChanged)

// Lights
SETTER_INT (LightShutoff,          lightShutoff,          lightsChanged)
SETTER_INT (HeadlightSensitivity,  headlightSensitivity,  lightsChanged)
SETTER_BOOL(DrlEnabled,            drlEnabled,            lightsChanged)
SETTER_BOOL(ApproachLighting,      approachLighting,      lightsChanged)
SETTER_INT (ApproachLightDuration, approachLightDuration, lightsChanged)
SETTER_BOOL(WelcomeLighting,       welcomeLighting,       lightsChanged)
SETTER_INT (InteriorLightTimer,    interiorLightTimer,    lightsChanged)

// Door Locks
SETTER_INT (AutoLockSpeed,         autoLockSpeed,         locksChanged)
SETTER_BOOL(AutoUnlockPark,        autoUnlockPark,        locksChanged)
SETTER_BOOL(AutoUnlockKeyRemoval,  autoUnlockKeyRemoval,  locksChanged)
SETTER_BOOL(FobLockAll,            fobLockAll,            locksChanged)

// Mirrors
SETTER_BOOL(MirrorTiltReverse,     mirrorTiltReverse,     mirrorsChanged)
SETTER_BOOL(MirrorFoldLock,        mirrorFoldLock,        mirrorsChanged)

// Wipers
SETTER_INT (RainSensorSensitivity, rainSensorSensitivity, wipersChanged)
SETTER_INT (WiperDelay,            wiperDelay,            wipersChanged)

// Comfort
SETTER_BOOL(SeatMemoryOnUnlock,    seatMemoryOnUnlock,    comfortChanged)
SETTER_BOOL(PowerWindowAutoOpen,   powerWindowAutoOpen,   comfortChanged)
SETTER_BOOL(SeatbeltReminder,      seatbeltReminder,      comfortChanged)
SETTER_INT (ParkAssistChimeVolume, parkAssistChimeVolume, comfortChanged)

// Map
SETTER_INT (MapOrientation,        mapOrientation,        mapSettingsChanged)
SETTER_BOOL(SpeedLimitDisplay,     speedLimitDisplay,     mapSettingsChanged)
SETTER_INT (MapDetailLevel,        mapDetailLevel,        mapSettingsChanged)

// Maintenance
SETTER_INT (MaintenanceInterval,   maintenanceInterval,   maintenanceChanged)

// Language
SETTER_INT (Language,              language,              languageChanged)

#undef SETTER_INT
#undef SETTER_BOOL

// ============================================================================
// Bluetooth UI actions — mock list manipulation. TODO: wire to BlueZ.
// ============================================================================

void SettingsService::btForgetDevice(const QString &mac)
{
    // TODO: wire to BlueZ — call org.bluez.Device1.Remove on the adapter
    for (int i = 0; i < m_btDevices.size(); ++i) {
        if (m_btDevices.at(i).toMap().value("mac").toString() == mac) {
            m_btDevices.removeAt(i);
            emit btDevicesChanged();
            armSaveTimer();
            return;
        }
    }
}

void SettingsService::btSetPriority(const QString &mac, int delta)
{
    // TODO: wire to BlueZ — priority controls AVRCP / HFP fallback order
    int idx = -1;
    for (int i = 0; i < m_btDevices.size(); ++i) {
        if (m_btDevices.at(i).toMap().value("mac").toString() == mac) {
            idx = i;
            break;
        }
    }
    if (idx < 0) return;

    const int swap = idx + ((delta > 0) ? -1 : 1);
    if (swap < 0 || swap >= m_btDevices.size()) return;

    m_btDevices.swapItemsAt(idx, swap);

    // Rewrite priority field to match new ordering
    for (int i = 0; i < m_btDevices.size(); ++i) {
        QVariantMap m = m_btDevices.at(i).toMap();
        m["priority"] = i;
        m_btDevices[i] = m;
    }

    emit btDevicesChanged();
    armSaveTimer();
}

void SettingsService::btToggleConnect(const QString &mac)
{
    // TODO: wire to BlueZ — org.bluez.Device1.Connect / Disconnect
    for (int i = 0; i < m_btDevices.size(); ++i) {
        QVariantMap d = m_btDevices.at(i).toMap();
        if (d.value("mac").toString() == mac) {
            d["connected"] = !d.value("connected").toBool();
            m_btDevices[i] = d;
            emit btDevicesChanged();
            armSaveTimer();
            return;
        }
    }
}

void SettingsService::btAddMockDevice(const QString &name)
{
    // TODO: wire to BlueZ — this stand-in fires when pairing-mode "accepts"
    // a device. Real flow listens for org.bluez.Adapter1.DeviceFound signals.
    QVariantMap m;
    m["name"]      = name.isEmpty() ? QStringLiteral("New Device") : name;
    m["mac"]       = QStringLiteral("AA:BB:CC:%1:%2:%3")
                        .arg(QString::number(QDateTime::currentMSecsSinceEpoch() & 0xFF, 16).toUpper().rightJustified(2, '0'),
                             QString::number((QDateTime::currentMSecsSinceEpoch() >> 8) & 0xFF, 16).toUpper().rightJustified(2, '0'),
                             QString::number((QDateTime::currentMSecsSinceEpoch() >> 16) & 0xFF, 16).toUpper().rightJustified(2, '0'));
    m["priority"]  = m_btDevices.size();
    m["connected"] = false;
    m_btDevices.append(m);
    emit btDevicesChanged();
    armSaveTimer();
}

// Audio presets — manual setter (string type, no SETTER_* macro)
void SettingsService::setAudioPresets(const QString &v)
{
    if (m_audioPresets == v) return;
    m_audioPresets = v;
    emit audioPresetsChanged();
    armSaveTimer();
}

// ── Drive mode (Personal config) ──────────────────────────────────────────
// QString setter (JSON blob — opaque to this class).
void SettingsService::setDriveModePersonalConfig(const QString &json)
{
    if (m_driveModePersonalConfig == json) return;
    m_driveModePersonalConfig = json;
    emit driveModePersonalConfigChanged();
    armSaveTimer();
}

void SettingsService::setAscEnabled(bool v)
{
    if (m_ascEnabled == v) return;
    m_ascEnabled = v;
    emit ascEnabledChanged();
    armSaveTimer();
}

void SettingsService::setTrackModeConfig(const QString &v)
{
    if (m_trackModeConfig == v) return;
    m_trackModeConfig = v;
    emit trackModeConfigChanged();
    armSaveTimer();
}
