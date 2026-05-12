// VehicleService.cpp — SocketCAN implementation
// Vehicle CAN (can0, 500kbps): HVAC, speed, gear, temps, headlights
// AVCAN (can1, 500kbps): Bose amp, SXM, radio
// Steering (can2, 250kbps): wheel buttons
//
// NOTE: CAN IDs are placeholder estimates for Infiniti Q60 2017.
// Replace all CAN_* constants with values from J2534 capture (Phase 0).

#include "VehicleService.h"
#include <QDebug>

#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>

VehicleService::VehicleService(QObject *parent)
    : QObject(parent)
{
}

VehicleService::~VehicleService()
{
    if (m_vehicleCanSock >= 0) ::close(m_vehicleCanSock);
    if (m_avCanSock >= 0)      ::close(m_avCanSock);
    if (m_can2Sock >= 0)       ::close(m_can2Sock);
}

void VehicleService::start()
{
    openCAN("can0", m_vehicleCanSock);
    openCAN("can1", m_avCanSock);
    openCAN("can2", m_can2Sock);

    if (m_vehicleCanSock >= 0) {
        m_vehicleNotifier = new QSocketNotifier(m_vehicleCanSock,
                                                QSocketNotifier::Read, this);
        connect(m_vehicleNotifier, &QSocketNotifier::activated,
                this, &VehicleService::onVehicleCanData);
        qDebug() << "[VehicleService] can0 ready";
    }
    if (m_avCanSock >= 0) {
        m_avNotifier = new QSocketNotifier(m_avCanSock,
                                           QSocketNotifier::Read, this);
        connect(m_avNotifier, &QSocketNotifier::activated,
                this, &VehicleService::onAVCanData);
        qDebug() << "[VehicleService] can1 ready";
    }
    if (m_can2Sock >= 0) {
        m_can2Notifier = new QSocketNotifier(m_can2Sock,
                                             QSocketNotifier::Read, this);
        connect(m_can2Notifier, &QSocketNotifier::activated,
                this, &VehicleService::onCAN2Data);
        qDebug() << "[VehicleService] can2 ready";
    }

    // Bose wake on startup — AVCAN frame to wake the amp
    QTimer::singleShot(500, this, &VehicleService::wakeBosse);
}

void VehicleService::openCAN(const char *iface, int &sock)
{
    sock = ::socket(PF_CAN, SOCK_RAW, CAN_RAW);
    if (sock < 0) {
        qWarning() << "[VehicleService] socket() failed for" << iface
                   << strerror(errno);
        return;
    }
    struct ifreq ifr;
    strncpy(ifr.ifr_name, iface, IFNAMSIZ - 1);
    if (::ioctl(sock, SIOCGIFINDEX, &ifr) < 0) {
        qWarning() << "[VehicleService] ioctl(SIOCGIFINDEX) failed for"
                   << iface << strerror(errno);
        ::close(sock);
        sock = -1;
        return;
    }
    struct sockaddr_can addr{};
    addr.can_family  = AF_CAN;
    addr.can_ifindex = ifr.ifr_ifindex;
    if (::bind(sock, reinterpret_cast<struct sockaddr *>(&addr),
               sizeof(addr)) < 0) {
        qWarning() << "[VehicleService] bind() failed for" << iface
                   << strerror(errno);
        ::close(sock);
        sock = -1;
    }
}

void VehicleService::onVehicleCanData()
{
    struct can_frame f;
    ssize_t n = ::read(m_vehicleCanSock, &f, sizeof(f));
    if (n == sizeof(f))
        parseVehicleFrame(f);
}

void VehicleService::onAVCanData()
{
    struct can_frame f;
    ssize_t n = ::read(m_avCanSock, &f, sizeof(f));
    if (n == sizeof(f))
        parseAVFrame(f);
}

void VehicleService::onCAN2Data()
{
    struct can_frame f;
    ssize_t n = ::read(m_can2Sock, &f, sizeof(f));
    if (n == sizeof(f))
        parseCAN2Frame(f);
}

// ─── Vehicle CAN parser ────────────────────────────────────────────────────
void VehicleService::parseVehicleFrame(const struct can_frame &f)
{
    switch (f.can_id & CAN_SFF_MASK) {

    case CAN_HVAC_STATUS: {
        // Byte 0: driver temp (raw, formula TBD post J2534)
        // Byte 1: passenger temp
        // Byte 2: fan speed [0–7]
        // Byte 3 bit0: AC, bit1: recirc, bits[4:6]: mode
        // Byte 4: seat heat driver, Byte 5: seat heat pass
        if (f.can_dlc < 6) break;
        float dt = static_cast<float>(f.data[0]) * 0.5f + 40.0f;
        float pt = static_cast<float>(f.data[1]) * 0.5f + 40.0f;
        int   fs = f.data[2] & 0x07;
        bool  ac = (f.data[3] & 0x01) != 0;
        bool  rc = (f.data[3] & 0x02) != 0;
        int   cm = (f.data[3] >> 4) & 0x07;
        int   ds = f.data[4] & 0x03;
        int   ps = f.data[5] & 0x03;

        if (dt != m_driverTemp)    { m_driverTemp = dt;    emit driverTempChanged(dt); }
        if (pt != m_passengerTemp) { m_passengerTemp = pt; emit passengerTempChanged(pt); }
        if (fs != m_fanSpeed)      { m_fanSpeed = fs;      emit fanSpeedChanged(fs); }
        if (ac != m_acOn)          { m_acOn = ac;          emit acOnChanged(ac); }
        if (rc != m_recircOn)      { m_recircOn = rc;      emit recircOnChanged(rc); }
        if (cm != m_climateMode)   { m_climateMode = cm;   emit climateModeChanged(cm); }
        if (ds != m_driverSeat)    { m_driverSeat = ds;    emit driverSeatChanged(ds); }
        if (ps != m_passSeat)      { m_passSeat = ps;      emit passSeatChanged(ps); }
        break;
    }

    case CAN_SPEED: {
        // Bytes 0–1: speed in 0.01 km/h units (big-endian)
        if (f.can_dlc < 2) break;
        uint16_t raw = (static_cast<uint16_t>(f.data[0]) << 8) | f.data[1];
        float kmh = raw * 0.01f;
        float mph = kmh * 0.621371f;
        if (mph != m_speed) { m_speed = mph; emit speedChanged(mph); }
        break;
    }

    case CAN_GEAR: {
        // Byte 0: gear selector (0=P 1=R 2=N 3=D 4-9=sport)
        if (f.can_dlc < 1) break;
        int g = f.data[0] & 0x0F;
        bool rev = (g == 1);
        if (g != m_gear)     { m_gear = g;     emit gearChanged(g); }
        if (rev != m_reverse){ m_reverse = rev; emit reverseChanged(rev); }
        break;
    }

    case CAN_OUTSIDE_TEMP: {
        // Byte 0: temp raw (raw - 40 = °C)
        if (f.can_dlc < 1) break;
        float c = static_cast<float>(f.data[0]) - 40.0f;
        float f_ = c * 9.0f / 5.0f + 32.0f;
        if (f_ != m_outsideTemp) { m_outsideTemp = f_; emit outsideTempChanged(f_); }
        break;
    }

    case CAN_HEADLIGHTS: {
        if (f.can_dlc < 1) break;
        int hl = f.data[0] & 0x03;
        if (hl != m_headlights) { m_headlights = hl; emit headlightsChanged(hl); }
        break;
    }

    default:
        break;
    }
}

// ─── AVCAN parser ──────────────────────────────────────────────────────────
void VehicleService::parseAVFrame(const struct can_frame &f)
{
    // AVCAN frames are mostly Bose amp status / SXM responses
    // Parsed by DENSO proxy daemons; we only watch for wake-ack here
    (void)f;
}

// ─── Steering wheel CAN2 ───────────────────────────────────────────────────
void VehicleService::parseCAN2Frame(const struct can_frame &f)
{
    if ((f.can_id & CAN_SFF_MASK) != CAN_WHEEL_BTNS) return;
    if (f.can_dlc < 1) return;

    // Button byte — placeholder bit assignments, replace post J2534
    uint8_t btn = f.data[0];
    if (btn & 0x01) emit volUp();
    if (btn & 0x02) emit volDown();
    if (btn & 0x04) emit seekFwd();
    if (btn & 0x08) emit seekBack();
    if (btn & 0x10) emit answerCall();
    if (btn & 0x20) emit endCall();
    if (btn & 0x40) emit voiceActivate();
}

// ─── CAN write helpers ─────────────────────────────────────────────────────
void VehicleService::sendCANFrame(int sock, canid_t id,
                                  const uint8_t *data, uint8_t len)
{
    if (sock < 0) return;
    struct can_frame f{};
    f.can_id  = id & CAN_SFF_MASK;
    f.can_dlc = len;
    memcpy(f.data, data, len);
    if (::write(sock, &f, sizeof(f)) < 0)
        qWarning() << "[VehicleService] CAN write failed:" << strerror(errno);
}

// ─── Climate write slots ───────────────────────────────────────────────────
void VehicleService::setDriverTemp(float temp)
{
    m_driverTemp = temp;
    emit driverTempChanged(temp);
    uint8_t raw = static_cast<uint8_t>((temp - 40.0f) / 0.5f);
    // Full HVAC control frame — pack all current state
    uint8_t d[6] = {
        raw,
        static_cast<uint8_t>((m_passengerTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>(m_fanSpeed & 0x07),
        static_cast<uint8_t>((m_acOn ? 0x01 : 0) |
                              (m_recircOn ? 0x02 : 0) |
                              ((m_climateMode & 0x07) << 4)),
        static_cast<uint8_t>(m_driverSeat & 0x03),
        static_cast<uint8_t>(m_passSeat & 0x03)
    };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_CTRL, d, 6);
}

void VehicleService::setPassengerTemp(float temp)
{
    m_passengerTemp = temp;
    emit passengerTempChanged(temp);
    uint8_t d[6] = {
        static_cast<uint8_t>((m_driverTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>((temp - 40.0f) / 0.5f),
        static_cast<uint8_t>(m_fanSpeed & 0x07),
        static_cast<uint8_t>((m_acOn ? 0x01 : 0) |
                              (m_recircOn ? 0x02 : 0) |
                              ((m_climateMode & 0x07) << 4)),
        static_cast<uint8_t>(m_driverSeat & 0x03),
        static_cast<uint8_t>(m_passSeat & 0x03)
    };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_CTRL, d, 6);
}

void VehicleService::setFanSpeed(int level)
{
    m_fanSpeed = qBound(0, level, 7);
    emit fanSpeedChanged(m_fanSpeed);
    uint8_t d[6] = {
        static_cast<uint8_t>((m_driverTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>((m_passengerTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>(m_fanSpeed),
        static_cast<uint8_t>((m_acOn ? 0x01 : 0) | (m_recircOn ? 0x02 : 0) |
                              ((m_climateMode & 0x07) << 4)),
        static_cast<uint8_t>(m_driverSeat), static_cast<uint8_t>(m_passSeat)
    };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_CTRL, d, 6);
}

void VehicleService::setAcOn(bool on)
{
    m_acOn = on;
    emit acOnChanged(on);
    uint8_t d3 = (m_acOn ? 0x01 : 0) | (m_recircOn ? 0x02 : 0) |
                 ((m_climateMode & 0x07) << 4);
    uint8_t d[6] = {
        static_cast<uint8_t>((m_driverTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>((m_passengerTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>(m_fanSpeed), d3,
        static_cast<uint8_t>(m_driverSeat), static_cast<uint8_t>(m_passSeat)
    };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_CTRL, d, 6);
}

void VehicleService::setRecircOn(bool on)
{
    m_recircOn = on;
    emit recircOnChanged(on);
    uint8_t d3 = (m_acOn ? 0x01 : 0) | (m_recircOn ? 0x02 : 0) |
                 ((m_climateMode & 0x07) << 4);
    uint8_t d[6] = {
        static_cast<uint8_t>((m_driverTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>((m_passengerTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>(m_fanSpeed), d3,
        static_cast<uint8_t>(m_driverSeat), static_cast<uint8_t>(m_passSeat)
    };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_CTRL, d, 6);
}

void VehicleService::setClimateMode(int mode)
{
    m_climateMode = qBound(0, mode, 3);
    emit climateModeChanged(m_climateMode);
    uint8_t d3 = (m_acOn ? 0x01 : 0) | (m_recircOn ? 0x02 : 0) |
                 ((m_climateMode & 0x07) << 4);
    uint8_t d[6] = {
        static_cast<uint8_t>((m_driverTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>((m_passengerTemp - 40.0f) / 0.5f),
        static_cast<uint8_t>(m_fanSpeed), d3,
        static_cast<uint8_t>(m_driverSeat), static_cast<uint8_t>(m_passSeat)
    };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_CTRL, d, 6);
}

void VehicleService::setDriverSeatHeat(int level)
{
    m_driverSeat = qBound(0, level, 3);
    emit driverSeatChanged(m_driverSeat);
    uint8_t d[2] = { static_cast<uint8_t>(m_driverSeat),
                     static_cast<uint8_t>(m_passSeat) };
    sendCANFrame(m_vehicleCanSock, CAN_SEAT_HEAT, d, 2);
}

void VehicleService::setPassSeatHeat(int level)
{
    m_passSeat = qBound(0, level, 3);
    emit passSeatChanged(m_passSeat);
    uint8_t d[2] = { static_cast<uint8_t>(m_driverSeat),
                     static_cast<uint8_t>(m_passSeat) };
    sendCANFrame(m_vehicleCanSock, CAN_SEAT_HEAT, d, 2);
}

void VehicleService::setRearDefrost(bool on)
{
    uint8_t d[1] = { static_cast<uint8_t>(on ? 0x01 : 0x00) };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_CTRL, d, 1);
}

// ─── Bose wake ─────────────────────────────────────────────────────────────
void VehicleService::wakeBosse()
{
    // AVCAN wake frame — exact byte pattern TBD from J2534 sniff
    // Pattern based on Infiniti AVCAN known docs (placeholder)
    uint8_t d[8] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_avCanSock, CAN_BOSE_WAKE, d, 8);
    qDebug() << "[VehicleService] Bose wake sent on AVCAN";
}
