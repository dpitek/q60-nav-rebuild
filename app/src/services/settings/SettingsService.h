#pragma once
// SettingsService.h — System + vehicle preference persistence
//
// Owns ALL settings from SettingsView.qml.  Persists to
//   QStandardPaths::AppDataLocation / settings.json
// using QSaveFile (atomic write — safe across power-loss / reboot).
//
// Profile-linked settings (nav prefs, display, units) are mirrored
// to/from the active ProfileService entry via applyFromProfile() /
// writeToProfile().  Every other setting is device-level.
//
// Auto-save: 5s debounce timer fires after any property change.
//
// Instantiated in main.cpp, exposed to QML as "SettingsService".

#include <QObject>
#include <QTimer>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QDateTime>

class ProfileService;

class SettingsService : public QObject
{
    Q_OBJECT

    // ── Display ────────────────────────────────────────────────────────────
    Q_PROPERTY(int  upperBrightness   READ upperBrightness   WRITE setUpperBrightness   NOTIFY displayChanged)
    Q_PROPERTY(int  lowerBrightness   READ lowerBrightness   WRITE setLowerBrightness   NOTIFY displayChanged)
    Q_PROPERTY(int  dayNightMode      READ dayNightMode      WRITE setDayNightMode      NOTIFY displayChanged)
    // 0=Auto 1=Day 2=Night
    Q_PROPERTY(int  autoDimThreshold  READ autoDimThreshold  WRITE setAutoDimThreshold  NOTIFY displayChanged)
    // lux threshold (0–1000) — engages day mode below this value when dayNightMode=Auto

    // ── Clock ──────────────────────────────────────────────────────────────
    Q_PROPERTY(int  timeFormat     READ timeFormat     WRITE setTimeFormat     NOTIFY clockChanged)
    // 0=12h 1=24h
    Q_PROPERTY(bool gpsSync        READ gpsSync        WRITE setGpsSync        NOTIFY clockChanged)
    Q_PROPERTY(int  clockHour      READ clockHour      WRITE setClockHour      NOTIFY clockChanged)
    Q_PROPERTY(int  clockMinute    READ clockMinute    WRITE setClockMinute    NOTIFY clockChanged)
    Q_PROPERTY(int  timezoneOffset READ timezoneOffset WRITE setTimezoneOffset NOTIFY clockChanged)
    // hours offset from UTC, -12 to +14

    // ── Units ──────────────────────────────────────────────────────────────
    Q_PROPERTY(int distanceUnit READ distanceUnit WRITE setDistanceUnit NOTIFY unitsChanged)
    // 0=mi 1=km
    Q_PROPERTY(int tempUnit     READ tempUnit     WRITE setTempUnit     NOTIFY unitsChanged)
    // 0=°F 1=°C
    Q_PROPERTY(int fuelUnit     READ fuelUnit     WRITE setFuelUnit     NOTIFY unitsChanged)
    // 0=MPG 1=L/100km 2=km/L

    // ── Navigation ────────────────────────────────────────────────────────
    Q_PROPERTY(bool voiceGuidance   READ voiceGuidance   WRITE setVoiceGuidance   NOTIFY navChanged)
    Q_PROPERTY(int  voiceVolume     READ voiceVolume     WRITE setVoiceVolume     NOTIFY navChanged)
    Q_PROPERTY(int  routePref       READ routePref       WRITE setRoutePref       NOTIFY navChanged)
    // 0=Fastest 1=Shortest 2=Eco
    Q_PROPERTY(bool avoidTolls      READ avoidTolls      WRITE setAvoidTolls      NOTIFY navChanged)
    Q_PROPERTY(bool avoidHighways   READ avoidHighways   WRITE setAvoidHighways   NOTIFY navChanged)
    Q_PROPERTY(bool poiIconsOnMap   READ poiIconsOnMap   WRITE setPoiIconsOnMap   NOTIFY navChanged)

    // ── Audio ─────────────────────────────────────────────────────────────
    Q_PROPERTY(bool clickSounds      READ clickSounds      WRITE setClickSounds      NOTIFY audioSettingsChanged)
    Q_PROPERTY(int  navPromptVolume  READ navPromptVolume  WRITE setNavPromptVolume  NOTIFY audioSettingsChanged)

    // ── Vehicle ───────────────────────────────────────────────────────────
    Q_PROPERTY(bool vdcEnabled READ vdcEnabled WRITE setVdcEnabled NOTIFY vehicleChanged)

    // ── Lights ────────────────────────────────────────────────────────────
    Q_PROPERTY(int  lightShutoff           READ lightShutoff           WRITE setLightShutoff           NOTIFY lightsChanged)
    // index: 0=Off 1=30s 2=45s 3=60s 4=90s 5=2m 6=3m
    Q_PROPERTY(int  headlightSensitivity   READ headlightSensitivity   WRITE setHeadlightSensitivity   NOTIFY lightsChanged)
    // 0=Low 1=Med 2=High
    Q_PROPERTY(bool drlEnabled             READ drlEnabled             WRITE setDrlEnabled             NOTIFY lightsChanged)
    Q_PROPERTY(bool approachLighting       READ approachLighting       WRITE setApproachLighting       NOTIFY lightsChanged)
    Q_PROPERTY(int  approachLightDuration  READ approachLightDuration  WRITE setApproachLightDuration  NOTIFY lightsChanged)
    // 0=30s 1=60s 2=90s
    Q_PROPERTY(bool welcomeLighting        READ welcomeLighting        WRITE setWelcomeLighting        NOTIFY lightsChanged)
    Q_PROPERTY(int  interiorLightTimer     READ interiorLightTimer     WRITE setInteriorLightTimer     NOTIFY lightsChanged)
    // 0=15s 1=30s 2=45s 3=60s

    // ── Door Locks ────────────────────────────────────────────────────────
    Q_PROPERTY(int  autoLockSpeed          READ autoLockSpeed          WRITE setAutoLockSpeed          NOTIFY locksChanged)
    // 0=Off 1=15mph 2=25mph
    Q_PROPERTY(bool autoUnlockPark         READ autoUnlockPark         WRITE setAutoUnlockPark         NOTIFY locksChanged)
    Q_PROPERTY(bool autoUnlockKeyRemoval   READ autoUnlockKeyRemoval   WRITE setAutoUnlockKeyRemoval   NOTIFY locksChanged)
    Q_PROPERTY(bool fobLockAll             READ fobLockAll             WRITE setFobLockAll             NOTIFY locksChanged)

    // ── Mirrors ───────────────────────────────────────────────────────────
    Q_PROPERTY(bool mirrorTiltReverse  READ mirrorTiltReverse  WRITE setMirrorTiltReverse  NOTIFY mirrorsChanged)
    Q_PROPERTY(bool mirrorFoldLock     READ mirrorFoldLock     WRITE setMirrorFoldLock     NOTIFY mirrorsChanged)

    // ── Wipers ────────────────────────────────────────────────────────────
    Q_PROPERTY(int rainSensorSensitivity READ rainSensorSensitivity WRITE setRainSensorSensitivity NOTIFY wipersChanged)
    // 1–5
    Q_PROPERTY(int wiperDelay           READ wiperDelay           WRITE setWiperDelay           NOTIFY wipersChanged)
    // 1–5

    // ── Comfort ───────────────────────────────────────────────────────────
    Q_PROPERTY(bool seatMemoryOnUnlock     READ seatMemoryOnUnlock     WRITE setSeatMemoryOnUnlock     NOTIFY comfortChanged)
    Q_PROPERTY(bool powerWindowAutoOpen    READ powerWindowAutoOpen    WRITE setPowerWindowAutoOpen    NOTIFY comfortChanged)
    Q_PROPERTY(bool seatbeltReminder       READ seatbeltReminder       WRITE setSeatbeltReminder       NOTIFY comfortChanged)
    Q_PROPERTY(int  parkAssistChimeVolume  READ parkAssistChimeVolume  WRITE setParkAssistChimeVolume  NOTIFY comfortChanged)
    // 0=Off 1=Low 2=Med 3=High

    // ── Map ───────────────────────────────────────────────────────────────
    Q_PROPERTY(int  mapOrientation    READ mapOrientation    WRITE setMapOrientation    NOTIFY mapSettingsChanged)
    // 0=Heading 1=North 2=3D
    Q_PROPERTY(bool speedLimitDisplay READ speedLimitDisplay WRITE setSpeedLimitDisplay NOTIFY mapSettingsChanged)
    Q_PROPERTY(int  mapDetailLevel    READ mapDetailLevel    WRITE setMapDetailLevel    NOTIFY mapSettingsChanged)
    // 0=Low 1=Med 2=High

    // ── Maintenance ───────────────────────────────────────────────────────
    Q_PROPERTY(int maintenanceInterval READ maintenanceInterval WRITE setMaintenanceInterval NOTIFY maintenanceChanged)
    // 0=3k 1=5k 2=7.5k 3=10k

    // ── Bluetooth (UI shell — real BlueZ pairing pending hardware) ───────
    // Devices are stored as a list of QVariantMap rows:
    //   { "name": "Phone (Driver)", "mac": "AA:BB:CC:DD:EE:FF",
    //     "priority": 0, "connected": false }
    Q_PROPERTY(QVariantList btDevices READ btDevices NOTIFY btDevicesChanged)

    // ── Language (UI shell — real i18n binding is post-MVP) ──────────────
    Q_PROPERTY(int language READ language WRITE setLanguage NOTIFY languageChanged)
    // 0=English 1=Spanish 2=French 3=Japanese

    // ── System (read-only build / runtime metadata) ──────────────────────
    Q_PROPERTY(QString softwareVersion READ softwareVersion CONSTANT)
    Q_PROPERTY(QString mapDataVersion  READ mapDataVersion  CONSTANT)
    Q_PROPERTY(QString buildDate       READ buildDate       CONSTANT)
    Q_PROPERTY(qint64  uptimeMs        READ uptimeMs        NOTIFY uptimeChanged)

public:
    explicit SettingsService(QObject *parent = nullptr);
    ~SettingsService() override = default;

    // Call once after all services are constructed
    void start(ProfileService *profileSvc);

    // Apply settings from an active profile's JSON block.
    // Called by ProfileService after a profile switch.
    Q_INVOKABLE void applyFromProfile(const QVariantMap &profile);

    // Write profile-linked settings back to the active profile.
    // Called automatically on property change when a profile is loaded.
    Q_INVOKABLE void writeToProfile();

    // Force immediate save (bypasses debounce)
    Q_INVOKABLE void saveNow();

    // Factory reset — wipe in-memory state, delete settings.json on disk,
    // re-emit every Changed signal so QML rebinds to fresh defaults.
    Q_INVOKABLE void resetToDefaults();

    // ── Bluetooth UI actions (mock — TODO: wire to BlueZ) ────────────────
    Q_INVOKABLE void btForgetDevice(const QString &mac);
    Q_INVOKABLE void btSetPriority(const QString &mac, int delta); // +1 up, -1 down
    Q_INVOKABLE void btToggleConnect(const QString &mac);
    Q_INVOKABLE void btAddMockDevice(const QString &name);          // pairing-flow shim

    // ── Property accessors ──────────────────────────────────────────────
    int  upperBrightness()       const { return m_upperBrightness; }
    int  lowerBrightness()       const { return m_lowerBrightness; }
    int  dayNightMode()          const { return m_dayNightMode; }
    int  autoDimThreshold()      const { return m_autoDimThreshold; }
    int  timeFormat()            const { return m_timeFormat; }
    bool gpsSync()               const { return m_gpsSync; }
    int  clockHour()             const { return m_clockHour; }
    int  clockMinute()           const { return m_clockMinute; }
    int  timezoneOffset()        const { return m_timezoneOffset; }
    int  distanceUnit()          const { return m_distanceUnit; }
    int  tempUnit()              const { return m_tempUnit; }
    int  fuelUnit()              const { return m_fuelUnit; }
    bool voiceGuidance()         const { return m_voiceGuidance; }
    int  voiceVolume()           const { return m_voiceVolume; }
    int  routePref()             const { return m_routePref; }
    bool avoidTolls()            const { return m_avoidTolls; }
    bool avoidHighways()         const { return m_avoidHighways; }
    bool poiIconsOnMap()         const { return m_poiIconsOnMap; }
    bool clickSounds()           const { return m_clickSounds; }
    int  navPromptVolume()       const { return m_navPromptVolume; }
    bool vdcEnabled()            const { return m_vdcEnabled; }
    int  lightShutoff()          const { return m_lightShutoff; }
    int  headlightSensitivity()  const { return m_headlightSensitivity; }
    bool drlEnabled()            const { return m_drlEnabled; }
    bool approachLighting()      const { return m_approachLighting; }
    int  approachLightDuration() const { return m_approachLightDuration; }
    bool welcomeLighting()       const { return m_welcomeLighting; }
    int  interiorLightTimer()    const { return m_interiorLightTimer; }
    int  autoLockSpeed()         const { return m_autoLockSpeed; }
    bool autoUnlockPark()        const { return m_autoUnlockPark; }
    bool autoUnlockKeyRemoval()  const { return m_autoUnlockKeyRemoval; }
    bool fobLockAll()            const { return m_fobLockAll; }
    bool mirrorTiltReverse()     const { return m_mirrorTiltReverse; }
    bool mirrorFoldLock()        const { return m_mirrorFoldLock; }
    int  rainSensorSensitivity() const { return m_rainSensorSensitivity; }
    int  wiperDelay()            const { return m_wiperDelay; }
    bool seatMemoryOnUnlock()    const { return m_seatMemoryOnUnlock; }
    bool powerWindowAutoOpen()   const { return m_powerWindowAutoOpen; }
    bool seatbeltReminder()      const { return m_seatbeltReminder; }
    int  parkAssistChimeVolume() const { return m_parkAssistChimeVolume; }
    int  mapOrientation()        const { return m_mapOrientation; }
    bool speedLimitDisplay()     const { return m_speedLimitDisplay; }
    int  mapDetailLevel()        const { return m_mapDetailLevel; }
    int  maintenanceInterval()   const { return m_maintenanceInterval; }
    int  language()              const { return m_language; }
    QVariantList btDevices()     const { return m_btDevices; }
    QString softwareVersion()    const { return m_softwareVersion; }
    QString mapDataVersion()     const { return m_mapDataVersion; }
    QString buildDate()          const { return m_buildDate; }
    qint64  uptimeMs()           const;

    // ── Setters (each arms the save debounce) ───────────────────────────
    void setUpperBrightness(int v);
    void setLowerBrightness(int v);
    void setDayNightMode(int v);
    void setAutoDimThreshold(int v);
    void setTimeFormat(int v);
    void setGpsSync(bool v);
    void setClockHour(int v);
    void setClockMinute(int v);
    void setTimezoneOffset(int v);
    void setDistanceUnit(int v);
    void setTempUnit(int v);
    void setFuelUnit(int v);
    void setVoiceGuidance(bool v);
    void setVoiceVolume(int v);
    void setRoutePref(int v);
    void setAvoidTolls(bool v);
    void setAvoidHighways(bool v);
    void setPoiIconsOnMap(bool v);
    void setClickSounds(bool v);
    void setNavPromptVolume(int v);
    void setVdcEnabled(bool v);
    void setLightShutoff(int v);
    void setHeadlightSensitivity(int v);
    void setDrlEnabled(bool v);
    void setApproachLighting(bool v);
    void setApproachLightDuration(int v);
    void setWelcomeLighting(bool v);
    void setInteriorLightTimer(int v);
    void setAutoLockSpeed(int v);
    void setAutoUnlockPark(bool v);
    void setAutoUnlockKeyRemoval(bool v);
    void setFobLockAll(bool v);
    void setMirrorTiltReverse(bool v);
    void setMirrorFoldLock(bool v);
    void setRainSensorSensitivity(int v);
    void setWiperDelay(int v);
    void setSeatMemoryOnUnlock(bool v);
    void setPowerWindowAutoOpen(bool v);
    void setSeatbeltReminder(bool v);
    void setParkAssistChimeVolume(int v);
    void setMapOrientation(int v);
    void setSpeedLimitDisplay(bool v);
    void setMapDetailLevel(int v);
    void setMaintenanceInterval(int v);
    void setLanguage(int v);

signals:
    void displayChanged();
    void clockChanged();
    void unitsChanged();
    void navChanged();
    void audioSettingsChanged();
    void vehicleChanged();
    void lightsChanged();
    void locksChanged();
    void mirrorsChanged();
    void wipersChanged();
    void comfortChanged();
    void mapSettingsChanged();
    void maintenanceChanged();
    void btDevicesChanged();
    void languageChanged();
    void uptimeChanged();

private slots:
    void onSaveTimerFired();
    void onUptimeTimerFired();

private:
    QString settingsFilePath() const;
    void    loadFromDisk();
    void    saveToDisk();
    void    armSaveTimer();
    void    seedDefaultBtDevices();
    void    emitAllChanged();
    QString readMapDataVersion() const;

    // ── Data members — defaults match SettingsView.qml ─────────────────
    int  m_upperBrightness       = 80;
    int  m_lowerBrightness       = 80;
    int  m_dayNightMode          = 0;
    int  m_autoDimThreshold      = 100;   // lux
    int  m_timeFormat            = 0;
    bool m_gpsSync               = true;
    int  m_clockHour             = 12;
    int  m_clockMinute           = 0;
    int  m_timezoneOffset        = -5;    // EST default
    int  m_distanceUnit          = 0;
    int  m_tempUnit              = 0;
    int  m_fuelUnit              = 0;
    bool m_voiceGuidance         = true;
    int  m_voiceVolume           = 70;
    int  m_routePref             = 0;
    bool m_avoidTolls            = false;
    bool m_avoidHighways         = false;
    bool m_poiIconsOnMap         = true;
    bool m_clickSounds           = true;
    int  m_navPromptVolume       = 80;
    bool m_vdcEnabled            = true;
    int  m_lightShutoff          = 2;
    int  m_headlightSensitivity  = 1;
    bool m_drlEnabled            = true;
    bool m_approachLighting      = true;
    int  m_approachLightDuration = 1;
    bool m_welcomeLighting       = true;
    int  m_interiorLightTimer    = 1;
    int  m_autoLockSpeed         = 1;
    bool m_autoUnlockPark        = true;
    bool m_autoUnlockKeyRemoval  = false;
    bool m_fobLockAll            = true;
    bool m_mirrorTiltReverse     = true;
    bool m_mirrorFoldLock        = false;
    int  m_rainSensorSensitivity = 3;
    int  m_wiperDelay            = 3;
    bool m_seatMemoryOnUnlock    = true;
    bool m_powerWindowAutoOpen   = true;
    bool m_seatbeltReminder      = true;
    int  m_parkAssistChimeVolume = 2;
    int  m_mapOrientation        = 0;
    bool m_speedLimitDisplay     = true;
    int  m_mapDetailLevel        = 1;
    int  m_maintenanceInterval   = 1;
    int  m_language              = 0;
    QVariantList m_btDevices;             // seeded in ctor

    // System metadata (set in ctor, never mutates after)
    QString m_softwareVersion;
    QString m_mapDataVersion;
    QString m_buildDate;
    qint64  m_bootTime           = 0;     // QDateTime::currentMSecsSinceEpoch() at ctor

    QTimer        *m_saveTimer   = nullptr;
    QTimer        *m_uptimeTimer = nullptr;
    ProfileService *m_profileSvc = nullptr;
};
