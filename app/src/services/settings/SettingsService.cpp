#include "SettingsService.h"
#include "../profile/ProfileService.h"

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QSaveFile>
#include <QStandardPaths>
#include <QVariantMap>

Q_LOGGING_CATEGORY(lcSettings, "q60nav.settings")

// 5-second debounce before writing to disk
static constexpr int SAVE_DEBOUNCE_MS = 5000;

// ---------------------------------------------------------------------------
SettingsService::SettingsService(QObject *parent)
    : QObject(parent)
    , m_saveTimer(new QTimer(this))
{
    m_saveTimer->setSingleShot(true);
    m_saveTimer->setInterval(SAVE_DEBOUNCE_MS);
    connect(m_saveTimer, &QTimer::timeout, this, &SettingsService::onSaveTimerFired);
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

    m_upperBrightness       = iget("upperBrightness",       80);
    m_lowerBrightness       = iget("lowerBrightness",       80);
    m_dayNightMode          = iget("dayNightMode",           0);
    m_timeFormat            = iget("timeFormat",             0);
    m_gpsSync               = bget("gpsSync",             true);
    m_clockHour             = iget("clockHour",             12);
    m_clockMinute           = iget("clockMinute",            0);
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
    root["timeFormat"]            = m_timeFormat;
    root["gpsSync"]               = m_gpsSync;
    root["clockHour"]             = m_clockHour;
    root["clockMinute"]           = m_clockMinute;
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
    root["maintenanceInterval"]   = m_maintenanceInterval;

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

// Clock
SETTER_INT (TimeFormat,            timeFormat,            clockChanged)
SETTER_BOOL(GpsSync,               gpsSync,               clockChanged)
SETTER_INT (ClockHour,             clockHour,             clockChanged)
SETTER_INT (ClockMinute,           clockMinute,           clockChanged)

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

#undef SETTER_INT
#undef SETTER_BOOL
