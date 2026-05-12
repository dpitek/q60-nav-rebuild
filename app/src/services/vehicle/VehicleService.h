#pragma once
#include <QObject>
#include <QTimer>
#include <QSocketNotifier>
#include <linux/can.h>
#include <linux/can/raw.h>

class VehicleService : public QObject {
    Q_OBJECT
    // Climate
    Q_PROPERTY(float driverTemp   READ driverTemp   NOTIFY driverTempChanged)
    Q_PROPERTY(float passengerTemp READ passengerTemp NOTIFY passengerTempChanged)
    Q_PROPERTY(int   fanSpeed     READ fanSpeed     NOTIFY fanSpeedChanged)
    Q_PROPERTY(bool  acOn         READ acOn         NOTIFY acOnChanged)
    Q_PROPERTY(bool  recircOn     READ recircOn     NOTIFY recircOnChanged)
    Q_PROPERTY(int   climateMode  READ climateMode  NOTIFY climateModeChanged)
    Q_PROPERTY(int   driverSeat   READ driverSeat   NOTIFY driverSeatChanged)
    Q_PROPERTY(int   passSeat     READ passSeat     NOTIFY passSeatChanged)
    // Vehicle signals
    Q_PROPERTY(float speed        READ speed        NOTIFY speedChanged)
    Q_PROPERTY(float speedLimit   READ speedLimit   NOTIFY speedLimitChanged)
    Q_PROPERTY(int   gear         READ gear         NOTIFY gearChanged)
    Q_PROPERTY(bool  reverse      READ reverse      NOTIFY reverseChanged)
    Q_PROPERTY(float outsideTemp  READ outsideTemp  NOTIFY outsideTempChanged)
    Q_PROPERTY(int   headlights   READ headlights   NOTIFY headlightsChanged)

public:
    explicit VehicleService(QObject *parent = nullptr);
    ~VehicleService();
    void start();

    // Climate reads
    float driverTemp()    const { return m_driverTemp; }
    float passengerTemp() const { return m_passengerTemp; }
    int   fanSpeed()      const { return m_fanSpeed; }
    bool  acOn()          const { return m_acOn; }
    bool  recircOn()      const { return m_recircOn; }
    int   climateMode()   const { return m_climateMode; }
    int   driverSeat()    const { return m_driverSeat; }
    int   passSeat()      const { return m_passSeat; }
    // Vehicle reads
    float speed()        const { return m_speed; }
    float speedLimit()   const { return m_speedLimit; }
    int   gear()         const { return m_gear; }
    bool  reverse()      const { return m_reverse; }
    float outsideTemp()  const { return m_outsideTemp; }
    int   headlights()   const { return m_headlights; }

public slots:
    // Climate writes — translates to CAN frames on Vehicle CAN
    void setDriverTemp(float temp);
    void setPassengerTemp(float temp);
    void setFanSpeed(int level);       // 0–7
    void setAcOn(bool on);
    void setRecircOn(bool on);
    void setClimateMode(int mode);     // 0=face 1=feet 2=blend 3=defrost
    void setDriverSeatHeat(int level); // 0–3
    void setPassSeatHeat(int level);
    void setRearDefrost(bool on);

    // Bose wake — must call on startup before audio
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
    void outsideTempChanged(float);
    void headlightsChanged(int);
    // Steering wheel button events
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

    int m_vehicleCanSock = -1;  // can0 — Vehicle CAN
    int m_avCanSock = -1;       // can1 — AVCAN (Bose, SXM, etc.)
    int m_can2Sock = -1;        // can2 — Steering wheel (250kbps)
    QSocketNotifier *m_vehicleNotifier = nullptr;
    QSocketNotifier *m_avNotifier = nullptr;
    QSocketNotifier *m_can2Notifier = nullptr;

    // State
    float m_driverTemp = 72.0f;
    float m_passengerTemp = 70.0f;
    int   m_fanSpeed = 4;
    bool  m_acOn = true;
    bool  m_recircOn = false;
    int   m_climateMode = 0;
    int   m_driverSeat = 0;
    int   m_passSeat = 0;
    float m_speed = 0.0f;
    float m_speedLimit = 0.0f;
    int   m_gear = 0;
    bool  m_reverse = false;
    float m_outsideTemp = 67.0f;
    int   m_headlights = 0;

    // CAN IDs — populated from DBC after Phase 0 sniff
    // Placeholders: replace with real IDs post J2534 capture
    static constexpr canid_t CAN_HVAC_STATUS     = 0x54A; // vehicle CAN
    static constexpr canid_t CAN_HVAC_CTRL        = 0x54B; // vehicle CAN write
    static constexpr canid_t CAN_SEAT_HEAT        = 0x625; // vehicle CAN
    static constexpr canid_t CAN_SPEED            = 0x180; // vehicle CAN
    static constexpr canid_t CAN_GEAR             = 0x421; // vehicle CAN
    static constexpr canid_t CAN_OUTSIDE_TEMP     = 0x385; // vehicle CAN
    static constexpr canid_t CAN_HEADLIGHTS       = 0x60D; // vehicle CAN
    static constexpr canid_t CAN_WHEEL_BTNS       = 0x25;  // CAN2 steering
    static constexpr canid_t CAN_BOSE_WAKE        = 0x3B3; // AVCAN — TBD J2534
    static constexpr canid_t CAN_BOSE_VOL         = 0x3B4; // AVCAN — TBD J2534
};
