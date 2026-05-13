#pragma once
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QFile>
#include <QVariantMap>
#include <QVariantList>
#ifdef HAVE_QT_DBUS
#include <QDBusObjectPath>
#endif

class SettingsService;
class VehicleService;

class AudioService : public QObject {
    Q_OBJECT

    // ── Existing properties ────────────────────────────────────────────────
    Q_PROPERTY(AudioSource source    READ source    NOTIFY sourceChanged)
    Q_PROPERTY(int          volume   READ volume    NOTIFY volumeChanged)
    Q_PROPERTY(bool         muted    READ muted     NOTIFY mutedChanged)
    Q_PROPERTY(QString      trackTitle   READ trackTitle   NOTIFY metadataChanged)
    Q_PROPERTY(QString      trackArtist  READ trackArtist  NOTIFY metadataChanged)
    Q_PROPERTY(QString      trackAlbum   READ trackAlbum   NOTIFY metadataChanged)
    Q_PROPERTY(QString      fmStation    READ fmStation    NOTIFY fmChanged)
    Q_PROPERTY(double       fmFrequency  READ fmFrequency  NOTIFY fmChanged)
    Q_PROPERTY(QString      rdsText      READ rdsText      NOTIFY fmChanged)
    // RDS-decoded two-line display: station name (PS/RT0) + song title (RT segment).
    // Stub parser populates these from the radiofc.out IPC stream — see onFmProxyData().
    Q_PROPERTY(QString      fmStationName READ fmStationName NOTIFY fmChanged)
    Q_PROPERTY(QString      fmSongTitle   READ fmSongTitle   NOTIFY fmChanged)
    Q_PROPERTY(QString      sxmChannel   READ sxmChannel   NOTIFY sxmChanged)
    Q_PROPERTY(QString      sxmName      READ sxmName      NOTIFY sxmChanged)
    Q_PROPERTY(QString      sxmCategory  READ sxmCategory  NOTIFY sxmChanged)
    Q_PROPERTY(int          sxmSignal    READ sxmSignal    NOTIFY sxmChanged)

    // ── EQ & balance ──────────────────────────────────────────────────────
    Q_PROPERTY(int  bass     READ bass     NOTIFY eqChanged)   // -7 to +7
    Q_PROPERTY(int  treble   READ treble   NOTIFY eqChanged)   // -7 to +7
    Q_PROPERTY(int  balance  READ balance  NOTIFY eqChanged)   // -9 to +9 L/R
    Q_PROPERTY(int  fade     READ fade     NOTIFY eqChanged)   // -9 to +9 F/R

    // ── Bose DSP toggles ──────────────────────────────────────────────────
    Q_PROPERTY(bool audioPilotOn   READ audioPilotOn   NOTIFY boseChanged)
    Q_PROPERTY(bool centerpointOn  READ centerpointOn  NOTIFY boseChanged)
    Q_PROPERTY(bool surroundOn     READ surroundOn     NOTIFY boseChanged)
    Q_PROPERTY(bool driverStageOn  READ driverStageOn  NOTIFY boseChanged)

    // ── Speed-Sensitive Volume ─────────────────────────────────────────────
    Q_PROPERTY(int  ssvLevel READ ssvLevel NOTIFY ssvChanged)  // 0=off 1-5

    // ── FM/AM/SXM presets ─────────────────────────────────────────────────
    Q_PROPERTY(QVariantList fmPresets        READ fmPresets        NOTIFY presetsChanged)
    Q_PROPERTY(QVariantList amPresets        READ amPresets        NOTIFY presetsChanged)
    Q_PROPERTY(QVariantList sxmPresets       READ sxmPresets       NOTIFY presetsChanged)
    Q_PROPERTY(int          activePresetIndex READ activePresetIndex NOTIFY presetsChanged)

    // ── BT device ─────────────────────────────────────────────────────────
    Q_PROPERTY(QString btDeviceName  READ btDeviceName  NOTIFY btConnectionChanged)
    Q_PROPERTY(bool    btConnected   READ btConnected   NOTIFY btConnectionChanged)

public:
    enum AudioSource { Bluetooth, FM, AM, SXM, AUX, None };
    Q_ENUM(AudioSource)

    explicit AudioService(QObject *parent = nullptr);
    ~AudioService() override;
    void start();

    // Wire persistence + vehicle-speed consumer.  Both optional — pass nullptr
    // in unit tests or when running without those services constructed.
    // SettingsService: presets are loaded immediately and written back via the
    //                  service's debounced save path whenever they change.
    // VehicleService:  read-only — we subscribe to speedChanged for SSV gain.
    void wireDependencies(SettingsService *settings, VehicleService *vehicle);

    // Existing accessors
    AudioSource source()       const { return m_source; }
    int         volume()       const { return m_volume; }
    bool        muted()        const { return m_muted; }
    QString     trackTitle()   const { return m_trackTitle; }
    QString     trackArtist()  const { return m_trackArtist; }
    QString     trackAlbum()   const { return m_trackAlbum; }
    QString     fmStation()    const { return m_fmStation; }
    double      fmFrequency()  const { return m_fmFrequency; }
    QString     rdsText()      const { return m_rdsText; }
    QString     fmStationName() const { return m_fmStationName; }
    QString     fmSongTitle()   const { return m_fmSongTitle; }
    QString     sxmChannel()   const { return m_sxmChannel; }
    QString     sxmName()      const { return m_sxmName; }
    QString     sxmCategory()  const { return m_sxmCategory; }
    int         sxmSignal()    const { return m_sxmSignal; }

    // EQ accessors
    int  bass()    const { return m_bass; }
    int  treble()  const { return m_treble; }
    int  balance() const { return m_balance; }
    int  fade()    const { return m_fade; }

    // Bose accessors
    bool audioPilotOn()  const { return m_audioPilotOn; }
    bool centerpointOn() const { return m_centerpointOn; }
    bool surroundOn()    const { return m_surroundOn; }
    bool driverStageOn() const { return m_driverStageOn; }

    // SSV accessor
    int ssvLevel() const { return m_ssvLevel; }

    // Preset accessors
    QVariantList fmPresets()         const { return m_fmPresets; }
    QVariantList amPresets()         const { return m_amPresets; }
    QVariantList sxmPresets()        const { return m_sxmPresets; }
    int          activePresetIndex() const { return m_activePresetIndex; }

    // BT device accessors
    QString btDeviceName() const { return m_btDeviceName; }
    bool    btConnected()  const { return m_btConnected; }

public slots:
    // Existing slots
    void setSource(AudioSource src);
    void setVolume(int vol);          // 0–100
    void setMuted(bool muted);
    void setFMFrequency(double mhz);
    void seekFM(bool forward);
    void setSXMChannel(int ch);
    void btPlay();
    void btPause();
    void btNext();
    void btPrev();
    void wakeBosse();                 // Emits bossWakeRequested → VehicleService

    // EQ slots
    void setBass(int v);              // clamped -7 to +7
    void setTreble(int v);            // clamped -7 to +7
    void setBalance(int v);           // clamped -9 to +9
    void setFade(int v);              // clamped -9 to +9

    // Bose DSP slots
    void setAudioPilot(bool on);
    void setCenterpoint(bool on);
    void setSurround(bool on);
    void setDriverStage(bool on);

    // SSV slot
    void setSSVLevel(int level);      // clamped 0-5

    // Preset slots
    void savePreset(int slot);        // save current freq to slot 0-5
    void recallPreset(int slot);      // set freq from slot 0-5

signals:
    void sourceChanged(AudioSource);
    void volumeChanged(int);
    void mutedChanged(bool);
    void metadataChanged();
    void fmChanged();
    void sxmChanged();
    void eqChanged();
    void boseChanged();
    void ssvChanged();
    void presetsChanged();
    void bossWakeRequested();         // Wired to VehicleService::wakeBosse in main.cpp
    void btConnectionChanged(bool connected);

private slots:
    void onSxmProxyData();
    void onFmProxyData();
    void onBluetoothMetadata(const QString &title, const QString &artist);
    void onBluetoothProperties(const QString &iface, const QVariantMap &props,
                                const QStringList &invalidated);
    void onVehicleSpeedChanged(float kph);

private:
    void blueZMediaCmd(const QString &method);
    void sendProxyCommand(const QString &daemon, const QString &cmd);
    void initPresets();
    void loadPresetsFromSettings();
    void writePresetsToSettings();
    void applySpeedGain();
    void parseRdsLine(const QString &line);
    static QVariantMap makePreset(double freq, const QString &name);

    // DENSO proxy daemons
    QProcess m_sxmProxy;
    QProcess m_fmProxy;

    // BlueZ D-Bus (optional — requires HAVE_QT_DBUS)
#ifdef HAVE_QT_DBUS
    class QDBusInterface *m_btMediaPlayer = nullptr;
    QString m_btPlayerPath;
#endif

    // Existing state
    AudioSource m_source = Bluetooth;
    int    m_volume = 50;
    bool   m_muted = false;
    QString m_trackTitle;
    QString m_trackArtist;
    QString m_trackAlbum;
    QString m_fmStation;
    double  m_fmFrequency = 96.1;
    QString m_rdsText;
    QString m_fmStationName;   // RDS PS (program service name)
    QString m_fmSongTitle;     // RDS RT segment (song / now-playing)
    QString m_sxmChannel;
    QString m_sxmName;
    QString m_sxmCategory;
    int     m_sxmSignal = 0;

    // EQ state
    int m_bass    = 0;
    int m_treble  = 0;
    int m_balance = 0;
    int m_fade    = 0;

    // Bose state
    bool m_audioPilotOn  = true;
    bool m_centerpointOn = false;
    bool m_surroundOn    = false;
    bool m_driverStageOn = false;

    // SSV state
    int m_ssvLevel = 0;

    // Preset state
    QVariantList m_fmPresets;
    QVariantList m_amPresets;
    QVariantList m_sxmPresets;
    int m_activePresetIndex = -1;

    // BT device state
    QString m_btDeviceName;
    bool    m_btConnected = false;

    // External services (non-owning) wired via wireDependencies().
    SettingsService *m_settings = nullptr;
    VehicleService  *m_vehicle  = nullptr;

    // Last-known vehicle speed (kph) — drives SSV gain calc
    float m_speedKph = 0.0f;

    // Suppress preset write-back while we're loading from settings
    bool m_loadingPresets = false;
};
