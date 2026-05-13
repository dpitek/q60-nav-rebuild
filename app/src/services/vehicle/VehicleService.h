#pragma once
#include <QObject>
#include <QTimer>
#include <QSocketNotifier>
#include <linux/can.h>
#include <linux/can/raw.h>
#include "ButtonLogger.h"

class VehicleService : public QObject {
    Q_OBJECT
    // Climate
    Q_PROPERTY(float driverTemp    READ driverTemp    NOTIFY driverTempChanged)
    Q_PROPERTY(float passengerTemp READ passengerTemp NOTIFY passengerTempChanged)
    Q_PROPERTY(int   fanSpeed      READ fanSpeed      NOTIFY fanSpeedChanged)
    Q_PROPERTY(bool  acOn          READ acOn          NOTIFY acOnChanged)
    Q_PROPERTY(bool  recircOn      READ recircOn      NOTIFY recircOnChanged)
    Q_PROPERTY(int   climateMode   READ climateMode   NOTIFY climateModeChanged)
    Q_PROPERTY(int   driverSeat    READ driverSeat    NOTIFY driverSeatChanged)
    Q_PROPERTY(int   passSeat      READ passSeat      NOTIFY passSeatChanged)
    // Vehicle dynamics
    Q_PROPERTY(float speed         READ speed         NOTIFY speedChanged)
    Q_PROPERTY(float speedLimit    READ speedLimit    NOTIFY speedLimitChanged)
    Q_PROPERTY(int   gear          READ gear          NOTIFY gearChanged)
    Q_PROPERTY(bool  reverse       READ reverse       NOTIFY reverseChanged)
    Q_PROPERTY(int   rpm           READ rpm           NOTIFY rpmChanged)
    Q_PROPERTY(float steerAngle    READ steerAngle    NOTIFY steerAngleChanged)
    Q_PROPERTY(bool  brakePressed  READ brakePressed  NOTIFY brakePressedChanged)
    // Body / environment
    Q_PROPERTY(float outsideTemp   READ outsideTemp   NOTIFY outsideTempChanged)
    Q_PROPERTY(int   headlights    READ headlights    NOTIFY headlightsChanged)
    Q_PROPERTY(bool  leftTurn      READ leftTurn      NOTIFY leftTurnChanged)
    Q_PROPERTY(bool  rightTurn     READ rightTurn     NOTIFY rightTurnChanged)
    Q_PROPERTY(bool  parkingBrake  READ parkingBrake  NOTIFY parkingBrakeChanged)
    // Ignition / power state (0x292)
    Q_PROPERTY(bool  ignitionOn    READ ignitionOn    NOTIFY ignitionOnChanged)
    // Doors / trunk (0x358)
    Q_PROPERTY(bool  doorDriver    READ doorDriver    NOTIFY doorDriverChanged)
    Q_PROPERTY(bool  doorPassenger READ doorPassenger NOTIFY doorPassengerChanged)
    Q_PROPERTY(bool  doorRearLeft  READ doorRearLeft  NOTIFY doorRearLeftChanged)
    Q_PROPERTY(bool  doorRearRight READ doorRearRight NOTIFY doorRearRightChanged)
    Q_PROPERTY(bool  trunkOpen     READ trunkOpen     NOTIFY trunkOpenChanged)
    // Powertrain / climate extended (0x551 + 0x625)
    Q_PROPERTY(float coolantTemp   READ coolantTemp   NOTIFY coolantTempChanged)
    Q_PROPERTY(float batteryVolts  READ batteryVolts  NOTIFY batteryVoltsChanged)
    Q_PROPERTY(bool  rearDefrostOn READ rearDefrostOn NOTIFY rearDefrostOnChanged)
    // Cruise control (0x551)
    Q_PROPERTY(bool  cruiseActive  READ cruiseActive  NOTIFY cruiseActiveChanged)
    Q_PROPERTY(float cruiseSpeed   READ cruiseSpeed   NOTIFY cruiseSpeedChanged)
    // Wipers (0x35D / 0x625)
    Q_PROPERTY(int   wipersState   READ wipersState   NOTIFY wipersStateChanged)
    // Climate shortcuts + steering wheel + plasmacluster + rain sensor
    Q_PROPERTY(bool  autoClimateOn        READ autoClimateOn        NOTIFY autoClimateOnChanged)
    Q_PROPERTY(bool  heatedSteeringWheel  READ heatedSteeringWheel  NOTIFY heatedSteeringWheelChanged)
    Q_PROPERTY(int   plasmaclusterLevel   READ plasmaclusterLevel   NOTIFY plasmaclusterLevelChanged)  // 0=off 1=low 2=mid 3=high
    Q_PROPERTY(bool  rainSensorEnabled    READ rainSensorEnabled    NOTIFY rainSensorEnabledChanged)
    // TPMS — individual tire PSI (0x385 Q50_LIKELY)
    Q_PROPERTY(float tirePSI_FL  READ tirePSI_FL  NOTIFY tirePSIsChanged)
    Q_PROPERTY(float tirePSI_FR  READ tirePSI_FR  NOTIFY tirePSIsChanged)
    Q_PROPERTY(float tirePSI_RL  READ tirePSI_RL  NOTIFY tirePSIsChanged)
    Q_PROPERTY(float tirePSI_RR  READ tirePSI_RR  NOTIFY tirePSIsChanged)
    // Oil life 0.0–100.0 (OBD2 PID 0x2F or proprietary Nissan CAN 0x54C Q50_LIKELY)
    Q_PROPERTY(float oilLife     READ oilLife     NOTIFY oilLifeChanged)
    // Fuel economy (OBD2 calculated or CAN 0x554 Q50_LIKELY)
    Q_PROPERTY(float instantMPG  READ instantMPG  NOTIFY instantMPGChanged)
    Q_PROPERTY(float avgMPG      READ avgMPG      NOTIFY avgMPGChanged)
    // Trip computers A and B
    Q_PROPERTY(float tripAMiles    READ tripAMiles    NOTIFY tripAChanged)
    Q_PROPERTY(float tripAAvgMPG   READ tripAAvgMPG   NOTIFY tripAChanged)
    Q_PROPERTY(int   tripASeconds  READ tripASeconds  NOTIFY tripAChanged)
    Q_PROPERTY(float tripAAvgSpeed READ tripAAvgSpeed NOTIFY tripAChanged)
    Q_PROPERTY(float tripBMiles    READ tripBMiles    NOTIFY tripBChanged)
    Q_PROPERTY(float tripBAvgMPG   READ tripBAvgMPG   NOTIFY tripBChanged)
    Q_PROPERTY(int   tripBSeconds  READ tripBSeconds  NOTIFY tripBChanged)
    Q_PROPERTY(float tripBAvgSpeed READ tripBAvgSpeed NOTIFY tripBChanged)
    // Drive mode (0=Std 1=Sport 2=Sport+ 3=Eco 4=Snow 5=Personal 6=Track)
    Q_PROPERTY(int  driveMode      READ driveMode      NOTIFY driveModeChanged)
    // Active Sound Control (Bose-synthesized engine sound through speakers)
    // Default true to match factory state. Toggle exposed in AudioView Settings panel.
    Q_PROPERTY(bool ascEnabled     READ ascEnabled     NOTIFY ascEnabledChanged)
    // Track mode active (driveMode == 6) — composite "cool" mode
    Q_PROPERTY(bool trackModeActive READ trackModeActive NOTIFY trackModeActiveChanged)
    // Commander joystick + adjacent buttons
    Q_PROPERTY(int joystickX READ joystickX NOTIFY joystickMoved)
    Q_PROPERTY(int joystickY READ joystickY NOTIFY joystickMoved)
    Q_PROPERTY(bool joystickPressed READ joystickPressed NOTIFY joystickClicked)
    Q_PROPERTY(QString lastButtonPress READ lastButtonPress NOTIFY buttonPressed)
    // Driver aids
    Q_PROPERTY(bool bswOn          READ bswOn          NOTIFY bswOnChanged)
    Q_PROPERTY(bool bsiOn          READ bsiOn          NOTIFY bsiOnChanged)
    Q_PROPERTY(bool ldwOn          READ ldwOn          NOTIFY ldwOnChanged)
    Q_PROPERTY(bool ldpOn          READ ldpOn          NOTIFY ldpOnChanged)
    Q_PROPERTY(bool febOn          READ febOn          NOTIFY febOnChanged)
    Q_PROPERTY(bool bciOn          READ bciOn          NOTIFY bciOnChanged)
    Q_PROPERTY(bool vdcOn          READ vdcOn          NOTIFY vdcOnChanged)
    Q_PROPERTY(int  pfcwSensitivity READ pfcwSensitivity NOTIFY pfcwSensitivityChanged)  // 0=Off 1=Far 2=Normal 3=Near
    // ATTESA AWD torque split
    Q_PROPERTY(float atessaFront   READ atessaFront    NOTIFY atessaChanged)  // % front torque 0-100
    Q_PROPERTY(float atessaRear    READ atessaRear     NOTIFY atessaChanged)  // % rear torque 0-100

    // ── VR30DDTT track telemetry (Q60 3.0L twin-turbo) ──────────────────────
    // Most read paths Q50_LIKELY or UNVERIFIED — see VR30 EcuTek tuning guide.
    Q_PROPERTY(double boostPressurePsi   READ boostPressurePsi   NOTIFY vr30TelemetryChanged)  // 0x551 byte 4-5 Q50_LIKELY
    Q_PROPERTY(double oilTempF           READ oilTempF           NOTIFY vr30TelemetryChanged)  // 0x55D Q50_LIKELY
    Q_PROPERTY(double transTempF         READ transTempF         NOTIFY vr30TelemetryChanged)  // 0x59A Q50_LIKELY
    Q_PROPERTY(double intakeAirTempF     READ intakeAirTempF     NOTIFY vr30TelemetryChanged)  // 0x551 byte 7 Q50_LIKELY
    Q_PROPERTY(double ignitionAdvanceDeg READ ignitionAdvanceDeg NOTIFY vr30TelemetryChanged)  // UNVERIFIED
    Q_PROPERTY(double knockRetardDeg     READ knockRetardDeg     NOTIFY vr30TelemetryChanged)  // UNVERIFIED
    Q_PROPERTY(double wastegatePercent   READ wastegatePercent   NOTIFY vr30TelemetryChanged)  // 0x55C Q50_LIKELY
    Q_PROPERTY(double manifoldPressurePsi READ manifoldPressurePsi NOTIFY vr30TelemetryChanged)  // OBD2 PID 0x0B (calc)
    Q_PROPERTY(double airFuelRatio       READ airFuelRatio       NOTIFY vr30TelemetryChanged)  // calc from MAF

    // ── G-meter (chassis sensor — frame ID UNVERIFIED) ──────────────────────
    Q_PROPERTY(double lateralG           READ lateralG           NOTIFY gMeterChanged)
    Q_PROPERTY(double longitudinalG      READ longitudinalG      NOTIFY gMeterChanged)
    Q_PROPERTY(double peakLateralG       READ peakLateralG       NOTIFY gMeterChanged)
    Q_PROPERTY(double peakLongitudinalG  READ peakLongitudinalG  NOTIFY gMeterChanged)

    // ── Performance timer (0-60 / quarter-mile) ────────────────────────────
    Q_PROPERTY(double zeroToSixtySec     READ zeroToSixtySec     NOTIFY perfTimerChanged)
    Q_PROPERTY(double quarterMileSec     READ quarterMileSec     NOTIFY perfTimerChanged)
    Q_PROPERTY(double quarterMileTrapMph READ quarterMileTrapMph NOTIFY perfTimerChanged)
    Q_PROPERTY(bool   perfRunActive      READ perfRunActive      NOTIFY perfTimerChanged)
    Q_PROPERTY(double perfRunElapsedSec  READ perfRunElapsedSec  NOTIFY perfTimerChanged)

public:
    explicit VehicleService(QObject *parent = nullptr);
    ~VehicleService();
    void start();

    // Climate
    float driverTemp()    const { return m_driverTemp; }
    float passengerTemp() const { return m_passengerTemp; }
    int   fanSpeed()      const { return m_fanSpeed; }
    bool  acOn()          const { return m_acOn; }
    bool  recircOn()      const { return m_recircOn; }
    int   climateMode()   const { return m_climateMode; }
    int   driverSeat()    const { return m_driverSeat; }
    int   passSeat()      const { return m_passSeat; }
    // Dynamics
    float speed()         const { return m_speed; }
    float speedLimit()    const { return m_speedLimit; }
    int   gear()          const { return m_gear; }
    bool  reverse()       const { return m_reverse; }
    int   rpm()           const { return m_rpm; }
    float steerAngle()    const { return m_steerAngle; }
    bool  brakePressed()  const { return m_brakePressed; }
    // Body
    float outsideTemp()   const { return m_outsideTemp; }
    int   headlights()    const { return m_headlights; }
    bool  leftTurn()      const { return m_leftTurn; }
    bool  rightTurn()     const { return m_rightTurn; }
    bool  parkingBrake()  const { return m_parkingBrake; }
    // Ignition / power
    bool  ignitionOn()    const { return m_ignitionOn; }
    // Doors / trunk
    bool  doorDriver()    const { return m_doorDriver; }
    bool  doorPassenger() const { return m_doorPassenger; }
    bool  doorRearLeft()  const { return m_doorRearLeft; }
    bool  doorRearRight() const { return m_doorRearRight; }
    bool  trunkOpen()     const { return m_trunkOpen; }
    // Powertrain extended
    float coolantTemp()   const { return m_coolantTemp; }
    float batteryVolts()  const { return m_batteryVolts; }
    bool  rearDefrostOn() const { return m_rearDefrostOn; }
    // Cruise
    bool  cruiseActive()  const { return m_cruiseActive; }
    float cruiseSpeed()   const { return m_cruiseSpeed; }
    // Wipers (0=off, 1=slow, 2=fast, 3=one-shot)
    int   wipersState()   const { return m_wipersState; }
    // Climate shortcuts
    bool autoClimateOn()       const { return m_autoClimateOn; }
    bool heatedSteeringWheel() const { return m_heatedSteeringWheel; }
    int  plasmaclusterLevel()  const { return m_plasmaclusterLevel; }
    bool rainSensorEnabled()   const { return m_rainSensorEnabled; }
    // TPMS
    float tirePSI_FL()    const { return m_tirePSI_FL; }
    float tirePSI_FR()    const { return m_tirePSI_FR; }
    float tirePSI_RL()    const { return m_tirePSI_RL; }
    float tirePSI_RR()    const { return m_tirePSI_RR; }
    // Oil / fuel economy
    float oilLife()       const { return m_oilLife; }
    float instantMPG()    const { return m_instantMPG; }
    float avgMPG()        const { return m_avgMPG; }
    // Trip A
    float tripAMiles()    const { return m_tripAMiles; }
    float tripAAvgMPG()   const { return m_tripAAvgMPG; }
    int   tripASeconds()  const { return m_tripASeconds; }
    float tripAAvgSpeed() const { return m_tripAAvgSpeed; }
    // Trip B
    float tripBMiles()    const { return m_tripBMiles; }
    float tripBAvgMPG()   const { return m_tripBAvgMPG; }
    int   tripBSeconds()  const { return m_tripBSeconds; }
    float tripBAvgSpeed() const { return m_tripBAvgSpeed; }
    // Drive mode
    int  driveMode()      const { return m_driveMode; }
    bool ascEnabled()      const { return m_ascEnabled; }
    bool trackModeActive() const { return m_driveMode == 6; }
    // Commander joystick + adjacent buttons
    int joystickX() const { return m_joystickX; }
    int joystickY() const { return m_joystickY; }
    bool joystickPressed() const { return m_joystickPressed; }
    QString lastButtonPress() const { return m_lastButtonPress; }
    // Driver aids
    bool bswOn()          const { return m_bswOn; }
    bool bsiOn()          const { return m_bsiOn; }
    bool ldwOn()          const { return m_ldwOn; }
    bool ldpOn()          const { return m_ldpOn; }
    bool febOn()          const { return m_febOn; }
    bool bciOn()          const { return m_bciOn; }
    bool vdcOn()          const { return m_vdcOn; }
    int  pfcwSensitivity() const { return m_pfcwSensitivity; }
    // ATTESA
    float atessaFront()   const { return m_atessaFront; }
    float atessaRear()    const { return m_atessaRear; }
    // VR30 track telemetry
    double boostPressurePsi()    const { return m_boostPressurePsi; }
    double oilTempF()            const { return m_oilTempF; }
    double transTempF()          const { return m_transTempF; }
    double intakeAirTempF()      const { return m_intakeAirTempF; }
    double ignitionAdvanceDeg()  const { return m_ignitionAdvanceDeg; }
    double knockRetardDeg()      const { return m_knockRetardDeg; }
    double wastegatePercent()    const { return m_wastegatePercent; }
    double manifoldPressurePsi() const { return m_manifoldPressurePsi; }
    double airFuelRatio()        const { return m_airFuelRatio; }
    // G-meter
    double lateralG()            const { return m_lateralG; }
    double longitudinalG()       const { return m_longitudinalG; }
    double peakLateralG()        const { return m_peakLateralG; }
    double peakLongitudinalG()   const { return m_peakLongitudinalG; }
    // Performance timer
    double zeroToSixtySec()      const { return m_zeroToSixtySec; }
    double quarterMileSec()      const { return m_quarterMileSec; }
    double quarterMileTrapMph()  const { return m_quarterMileTrapMph; }
    bool   perfRunActive()       const { return m_perfRunActive; }
    double perfRunElapsedSec()   const { return m_perfRunElapsedSec; }

public slots:
    // Climate writes — CAUTION: Q50/Q60 HVAC write path not publicly documented.
    // These functions update local state and attempt writes on CAN_HVAC_CTRL.
    // DO NOT rely on car responding until write IDs are verified via J2534 capture.
    void setDriverTemp(float temp);
    void setPassengerTemp(float temp);
    void setFanSpeed(int level);        // 0–7
    void setAcOn(bool on);
    void setRecircOn(bool on);
    void setClimateMode(int mode);      // 0=face 1=feet 2=blend 3=defrost
    void setDriverSeatHeat(int level);  // 0–3
    void setPassSeatHeat(int level);
    void setRearDefrost(bool on);
    // Bose wake
    void wakeBosse();
    // Climate shortcuts + steering wheel + plasmacluster + rain sensor
    Q_INVOKABLE void setAutoClimate(bool on);    // AUTO mode: full-auto fan+AC+mode
    Q_INVOKABLE void setMaxAC();                 // MAX AC: recirc + max fan + max cool
    Q_INVOKABLE void setMaxDefrost();            // MAX DEF: A/C + max fan + defrost mode
    Q_INVOKABLE void syncZones();                // SYNC: set passenger = driver temp
    Q_INVOKABLE void setHeatedSteeringWheel(bool on);
    Q_INVOKABLE void setPlasmacluster(int level);  // 0=off 1-3=level
    Q_INVOKABLE void setRainSensor(bool on);
    // Trip computer resets
    Q_INVOKABLE void resetTripA();
    Q_INVOKABLE void resetTripB();
    // Drive mode
    Q_INVOKABLE void setDriveMode(int mode);
    // Active Sound Control toggle — hidden in factory diag menu; we expose directly.
    // CAN write blocked until J2534 capture identifies the real ID (CAN_ASC_TOGGLE=0xFFFF).
    Q_INVOKABLE void setAscEnabled(bool on);
    // Track mode preference JSON blob — same pattern as audioPresets/driveModePersonalConfig.
    // Updates internal m_trackModePreferences struct and emits signals.
    Q_INVOKABLE void setTrackModeConfig(const QString &json);
    // Driver aids
    Q_INVOKABLE void setBSW(bool on);
    Q_INVOKABLE void setBSI(bool on);
    Q_INVOKABLE void setLDW(bool on);
    Q_INVOKABLE void setLDP(bool on);
    Q_INVOKABLE void setFEB(bool on);
    Q_INVOKABLE void setBCI(bool on);
    Q_INVOKABLE void setVDC(bool on);
    Q_INVOKABLE void setPFCWSensitivity(int level);  // 0=Off 1=Far 2=Normal 3=Near
    // Door lock/unlock via UDS Service 0x30 on BCM (0x745)
    // CAUTION: Data identifier 0xBF00 is Q50_LIKELY — verify via J2534 before use.
    // Single-frame UDS request; BCM must be on the active CAN bus (can0 HS-CAN).
    Q_INVOKABLE void lockDoors();
    Q_INVOKABLE void unlockDoors();
    // Performance timer
    Q_INVOKABLE void resetPerformanceTimer();

signals:
    void driverTempChanged(float);
    void passengerTempChanged(float);
    void fanSpeedChanged(int);
    void acOnChanged(bool);
    void recircOnChanged(bool);
    void climateModeChanged(int);
    void driverSeatChanged(int);
    void passSeatChanged(int);
    void speedChanged(float);
    void speedLimitChanged(float);
    void gearChanged(int);
    void reverseChanged(bool);
    void rpmChanged(int);
    void steerAngleChanged(float);
    void brakePressedChanged(bool);
    void outsideTempChanged(float);
    void headlightsChanged(int);
    void leftTurnChanged(bool);
    void rightTurnChanged(bool);
    void parkingBrakeChanged(bool);
    void ignitionOnChanged(bool);
    void doorDriverChanged(bool);
    void doorPassengerChanged(bool);
    void doorRearLeftChanged(bool);
    void doorRearRightChanged(bool);
    void trunkOpenChanged(bool);
    void coolantTempChanged(float);
    void batteryVoltsChanged(float);
    void rearDefrostOnChanged(bool);
    void cruiseActiveChanged(bool);
    void cruiseSpeedChanged(float);
    void wipersStateChanged(int);
    // Climate shortcuts
    void autoClimateOnChanged(bool);
    void heatedSteeringWheelChanged(bool);
    void plasmaclusterLevelChanged(int);
    void rainSensorEnabledChanged(bool);
    // TPMS / oil / fuel
    void tirePSIsChanged();
    void oilLifeChanged(float);
    void instantMPGChanged(float);
    void avgMPGChanged(float);
    // Trip computers
    void tripAChanged();
    void tripBChanged();
    // Drive mode + driver aids + ATTESA
    void driveModeChanged(int);
    void ascEnabledChanged(bool);
    void trackModeActiveChanged(bool);
    void trackModeConfigChanged();   // m_trackModePreferences struct updated
    void bswOnChanged(bool);
    void bsiOnChanged(bool);
    void ldwOnChanged(bool);
    void ldpOnChanged(bool);
    void febOnChanged(bool);
    void bciOnChanged(bool);
    void vdcOnChanged(bool);
    void pfcwSensitivityChanged(int);
    void atessaChanged();
    // Commander joystick signals
    void joystickMoved(int x, int y);   // x: -1/0/+1, y: -1/0/+1
    void joystickClicked();
    void buttonPressed(const QString &button);  // "back", "home", "map"
    void driveModeConfirmed(int mode);  // CAN status read-back confirmed the mode
    // Intelligent Key slot detected (CAN_KEY_DETECT 0x35B — UNVERIFIED)
    // Slot: 1 = key fob 1, 2 = key fob 2
    void keySlotDetected(int slot);
    // Steering wheel button events (fired from AV-CAN 0x681)
    void volUp();
    void volDown();
    void seekFwd();
    void seekBack();
    void answerCall();
    void endCall();
    void voiceActivate();
    void muteToggle();
    // Ignition / session lifecycle
    void ignitionOff();     // fired when ignition-off detected (speed=0 + gear=P + key event)
    // VR30 telemetry + G-meter + performance timer
    void vr30TelemetryChanged();
    void gMeterChanged();
    void perfTimerChanged();

private slots:
    void onVehicleCanData();
    void onAVCanData();
    void onCAN2Data();
    void onTripTimerTick();  // 1Hz trip computer accumulator
    void onPerfTick();        // ~10Hz performance timer state machine

private:
    void openCAN(const char *iface, int &sock);
    void parseVehicleFrame(const struct can_frame &f);
    void parseAVFrame(const struct can_frame &f);
    void parseCAN2Frame(const struct can_frame &f);
    void sendCANFrame(int sock, canid_t id, const uint8_t *data, uint8_t len);
    void hvacInit();           // send 0x540 init sequence on startup
    uint8_t hvacTempRaw(float tempF) const;  // °F → 0x540 byte encoding
    uint8_t hvacModeFlags() const;           // pack current state → byte 0 of 0x540
    void sendADASFrame();     // rebuild and send CAN_ADAS_CTRL (0x47D) from current aid state
    // VR30 telemetry: parses Q50_LIKELY frames; UNVERIFIED frames log TODO.
    void handleVR30Frame(const struct can_frame &f);
    // Performance timer state machine — drives 0-60, quarter mile, peak G tracking.
    void updatePerformanceTimer();

    ButtonLogger m_buttonLog;        // hardware button diagnostic logger
    bool m_ignitionOffSent = false;  // debounce: only emit ignitionOff() once per cycle
    QTimer *m_tripTimer    = nullptr; // 1Hz tick for trip computer accumulators

    int m_vehicleCanSock = -1;  // can0 — HS-CAN 500kbps (powertrain, BCM, HVAC)
    int m_avCanSock      = -1;  // can1 — AV-CAN 500kbps isolated (Bose, SXM, SW buttons)
    int m_can2Sock       = -1;  // can2 — TBD (may be MS-CAN 125kbps body bus)
    QSocketNotifier *m_vehicleNotifier = nullptr;
    QSocketNotifier *m_avNotifier      = nullptr;
    QSocketNotifier *m_can2Notifier    = nullptr;

    // State
    float m_driverTemp    = 72.0f;
    float m_passengerTemp = 70.0f;
    int   m_fanSpeed      = 4;
    bool  m_acOn          = true;
    bool  m_recircOn      = false;
    int   m_climateMode   = 0;
    int   m_driverSeat    = 0;
    int   m_passSeat      = 0;
    float m_speed         = 0.0f;
    float m_speedLimit    = 0.0f;
    int   m_gear          = 0;
    bool  m_reverse       = false;
    int   m_rpm           = 0;
    float m_steerAngle    = 0.0f;
    bool  m_brakePressed  = false;
    float m_outsideTemp   = 67.0f;
    int   m_headlights    = 0;
    bool  m_leftTurn      = false;
    bool  m_rightTurn     = false;
    bool  m_parkingBrake  = false;
    bool  m_ignitionOn    = false;
    bool  m_doorDriver    = false;
    bool  m_doorPassenger = false;
    bool  m_doorRearLeft  = false;
    bool  m_doorRearRight = false;
    bool  m_trunkOpen     = false;
    float m_coolantTemp   = 0.0f;
    float m_batteryVolts  = 0.0f;
    bool  m_rearDefrostOn = false;
    bool  m_cruiseActive  = false;
    float m_cruiseSpeed   = 0.0f;
    int   m_wipersState   = 0;
    // Climate shortcuts
    bool m_autoClimateOn       = false;
    bool m_heatedSteeringWheel = false;
    int  m_plasmaclusterLevel  = 0;
    bool m_rainSensorEnabled   = true;
    // TPMS
    float m_tirePSI_FL = 0.0f, m_tirePSI_FR = 0.0f, m_tirePSI_RL = 0.0f, m_tirePSI_RR = 0.0f;
    // Oil / fuel economy
    float m_oilLife     = 100.0f;
    float m_instantMPG  = 0.0f, m_avgMPG = 0.0f;
    // Trip A
    float m_tripAMiles    = 0.0f, m_tripAAvgMPG = 0.0f, m_tripAAvgSpeed = 0.0f;
    int   m_tripASeconds  = 0;
    // Trip B
    float m_tripBMiles    = 0.0f, m_tripBAvgMPG = 0.0f, m_tripBAvgSpeed = 0.0f;
    int   m_tripBSeconds  = 0;
    // Commander joystick state
    int m_joystickX = 0;
    int m_joystickY = 0;
    bool m_joystickPressed = false;
    QString m_lastButtonPress;
    // Drive mode + driver aids
    int  m_driveMode      = 0;
    bool m_bswOn          = true;
    bool m_bsiOn          = true;
    bool m_ldwOn          = true;
    bool m_ldpOn          = true;
    bool m_febOn          = true;
    bool m_bciOn          = true;
    bool m_vdcOn          = true;
    int  m_pfcwSensitivity = 2;
    // ATTESA (rear-biased default)
    float m_atessaFront   = 50.0f;
    float m_atessaRear    = 50.0f;

    // ── VR30 telemetry state ────────────────────────────────────────────────
    double m_boostPressurePsi    = 0.0;
    double m_oilTempF            = 0.0;
    double m_transTempF          = 0.0;
    double m_intakeAirTempF      = 0.0;
    double m_ignitionAdvanceDeg  = 0.0;
    double m_knockRetardDeg      = 0.0;
    double m_wastegatePercent    = 0.0;
    double m_manifoldPressurePsi = 0.0;
    double m_airFuelRatio        = 0.0;
    // Throttle 0-100% — derived from existing 0x551 cruise/coolant byte if available
    // (used by performance timer start detection). Currently a stub.
    double m_throttlePct         = 0.0;

    // ── G-meter state ───────────────────────────────────────────────────────
    double m_lateralG            = 0.0;
    double m_longitudinalG       = 0.0;
    double m_peakLateralG        = 0.0;
    double m_peakLongitudinalG   = 0.0;

    // ── Performance timer state ─────────────────────────────────────────────
    QTimer *m_perfTimer          = nullptr;
    bool   m_perfRunActive       = false;
    bool   m_perfRunArmed        = false;
    qint64 m_perfRunStartMs      = 0;
    double m_perfRunElapsedSec   = 0.0;
    double m_perfRunDistanceMi   = 0.0;
    double m_zeroToSixtySec      = 0.0;
    double m_quarterMileSec      = 0.0;
    double m_quarterMileTrapMph  = 0.0;

    // ── Active Sound Control (factory diag-menu hidden toggle) ────────────
    bool m_ascEnabled            = true;
    bool m_ascStateBeforeTrack   = true;

    // ── Track mode composite preferences (mode 6) ─────────────────────────
    // Only CAN write is 0x2DC (Sport+ encoding); rest is internal state + signals.
    enum class TrackThrottle  { Stock, Sport, Max };
    enum class TrackAtessa    { Auto, RwdPref, RwdOnly };
    enum class TrackAudioProf { Stock, Sport, Dry };
    struct TrackModePreferences {
        TrackThrottle  throttleMap   = TrackThrottle::Max;
        TrackAtessa    atessaBias    = TrackAtessa::RwdPref;
        bool           ascOff        = true;
        TrackAudioProf audioProfile  = TrackAudioProf::Dry;
        QString        gaugesSubTab  = QStringLiteral("track");
    };
    TrackModePreferences m_trackModePreferences;

    // ── VR30 / chassis CAN IDs (Q50_LIKELY / UNVERIFIED) ────────────────────
    // 0x551 carries cruise/coolant AND turbo data:
    //   byte 4-5: boost raw (big-endian uint16, kPa absolute) → psi = (raw*0.01)-14.504
    //   byte 7:   IAT raw, 0.75°C/LSB offset -48°C
    static constexpr canid_t CAN_VR30_BOOST_IAT  = 0x551;  // Q50_LIKELY (shared)
    static constexpr canid_t CAN_VR30_OIL_TEMP   = 0x55D;  // Q50_LIKELY (VVT proxy)
    static constexpr canid_t CAN_VR30_TRANS_TEMP = 0x59A;  // Q50_LIKELY (TCM)
    static constexpr canid_t CAN_VR30_WASTEGATE  = 0x55C;  // Q50_LIKELY
    static constexpr canid_t CAN_VR30_IGN_KNOCK  = 0xFFFF; // UNVERIFIED placeholder
    // G-sensor 3-axis (ATTESA + ABS): bytes 0-1 lateral, 2-3 longitudinal,
    // signed 16-bit big-endian 0.001 G/LSB.
    static constexpr canid_t CAN_G_SENSOR        = 0x132;  // UNVERIFIED

    // ─── CAN IDs ─────────────────────────────────────────────────────────────
    // Sources: opendbc nissan_common.dbc, opendbc X-Trail/Xterra, carhack 370Z,
    //          dalathegreat leaf_can_bus_messages AZE0 DBC, balrog-kun Qashqai.
    //
    // Confidence annotations:
    //   CONFIRMED   — verified across multiple Nissan/Infiniti platforms
    //   Q50_LIKELY  — platform-inferred; high probability but unconfirmed on Q60
    //   UNVERIFIED  — placeholder; DO NOT use for writes until J2534 capture

    // ── HS-CAN (can0, 500 kbps) ───────────────────────────────────────────

    // Steering angle — bytes 0-1, signed 16-bit little-endian, 0.1°/LSB
    // Source: opendbc nissan_common.dbc, carhack 370Z, Qashqai README
    static constexpr canid_t CAN_STEER_ANGLE     = 0x002;  // CONFIRMED

    // Steering torque — bits [7:12] (12-bit), -0.01 Nm scale, +20.47 offset
    // Also carries second steer angle reading: bits [23:18]
    // Source: opendbc nissan_common.dbc (ProPilot/LKAS platform)
    static constexpr canid_t CAN_STEER_TORQUE    = 0x185;  // CONFIRMED

    // RPM — bytes 2-3, big-endian uint16, 0.125 RPM/LSB
    // Also: byte 0 bit 3 = AC compressor request
    // Source: opendbc nissan_xterra_2011.dbc, carhack 370Z
    static constexpr canid_t CAN_RPM             = 0x1F9;  // CONFIRMED

    // Speed — bytes 4-5, big-endian uint16, 0.01 km/h/LSB (cluster output)
    // Source: carhack 370Z, Leaf AZE0 DBC, Qashqai README
    static constexpr canid_t CAN_SPEED           = 0x280;  // CONFIRMED

    // ABS wheel speeds front — bytes 0-1 (FR), bytes 2-3 (FL), big-endian, 0.005 km/h/LSB
    // Source: opendbc Leaf AZE0, nissan_xterra_2011.dbc
    static constexpr canid_t CAN_WHEEL_SPD_FRONT = 0x284;  // CONFIRMED

    // ABS wheel speeds rear — bytes 0-1 (RR), bytes 2-3 (RL), big-endian, 0.005 km/h/LSB
    // Source: opendbc Leaf AZE0, nissan_common.dbc (used by openpilot safety)
    static constexpr canid_t CAN_WHEEL_SPD_REAR  = 0x285;  // CONFIRMED

    // Brake / TCS — bit 52 (big-endian) = brake light on; bit 38 = TCS off
    // Also: bit 23 = driver brake pressed (X-Trail DBC)
    // Source: opendbc nissan_xterra_2011.dbc, nissan_x_trail_2017.dbc
    static constexpr canid_t CAN_BRAKE           = 0x354;  // CONFIRMED

    // Gear selector — byte 0, AT values: P=1 R=2 N=3 D=4 (6MT: P=0x00 R=0x10 1st=0x80+)
    // Source: carhack 370Z, opendbc X-Trail, Leaf AZE0 DBC
    static constexpr canid_t CAN_GEAR            = 0x421;  // CONFIRMED

    // Odometer + parking brake — bytes 1-3 (24-bit), km/miles; byte 0 bit 2 = P-brake
    // Source: Leaf AZE0 DBC, Qashqai README
    static constexpr canid_t CAN_CLUSTER         = 0x5C5;  // CONFIRMED

    // BCM status — turn signals, headlights, doors (see parseVehicleFrame for bit map)
    // byte 0 bit 1 = headlights; byte 1 bit 5 = left turn, bit 6 = right turn
    // byte 0 bit 4 = driver door, bit 5 = passenger door (370Z mapping)
    // Source: carhack 370Z, Leaf AZE0 DBC BCM_GeneralStatus7
    static constexpr canid_t CAN_BODY_STATUS      = 0x60D;  // CONFIRMED (renamed: CAN_BCM is reserved in <linux/can.h>)

    // Outside air temp — byte 7, 0.5°C/LSB, offset -40°C (VCM relay from A/C Auto Amp)
    // Source: Leaf AZE0 DBC VCM_HMI_GeneralData2
    static constexpr canid_t CAN_OUTSIDE_TEMP    = 0x510;  // CONFIRMED

    // ── HVAC frames (HS-CAN, A/C Auto Amp ↔ AV unit) ─────────────────────
    // These are STATUS frames sent by the A/C Auto Amp to the AV display unit.
    // READ path is confirmed (Leaf AZE0 DBC). WRITE path for Q50/Q60 dual-zone
    // is NOT publicly documented — Leaf is single-zone; Q50 byte layout differs.
    //
    // 0x54A: Aircon status 1
    //   byte 0: CC on/off bitmask (0x12/0x3C=off; 0xA0/0xDA=on)
    //   byte 4: setpoint (single-zone Leaf; Q50 driver zone — UNVERIFIED)
    //   byte 7: ambient temp, same formula as CAN_OUTSIDE_TEMP (backup source)
    static constexpr canid_t CAN_HVAC_STATUS     = 0x54A;  // CONFIRMED read; UNVERIFIED write

    // 0x54B: Aircon status 2
    //   byte 1: climate on = 0x78, off = 0x08
    //   byte 2: climate on = 0x88, off = 0x80
    //   byte 4 bits[3:7]: fan speed 1–7 (= (byte4 >> 3) & 0x1F)
    //   byte 7: fan speed change flag (0=no change, 1=changed)
    static constexpr canid_t CAN_HVAC_STATUS2    = 0x54B;  // CONFIRMED read; UNVERIFIED write

    // ── HVAC write frames (HS-CAN) ────────────────────────────────────────────
    // Source: github.com/rynbrd/r51-ecu (R51 Pathfinder/Frontier, same Denso A/C Auto Amp)
    // Cross-referenced: Leaf AZE0 DBC write path analysis, Q50 forum CAN logs
    //
    // 0x540: Climate control command frame (temp + mode)
    //   byte 0: mode flags bitmask
    //     bit 0: system on (1=on, 0=off)
    //     bit 1: A/C compressor request (1=on)
    //     bit 2: recirculation (1=recirc, 0=fresh)
    //     bits 3-4: airflow mode (0=face, 1=feet, 2=blend, 3=defrost)
    //     bit 5: auto mode
    //     bit 6: dual-zone (1=independent zones, 0=sync)
    //   byte 1: driver zone temp raw (same encoding as status: raw = C * 9/5 + 73)
    //   byte 2: passenger zone temp raw
    //   bytes 3-7: 0x00
    //
    // Initialization: send 0x540 with byte0=0x00 x3 (100ms apart) before first command.
    // The A/C Auto Amp ACKs with 0x54A; if no ACK after 3 attempts, amp is offline.
    //
    // NOTE: Temp encoding confirmed matching 0x54A read path (same Denso unit).
    //       Mode bit positions from r51-ecu — CONFIRM via J2534 before relying on writes.
    static constexpr canid_t CAN_HVAC_WRITE      = 0x540;  // CONFIRMED (r51-ecu); byte layout Q50_LIKELY

    // 0x541: Fan speed + recirc override frame
    //   byte 0 bits[0:2]: fan speed 0-7 (0=off, 1=min, 7=max)
    //   byte 0 bit 7: manual fan override (1=manual, 0=auto)
    //   bytes 1-7: 0x00
    static constexpr canid_t CAN_HVAC_FAN        = 0x541;  // CONFIRMED (r51-ecu); byte layout Q50_LIKELY

    // Legacy alias — kept for setAcOn/setRecircOn that still target status-format frames.
    // Remove once all write methods are migrated to 0x540/0x541.
    static constexpr canid_t CAN_HVAC_CTRL       = CAN_HVAC_WRITE;

    // ── Newly confirmed IDs (2026-05 CAN research) ───────────────────────────
    // Source: balrog-kun Qashqai CAN README, carhack 370Z/Sentra, cross-Nissan platform
    //         opendbc nissan_common.dbc, InfinitiQ50Forum CAN thread

    // Ignition state bitfield — byte 0: bit0=ACC, bit1=IGN_ON, bit2=START
    //   0x00=off, 0x01=ACC, 0x03=IGN_ON(run), 0x07=START(cranking)
    //   Used for reliable ignition-off detection (replaces gear+speed heuristic).
    // Source: carhack 370Z, cross-Nissan platform
    static constexpr canid_t CAN_IGNITION        = 0x292;  // Q50_LIKELY

    // Door status + blower fan request
    //   byte 0: door open bitmask
    //     bit 0: driver door open
    //     bit 1: passenger door open
    //     bit 2: rear left door open
    //     bit 3: rear right door open
    //     bit 4: trunk/hatch open
    //   byte 2: blower fan request level (0=off, 1-7=speed)
    // Source: cross-platform Nissan, Qashqai README
    static constexpr canid_t CAN_DOOR_STATUS     = 0x358;  // Q50_LIKELY

    // Climate operational state + wipers
    //   byte 0: A/C compressor clutch engagement (0x00=off, 0x08=on)
    //   byte 2: wiper state (0x00=off, 0x01=slow, 0x02=fast, 0x03=one-shot)
    // Source: Qashqai CAN README, cross-Nissan
    static constexpr canid_t CAN_CLIMATE_WIPERS  = 0x35D;  // Q50_LIKELY

    // Cruise control + coolant temperature
    //   byte 0: cruise bitfield (bit 0=active, bit 1=set, bit 2=acc_on)
    //   byte 2: cruise set speed (km/h, uint8 — display in mph)
    //   byte 6: coolant temp raw, 0.5°C/LSB, offset -40°C (same formula as OAT)
    // Source: cross-platform Nissan (Sentra, Rogue, 370Z patterns)
    static constexpr canid_t CAN_CRUISE_COOLANT  = 0x551;  // Q50_LIKELY

    // BCM extended status (light feedback, battery, defrost)
    //   byte 0: headlight/foglight bitmask (bit 0=fog, bit 1=high-beam)
    //   byte 1: rear defrost on (bit 0), A/C LED (bit 1)
    //   byte 2: battery voltage raw (raw × 0.1 + 0.0 → check scaling on first boot)
    //   byte 4: wiper high-speed state
    // Source: Leaf AZE0 DBC HeadlightFoglightStatus + cross-Nissan BCM frames
    // NOTE: Previously mislabeled CAN_SEAT_HEAT — 0x625 is a STATUS read frame.
    //       Seat heat WRITE path remains UNVERIFIED. Do not write to 0x625.
    static constexpr canid_t CAN_BCM_EXTENDED    = 0x625;  // Q50_LIKELY (READ ONLY)

    // Seat heat write — no confirmed public ID for Q50/Q60.
    // BLOCKED until J2534 capture. Do not transmit.
    static constexpr canid_t CAN_SEAT_HEAT_WRITE = 0xFFFF; // UNVERIFIED PLACEHOLDER

    // Active Sound Control (Bose engine sound enhancement) — factory hides this
    // toggle in a deep diagnostic menu (Settings → Seek-up ×3 → hold below
    // right-scroll-arrow ×5s). The CAN frame written by the diag menu has not
    // been captured yet. BLOCKED until J2534 capture identifies the real ID.
    // UNVERIFIED PLACEHOLDER — sniff during diagnostic menu toggle
    //   (Settings→Seek-up×3→hold below right-scroll-arrow×5s)
    static constexpr canid_t CAN_ASC_TOGGLE      = 0xFFFF; // UNVERIFIED PLACEHOLDER

    // ── UDS diagnostic addresses (HS-CAN) ────────────────────────────────────
    // Standard Nissan/Infiniti UDS addressing pattern — confirmed cross-platform.
    // Service 0x30 (InputOutputControlByID) enables BCM I/O commands.
    // Data identifiers for door lock (0xBF00) are Q50_LIKELY — verify via J2534.
    static constexpr canid_t UDS_COMBINATION_METER = 0x743; // CONFIRMED cross-platform
    static constexpr canid_t UDS_BCM               = 0x745; // CONFIRMED cross-platform
    static constexpr canid_t UDS_BCM_RESPONSE       = 0x74D; // CONFIRMED (request+8)

    // ── Climate shortcuts / steering wheel / plasmacluster / rain sensor ────
    // No confirmed public write paths for Q50/Q60. BLOCKED until J2534 capture.
    // Setters update local state + emit signals but do NOT transmit any frame —
    // matches the seat-heat placeholder pattern (CAN_SEAT_HEAT_WRITE).
    static constexpr canid_t CAN_HEATED_STEERING     = 0xFFFF; // UNVERIFIED PLACEHOLDER — blocked until J2534 capture
    static constexpr canid_t CAN_PLASMA              = 0xFFFF; // UNVERIFIED PLACEHOLDER — blocked until J2534 capture
    static constexpr canid_t CAN_RAIN_SENSOR_ENABLE  = 0xFFFF; // UNVERIFIED PLACEHOLDER — blocked until J2534 capture

    // ── TPMS / oil life / fuel economy ───────────────────────────────────────
    // TPMS — 4 tire PSI broadcast (Q50_LIKELY)
    // byte 0-1: FL big-endian uint16 × 0.25 = PSI
    // byte 2-3: FR, byte 4-5: RL, byte 6-7: RR
    static constexpr canid_t CAN_TPMS         = 0x385;  // Q50_LIKELY

    // Oil life — Q50_LIKELY Nissan proprietary (OBD2 PID fallback at 0x21C Q50_LIKELY)
    static constexpr canid_t CAN_OIL_LIFE     = 0x54C;  // Q50_LIKELY

    // Fuel economy — instantaneous and trip average (Q50_LIKELY)
    // byte 0-1: instant MPG (big-endian uint16, ×0.1 MPG/LSB)
    // byte 2-3: average MPG (big-endian uint16, ×0.1 MPG/LSB)
    static constexpr canid_t CAN_FUEL_ECONOMY = 0x554;  // Q50_LIKELY

    // ── Drive mode / driver aids / ATTESA ────────────────────────────────────
    // Drive mode selector — BCM/TCM command (Q50_LIKELY)
    // byte 0: mode enum (0=Standard 1=Sport 2=Sport+ 3=Eco 4=Snow 5=Personal)
    static constexpr canid_t CAN_DRIVE_MODE   = 0x2DC;  // Q50_LIKELY

    // Driver aids enable/disable — ADAS control unit (Q50_LIKELY)
    // byte 0: bit0=BSW bit1=BSI bit2=LDW bit3=LDP bit4=FEB bit5=BCI bit6=VDC
    // byte 1: PFCW sensitivity (0=off 1=far 2=normal 3=near)
    static constexpr canid_t CAN_ADAS_CTRL    = 0x47D;  // Q50_LIKELY

    // ATTESA AWD torque split status (Q50_LIKELY; rear-biased default)
    // byte 0: front torque % (0–100)
    // byte 1: rear torque % (0–100)
    static constexpr canid_t CAN_ATTESA       = 0x1CA;  // Q50_LIKELY

    // ── AV-CAN (can1, 500 kbps, isolated infotainment bus) ────────────────
    // Steering wheel + panel buttons — byte 0 = status, byte 4 = button code:
    //   Vol+=0xC9  Vol-=0xCA  Seek↑=0x92  Seek↓=0x91  Answer=0xC5  End=0xC6
    //   FM/AM=0xA3  AUX=0xAC  Menu=0xC4  Mute=0xAD
    //   Idle status: byte 0 = 0x0F
    // Source: Leaf AV-CAN DBC. Q50/Q60 InTouch topology Q50_LIKELY same bus.
    static constexpr canid_t CAN_AV_BTNS         = 0x681;  // Q50_LIKELY

    // Bose amplifier wake — no confirmed public ID for Q50/Q60.
    // Sniff at Bose amp connector (trunk, multi-pin green connector on the amp body).
    static constexpr canid_t CAN_BOSE_WAKE       = 0x3B3;  // UNVERIFIED PLACEHOLDER
    static constexpr canid_t CAN_BOSE_VOL        = 0x3B4;  // UNVERIFIED PLACEHOLDER

    // Commander (center console joystick + adjacent buttons)
    // AV-CAN — IDs UNVERIFIED, need J2534 capture on first boot
    static constexpr uint32_t CAN_COMMANDER       = 0x3F6;  // UNVERIFIED — joystick direction + push
    static constexpr uint32_t CAN_COMMANDER_BTN   = 0x4CE;  // UNVERIFIED — Back/Home/Map adjacent buttons

    // Drive mode status read-back (physical selector button)
    // HS-CAN — ID UNVERIFIED
    static constexpr uint32_t CAN_DRIVE_MODE_STATUS = 0x266; // UNVERIFIED — active mode broadcast

    // ── Intelligent Key detection (BCM → HS-CAN) ─────────────────────────────
    // BCM broadcasts key presence/ID when an Intelligent Key is detected in the
    // vehicle (proximity sensor or Start button press).
    //   byte 2: key slot (0x01=key1, 0x02=key2, 0x00=no key)
    // UNVERIFIED: ID 0x35B is a Q50_LIKELY candidate based on BCM frame analysis.
    // Confirm via J2534 capture on first boot before trusting slot values.
    static constexpr canid_t CAN_KEY_DETECT = 0x35B; // UNVERIFIED — BCM key slot broadcast
};
