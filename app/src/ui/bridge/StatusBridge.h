#pragma once
// StatusBridge — shared state between upper and lower screens
// Zero-copy signal relay: services emit → bridge re-emits to both QML windows
#include <QObject>
#include <QString>
#include <QTimer>

class NavigationService;
class VehicleService;
class AudioService;
class NetworkService;
class ParkingService;

class StatusBridge : public QObject {
    Q_OBJECT
    // Nav state (mirrored to lower screen)
    Q_PROPERTY(bool    navActive      READ navActive      NOTIFY navActiveChanged)
    Q_PROPERTY(QString nextStreet     READ nextStreet     NOTIFY navInstructionChanged)
    Q_PROPERTY(QString nextManeuver   READ nextManeuver   NOTIFY navInstructionChanged)
    Q_PROPERTY(double  nextDistance   READ nextDistance   NOTIFY navInstructionChanged)
    Q_PROPERTY(QString eta            READ eta            NOTIFY etaChanged)
    Q_PROPERTY(double  speed          READ speed          NOTIFY speedChanged)
    Q_PROPERTY(double  speedLimit     READ speedLimit     NOTIFY speedChanged)
    // Screen event flags
    Q_PROPERTY(bool    callActive     READ callActive     NOTIFY callActiveChanged)
    Q_PROPERTY(bool    reverseActive  READ reverseActive  NOTIFY reverseActiveChanged)
    Q_PROPERTY(bool    approachingTurn READ approachingTurn NOTIFY approachingTurnChanged)
    // Connectivity
    Q_PROPERTY(bool    gpsLock        READ gpsLock        NOTIFY gpsLockChanged)
    Q_PROPERTY(bool    btConnected    READ btConnected    NOTIFY btConnectedChanged)
    Q_PROPERTY(bool    sxmActive      READ sxmActive      NOTIFY sxmActiveChanged)
    Q_PROPERTY(double  outsideTemp    READ outsideTemp    NOTIFY outsideTempChanged)
    Q_PROPERTY(QString timeString     READ timeString     NOTIFY timeChanged)
    // GPS position (for map tracking)
    Q_PROPERTY(double  latitude       READ latitude       NOTIFY positionChanged)
    Q_PROPERTY(double  longitude      READ longitude      NOTIFY positionChanged)
    // LTE network
    Q_PROPERTY(bool    networkOnline  READ networkOnline  NOTIFY networkChanged)
    Q_PROPERTY(QString networkType    READ networkType    NOTIFY networkChanged)  // "LTE"/"3G"/"none"
    Q_PROPERTY(int     signalStrength READ signalStrength NOTIFY networkChanged)  // 0-5 bars
    // Around View Monitor (AVM) — upper screen camera composite overlay
    Q_PROPERTY(bool    avmActive      READ avmActive      NOTIFY avmActiveChanged)

public:
    explicit StatusBridge(NavigationService *nav,
                          VehicleService   *vehicle,
                          AudioService     *audio,
                          NetworkService   *network = nullptr,
                          ParkingService   *parking = nullptr,
                          QObject *parent = nullptr);

    bool   networkOnline()   const { return m_networkOnline; }
    QString networkType()    const { return m_networkType; }
    int    signalStrength()  const { return m_signalStrength; }

    bool   navActive()      const { return m_navActive; }
    QString nextStreet()    const { return m_nextStreet; }
    QString nextManeuver()  const { return m_nextManeuver; }
    double  nextDistance()  const { return m_nextDistance; }
    QString eta()           const { return m_eta; }
    double  speed()         const { return m_speed; }
    double  speedLimit()    const { return m_speedLimit; }
    bool   callActive()     const { return m_callActive; }
    bool   reverseActive()  const { return m_reverseActive; }
    bool   approachingTurn() const { return m_approachingTurn; }
    bool   gpsLock()        const { return m_gpsLock; }
    bool   btConnected()    const { return m_btConnected; }
    bool   sxmActive()      const { return m_sxmActive; }
    double outsideTemp()    const { return m_outsideTemp; }
    QString timeString()    const { return m_timeString; }
    double latitude()       const { return m_latitude; }
    double longitude()      const { return m_longitude; }
    bool   avmActive()      const { return m_avmActive; }

    // Setter for AVM activation — invokable from QML (corner badge, lower-screen
    // Vehicle tab button, or future CAN-driven gear=R + button-held trigger).
    Q_INVOKABLE void setAvmActive(bool active);

    // ── Phone call controls ──────────────────────────────────────────────
    // All BT HFP wiring is stubbed until BlueZ HFP profile lands (see
    // AudioService backlog). These invocables update local call/mute state
    // and emit the relevant signals so the PhoneView dial/end/mute/speaker
    // buttons have working UX. DTMF tones route through AudioService's
    // existing PCM path.
    Q_INVOKABLE void answerCall();   // accept incoming call (sets callActive=true)
    Q_INVOKABLE void endCall();      // terminate active call
    Q_INVOKABLE void toggleMute();   // mic mute toggle (forwards to AudioService)
    Q_INVOKABLE void toggleSpeaker();// route audio to handset/speaker
    Q_INVOKABLE void sendDtmf(const QString &digit);  // DTMF tone "0"-"9","*","#"
    Q_INVOKABLE void dial(const QString &number);     // initiate outgoing call (stub)
    Q_PROPERTY(bool muted    READ muted    NOTIFY muteChanged)
    Q_PROPERTY(bool speakerOn READ speakerOn NOTIFY speakerChanged)
    bool muted()    const { return m_muted; }
    bool speakerOn() const { return m_speakerOn; }

signals:
    void navActiveChanged(bool);
    void navInstructionChanged();
    void etaChanged(QString);
    void speedChanged();
    void callActiveChanged(bool);
    void reverseActiveChanged(bool);
    void approachingTurnChanged(bool);
    void gpsLockChanged(bool);
    void btConnectedChanged(bool);
    void sxmActiveChanged(bool);
    void outsideTempChanged(double);
    void timeChanged(QString);
    void positionChanged();
    void networkChanged();
    void avmActiveChanged(bool);
    void muteChanged(bool);
    void speakerChanged(bool);
    void dtmfSent(QString digit);
    void outgoingCallInitiated(QString number);

    // Cross-screen commands
    void showTurnBanner();      // Lower screen: flash turn arrow overlay
    void showAlertBanner(const QString &msg);
    void switchLowerToPhone();  // Auto-switch lower screen on call
    void restoreLowerScreen();  // Return to previous lower tab after call

private slots:
    void onClockTick();
    void onNavInstruction();
    void onSpeedUpdate(double speed);
    void onReverseEngaged(bool reverse);
    void onCallStarted();
    void onCallEnded();

private:
    NavigationService *m_nav;
    VehicleService    *m_vehicle;
    AudioService      *m_audio;
    NetworkService    *m_network;
    ParkingService    *m_parking;

    bool    m_networkOnline  = false;
    QString m_networkType    = QStringLiteral("none");
    int     m_signalStrength = 0;
    bool    m_muted          = false;
    bool    m_speakerOn      = false;

    bool    m_navActive = false;
    QString m_nextStreet;
    QString m_nextManeuver;
    double  m_nextDistance = 0.0;
    QString m_eta;
    double  m_speed = 0.0;
    double  m_speedLimit = 0.0;
    bool    m_callActive = false;
    bool    m_reverseActive = false;
    bool    m_approachingTurn = false;
    bool    m_gpsLock = false;
    bool    m_btConnected = false;
    bool    m_sxmActive = false;
    double  m_outsideTemp = 67.0;
    QString m_timeString;
    double  m_latitude  = 0.0;
    double  m_longitude = 0.0;
    bool    m_avmActive = false;

    QTimer *m_clockTimer;
    static constexpr double TURN_BANNER_MILES = 0.5;
};
