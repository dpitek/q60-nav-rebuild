#pragma once
#include <QObject>
#include <QTimer>
#include <QSocketNotifier>
#include <linux/can.h>
#include <linux/can/raw.h>

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
    // Steering wheel button events (fired from AV-CAN 0x681)
    void volUp();
    void volDown();
    void seekFwd();
    void seekBack();
    void answerCall();
    void endCall();
    void voiceActivate();

private slots:
    void onVehicleCanData();
    void onAVCanData();
    void onCAN2Data();

private:
    void openCAN(const char *iface, int &sock);
    void parseVehicleFrame(const struct can_frame &f);
    void parseAVFrame(const struct can_frame &f);
    void parseCAN2Frame(const struct can_frame &f);
    void sendCANFrame(int sock, canid_t id, const uint8_t *data, uint8_t len);

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

    // HVAC write target — pending J2534 capture; using 0x54A as best guess
    // DO NOT rely on car responding until confirmed. Updates local state regardless.
    static constexpr canid_t CAN_HVAC_CTRL       = 0x54A;  // UNVERIFIED WRITE PATH

    // Seat heat — 0x625 is USM_GeneralStatus (read). Write target UNVERIFIED.
    // Source: Leaf AZE0 DBC (HeadlightFoglightStatus also on this ID)
    static constexpr canid_t CAN_SEAT_HEAT       = 0x625;  // UNVERIFIED WRITE PATH

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
};
