// VehicleService.cpp — SocketCAN implementation
// can0: HS-CAN 500kbps — powertrain, BCM, HVAC, ABS (Vehicle CAN)
// can1: AV-CAN 500kbps isolated — Bose, SXM, steering wheel buttons
// can2: TBD (possibly MS-CAN 125kbps body bus — probe needed)
//
// CAN IDs are sourced from community research across Nissan/Infiniti platforms
// (370Z, X-Trail, Leaf AZE0, Qashqai). See VehicleService.h for confidence levels.
// HVAC write path and Bose wake ID require J2534 verification before relying on.

#include "VehicleService.h"
#include <QCoreApplication>
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
    // Open diagnostic button logger — rotates previous session log, starts fresh
    m_buttonLog.open(QStringLiteral("/var/log/q60nav-buttons.log"));

    // Connect ignition-off signal to logger to seal the session file
    connect(this, &VehicleService::ignitionOff,
            this, [this]() { m_buttonLog.signalSessionEnd(QStringLiteral("ignition_off")); });

    openCAN("can0", m_vehicleCanSock);
    openCAN("can1", m_avCanSock);
    openCAN("can2", m_can2Sock);

    if (m_vehicleCanSock >= 0) {
        m_vehicleNotifier = new QSocketNotifier(m_vehicleCanSock,
                                                QSocketNotifier::Read, this);
        connect(m_vehicleNotifier, &QSocketNotifier::activated,
                this, &VehicleService::onVehicleCanData);
        qDebug() << "[VehicleService] can0 (HS-CAN) ready";
    }
    if (m_avCanSock >= 0) {
        m_avNotifier = new QSocketNotifier(m_avCanSock,
                                           QSocketNotifier::Read, this);
        connect(m_avNotifier, &QSocketNotifier::activated,
                this, &VehicleService::onAVCanData);
        qDebug() << "[VehicleService] can1 (AV-CAN) ready";
    }
    if (m_can2Sock >= 0) {
        m_can2Notifier = new QSocketNotifier(m_can2Sock,
                                             QSocketNotifier::Read, this);
        connect(m_can2Notifier, &QSocketNotifier::activated,
                this, &VehicleService::onCAN2Data);
        qDebug() << "[VehicleService] can2 (TBD) ready";
    }

    // HVAC init — send handshake sequence after bus settles (300ms)
    QTimer::singleShot(300, this, &VehicleService::hvacInit);

    // Bose wake on startup — send on AV-CAN after bus settles
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
    if (::read(m_vehicleCanSock, &f, sizeof(f)) == sizeof(f))
        parseVehicleFrame(f);
}

void VehicleService::onAVCanData()
{
    struct can_frame f;
    if (::read(m_avCanSock, &f, sizeof(f)) == sizeof(f))
        parseAVFrame(f);
}

void VehicleService::onCAN2Data()
{
    struct can_frame f;
    if (::read(m_can2Sock, &f, sizeof(f)) == sizeof(f))
        parseCAN2Frame(f);
}

// ─── HS-CAN parser (can0) ─────────────────────────────────────────────────
void VehicleService::parseVehicleFrame(const struct can_frame &f)
{
    switch (f.can_id & CAN_SFF_MASK) {

    // ── 0x002: Steering angle ─────────────────────────────────────────────
    // bytes 0-1: signed 16-bit little-endian, 0.1°/LSB
    // Source: opendbc nissan_common.dbc, carhack 370Z
    case CAN_STEER_ANGLE: {
        if (f.can_dlc < 2) break;
        int16_t raw = static_cast<int16_t>(
            static_cast<uint16_t>(f.data[0]) |
            (static_cast<uint16_t>(f.data[1]) << 8));
        float deg = raw * 0.1f;
        if (deg != m_steerAngle) { m_steerAngle = deg; emit steerAngleChanged(deg); }
        break;
    }

    // ── 0x1F9: Engine RPM ─────────────────────────────────────────────────
    // bytes 2-3: big-endian uint16, 0.125 RPM/LSB
    // byte 0 bit 3: AC compressor request
    // Source: opendbc nissan_xterra_2011.dbc, carhack 370Z
    case CAN_RPM: {
        if (f.can_dlc < 4) break;
        uint16_t raw = (static_cast<uint16_t>(f.data[2]) << 8) | f.data[3];
        int rpm = static_cast<int>(raw * 0.125f);
        if (rpm != m_rpm) { m_rpm = rpm; emit rpmChanged(rpm); }
        break;
    }

    // ── 0x280: Vehicle speed (cluster) ───────────────────────────────────
    // bytes 4-5: big-endian uint16, 0.01 km/h/LSB
    // Source: carhack 370Z ("E,F bytes"), Leaf AZE0 DBC, Qashqai README
    case CAN_SPEED: {
        if (f.can_dlc < 6) break;
        uint16_t raw = (static_cast<uint16_t>(f.data[4]) << 8) | f.data[5];
        float kmh = raw * 0.01f;
        float mph = kmh * 0.621371f;
        if (mph != m_speed) { m_speed = mph; emit speedChanged(mph); }
        break;
    }

    // ── 0x354: Brake / TCS ────────────────────────────────────────────────
    // bit 52 (big-endian frame bit numbering) = brake light
    // bit 23 = driver brake pressed (X-Trail DBC)
    // bit 38 = TCS disabled
    // DBC bit 52 = byte 6 bit 4 (little-endian byte, big-endian bit within)
    // Simpler: byte 2 bit 7 per 370Z raw observation (use both, J2534 to confirm)
    // Source: opendbc nissan_xterra_2011.dbc, nissan_x_trail_2017.dbc
    case CAN_BRAKE: {
        if (f.can_dlc < 7) break;
        // DBC bit 52 in Motorola/big-endian = byte 6, bit 4 from MSB
        bool brk = (f.data[6] & 0x10) != 0;
        if (brk != m_brakePressed) { m_brakePressed = brk; emit brakePressedChanged(brk); }
        break;
    }

    // ── 0x421: Gear selector ─────────────────────────────────────────────
    // AT: P=1 R=2 N=3 D=4 (L/M sport modes > 4)
    // 6MT: P/N=0 R=0x10 1st=0x80 2nd=0x88 3rd=0x90 4th=0x98 5th=0xA0 6th=0xA8
    // Source: carhack 370Z, opendbc X-Trail (AT values), Leaf AZE0 DBC
    case CAN_GEAR: {
        if (f.can_dlc < 1) break;
        uint8_t raw = f.data[0];
        int  g;
        bool rev;
        if (raw <= 10) {
            // Automatic transmission (AT) interpretation
            g   = static_cast<int>(raw);
            rev = (raw == 2);
        } else {
            // Manual/other — map 6MT codes to display gear
            rev = (raw == 0x10);
            if      (raw == 0x80) g = 1;
            else if (raw == 0x88) g = 2;
            else if (raw == 0x90) g = 3;
            else if (raw == 0x98) g = 4;
            else if (raw == 0xA0) g = 5;
            else if (raw == 0xA8) g = 6;
            else                  g = 0;
        }
        if (g   != m_gear)    { m_gear    = g;   emit gearChanged(g); }
        if (rev != m_reverse) { m_reverse = rev; emit reverseChanged(rev); }

        // Ignition-off heuristic: gear=Park + speed < 1 mph + parking brake active.
        // This seals the button log for the session. Not 100% reliable (no direct
        // key-off CAN ID confirmed yet), but good enough for log lifecycle management.
        // A future J2534 capture of key-off events can make this more precise.
        if (g == 1 && m_speed < 1.0f && m_parkingBrake && !m_ignitionOffSent) {
            m_ignitionOffSent = true;
            emit ignitionOff();
        } else if (g != 1 || m_speed >= 1.0f) {
            m_ignitionOffSent = false;  // reset when car is moving again
        }
        break;
    }

    // ── 0x510: Outside ambient temperature (VCM relay) ───────────────────
    // byte 7: 0.5°C/LSB, offset -40°C → temp_C = (raw * 0.5f) - 40.0f
    // Source: Leaf AZE0 DBC VCM_HMI_GeneralData2 (OutsideAmbientTemperature)
    case CAN_OUTSIDE_TEMP: {
        if (f.can_dlc < 8) break;
        float c = (f.data[7] * 0.5f) - 40.0f;
        float fahr = c * 9.0f / 5.0f + 32.0f;
        if (fahr != m_outsideTemp) { m_outsideTemp = fahr; emit outsideTempChanged(fahr); }
        break;
    }

    // ── 0x54A: HVAC status 1 (A/C Auto Amp → AV unit) ────────────────────
    // byte 0:  CC status bitmask (0x12/0x3C=off; 0xA0/0xDA=on)
    // byte 4:  driver zone setpoint (Leaf single-zone basis; Q50 dual-zone UNVERIFIED)
    //          Formula: temp_F = (raw - 41) → temp_C = (raw - 73.0f) * 5.0f/9.0f
    //          Verified: 0x83=90°F, 0x79≈79°F
    // byte 5:  passenger zone setpoint (Q50 — UNVERIFIED, inferred from dual-zone arch)
    // byte 7:  ambient temp (same formula as 0x510, used as fallback)
    // Source: Leaf AZE0 DBC Aircon_GeneralStatus1_ITM
    case CAN_HVAC_STATUS: {
        if (f.can_dlc < 8) break;
        // Driver temp setpoint
        if (f.data[4] > 0) {
            float dt = (static_cast<float>(f.data[4]) - 73.0f) * 5.0f / 9.0f;
            dt = dt * 9.0f / 5.0f + 32.0f;  // convert to °F for display
            if (dt != m_driverTemp && dt > 40.0f && dt < 110.0f) {
                m_driverTemp = dt;
                emit driverTempChanged(dt);
            }
        }
        // Passenger temp setpoint (Q50 UNVERIFIED — may not be byte 5)
        if (f.data[5] > 0) {
            float pt = (static_cast<float>(f.data[5]) - 73.0f) * 5.0f / 9.0f;
            pt = pt * 9.0f / 5.0f + 32.0f;
            if (pt != m_passengerTemp && pt > 40.0f && pt < 110.0f) {
                m_passengerTemp = pt;
                emit passengerTempChanged(pt);
            }
        }
        // Ambient temp fallback (byte 7, same VCM formula)
        float amb_c = (f.data[7] * 0.5f) - 40.0f;
        float amb_f = amb_c * 9.0f / 5.0f + 32.0f;
        if (m_outsideTemp == 67.0f && amb_f > -40.0f && amb_f < 140.0f) {
            // Only use as fallback if 0x510 hasn't populated yet
            m_outsideTemp = amb_f;
            emit outsideTempChanged(amb_f);
        }
        break;
    }

    // ── 0x54B: HVAC status 2 ─────────────────────────────────────────────
    // byte 1: climate on = 0x78, off = 0x08
    // byte 4 bits[3:7]: fan speed 1-7 = (byte4 >> 3) & 0x1F
    // Source: Leaf AZE0 DBC Aircon_GeneralStatus2_ITM
    case CAN_HVAC_STATUS2: {
        if (f.can_dlc < 5) break;
        bool ac = (f.data[1] == 0x78);
        int  fs = (f.data[4] >> 3) & 0x1F;
        fs = qBound(0, fs, 7);
        if (ac != m_acOn)     { m_acOn = ac;    emit acOnChanged(ac); }
        if (fs != m_fanSpeed) { m_fanSpeed = fs; emit fanSpeedChanged(fs); }
        break;
    }

    // ── 0x5C5: Cluster (odometer, parking brake) ─────────────────────────
    // byte 0 bit 2: parking brake active
    // bytes 1-3:    odometer (24-bit, market-native units — not parsed for nav)
    // Source: Leaf AZE0 DBC, Qashqai README
    case CAN_CLUSTER: {
        if (f.can_dlc < 1) break;
        bool pb = (f.data[0] & 0x04) != 0;
        if (pb != m_parkingBrake) { m_parkingBrake = pb; emit parkingBrakeChanged(pb); }
        break;
    }

    // ── 0x60D: BCM — turn signals, headlights, doors ─────────────────────
    // byte 0 bit 1: headlights on (1=on, 0=off)
    // byte 0 bit 2: running lights / parking lights
    // byte 1 bit 5: left turn signal active
    // byte 1 bit 6: right turn signal active
    // byte 0 bit 4: driver door open
    // byte 0 bit 5: passenger door open
    // Source: carhack 370Z mapping; cross-checked vs Leaf AZE0 DBC BCM_GeneralStatus7
    case CAN_BODY_STATUS: {
        if (f.can_dlc < 2) break;
        int  hl  = (f.data[0] & 0x02) ? 2 : (f.data[0] & 0x04) ? 1 : 0;
        bool lft = (f.data[1] & 0x20) != 0;
        bool rgt = (f.data[1] & 0x40) != 0;
        if (hl  != m_headlights) { m_headlights = hl;  emit headlightsChanged(hl); }
        if (lft != m_leftTurn)   { m_leftTurn   = lft; emit leftTurnChanged(lft); }
        if (rgt != m_rightTurn)  { m_rightTurn  = rgt; emit rightTurnChanged(rgt); }
        break;
    }

    default:
        break;
    }
}

// ─── AV-CAN parser (can1) ─────────────────────────────────────────────────
// Handles steering wheel / panel button presses via 0x681
// Source: Leaf AV-CAN DBC; Q50_LIKELY same bus topology
//
// All presses are logged to /var/log/q60nav-buttons.log via ButtonLogger.
// Unknown button codes are logged as UNKNOWN for J2534 cross-reference.
void VehicleService::parseAVFrame(const struct can_frame &f)
{
    canid_t id = f.can_id & CAN_SFF_MASK;

    // Log all AV-CAN frames that aren't the idle heartbeat (byte0=0x0F)
    // This captures every button the car sends, even ones we don't act on yet.
    if (id == CAN_AV_BTNS && f.can_dlc >= 1 && f.data[0] != 0x0F) {
        // Determine action string for known button codes
        QString action;
        if (f.can_dlc >= 5) {
            switch (f.data[4]) {
            case 0xC9: action = QStringLiteral("VolumeUp");      break;
            case 0xCA: action = QStringLiteral("VolumeDown");    break;
            case 0x92: action = QStringLiteral("SeekForward");   break;
            case 0x91: action = QStringLiteral("SeekBack");      break;
            case 0xC5: action = QStringLiteral("AnswerCall");    break;
            case 0xC6: action = QStringLiteral("EndCall");       break;
            case 0xAD: action = QStringLiteral("Mute");          break;
            case 0x90: action = QStringLiteral("VoiceActivate"); break;
            case 0xA3: action = QStringLiteral("FmAmToggle");    break;
            case 0xAC: action = QStringLiteral("AuxSelect");     break;
            case 0xC4: action = QStringLiteral("Menu");          break;
            case 0x80: action = QStringLiteral("CruiseOn");      break;
            case 0x81: action = QStringLiteral("CruiseOff");     break;
            case 0x82: action = QStringLiteral("CruiseSet");     break;
            case 0x83: action = QStringLiteral("CruiseResume");  break;
            case 0x84: action = QStringLiteral("CruiseCancel");  break;
            case 0x85: action = QStringLiteral("CruiseAccel");   break;
            case 0x86: action = QStringLiteral("CruiseDecel");   break;
            case 0x00: action = QStringLiteral("ButtonRelease"); break;
            default:   action = QStringLiteral("UNKNOWN_0x") +
                                QString::number(f.data[4], 16).toUpper();
            }
        } else {
            action = QStringLiteral("SHORT_FRAME");
        }
        m_buttonLog.logAction(QStringLiteral("AV-CAN"), id, f, action);
    } else if (id != CAN_AV_BTNS) {
        // Log all other non-idle AV-CAN frames for discovery
        m_buttonLog.logDiscovery(QStringLiteral("AV-CAN"), id, f);
        return;
    }

    // Only dispatch Qt signals on active press (byte0=0x04 press, 0x03=power key)
    if (f.can_dlc < 5) return;
    if (f.data[0] != 0x04 && f.data[0] != 0x03) return;

    switch (f.data[4]) {
    case 0xC9: emit volUp();         break;
    case 0xCA: emit volDown();       break;
    case 0x92: emit seekFwd();       break;
    case 0x91: emit seekBack();      break;
    case 0xC5: emit answerCall();    break;
    case 0xC6: emit endCall();       break;
    case 0xAD: emit muteToggle();    break;
    case 0x90: emit voiceActivate(); break;  // steering wheel speech button
    default:   break;
    }
}

// ─── CAN2 parser (can2) ───────────────────────────────────────────────────
// Bus topology on Q60 not confirmed. May be MS-CAN 125kbps for body controls,
// or this interface may not exist.
// ALL frames are logged for J2534 cross-reference and CAN discovery.
void VehicleService::parseCAN2Frame(const struct can_frame &f)
{
    canid_t id = f.can_id & CAN_SFF_MASK;
    m_buttonLog.logDiscovery(QStringLiteral("CAN2"), id, f);
    qDebug() << "[VehicleService] can2 frame id=" << Qt::hex << id
             << "dlc=" << f.can_dlc;
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

// ─── HVAC helpers ──────────────────────────────────────────────────────────

// Encode °F display temp to 0x540 raw byte.
// Same scale as status 0x54A (confirmed matching Denso unit read path):
//   raw = (temp_C * 9/5) + 73   → inverse of: temp_F = (raw - 73) * 5/9 * 9/5 + 32
// Clamp to [0x48, 0x90] ≈ [60°F, 90°F] — typical A/C setpoint range.
uint8_t VehicleService::hvacTempRaw(float tempF) const
{
    float c   = (tempF - 32.0f) * 5.0f / 9.0f;
    float raw = c * 9.0f / 5.0f + 73.0f;
    return static_cast<uint8_t>(qBound(0x48, static_cast<int>(raw), 0x90));
}

// Pack current HVAC state into the mode-flags byte (byte 0) of 0x540.
// Bit layout from r51-ecu (R51 Pathfinder, same Denso A/C Auto Amp):
//   bit 0: system on
//   bit 1: A/C compressor on
//   bit 2: recirculation on
//   bits 3-4: airflow mode (0=face, 1=feet, 2=blend, 3=defrost)
//   bit 5: auto mode (0 = manual)
//   bit 6: dual-zone independent mode
// Q50_LIKELY — bit positions from r51-ecu; verify via J2534 before relying on writes.
uint8_t VehicleService::hvacModeFlags() const
{
    uint8_t f = 0;
    f |= 0x01;                                       // system on
    if (m_acOn)    f |= 0x02;
    if (m_recircOn) f |= 0x04;
    f |= static_cast<uint8_t>((m_climateMode & 0x03) << 3);
    f |= 0x40;                                       // dual-zone (Q60 has two zones)
    return f;
}

// HVAC initialization sequence — send three null frames on 0x540 (100ms apart)
// to register as the infotainment unit with the A/C Auto Amp. The amp starts
// sending status frames (0x54A/0x54B) in response once it sees the handshake.
// Source: r51-ecu observation — amp ignores control frames until handshake completes.
void VehicleService::hvacInit()
{
    if (m_vehicleCanSock < 0) {
        qDebug() << "[VehicleService] hvacInit: can0 not open — skipping HVAC handshake";
        return;
    }
    static int initStep = 0;
    uint8_t d[8] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_FAN,   d, 8);
    ++initStep;
    if (initStep < 3) {
        // Three handshake frames, 100ms apart
        QTimer::singleShot(100, this, &VehicleService::hvacInit);
    } else {
        initStep = 0;
        qDebug() << "[VehicleService] HVAC handshake complete — A/C Auto Amp should respond on 0x54A";
    }
}

// ─── Climate write slots ───────────────────────────────────────────────────
// Write path: 0x540 (temp/mode) and 0x541 (fan speed).
// Source: github.com/rynbrd/r51-ecu — confirmed on R51 Denso A/C Auto Amp.
// Same amp used on Q50/Q60; byte layout Q50_LIKELY. Verify via J2534 on first boot.
// Local state updated immediately so UI is responsive regardless of car ACK.

void VehicleService::setDriverTemp(float temp)
{
    m_driverTemp = qBound(60.0f, temp, 90.0f);
    emit driverTempChanged(m_driverTemp);
    uint8_t d[8] = { hvacModeFlags(),
                     hvacTempRaw(m_driverTemp),
                     hvacTempRaw(m_passengerTemp),
                     0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
}

void VehicleService::setPassengerTemp(float temp)
{
    m_passengerTemp = qBound(60.0f, temp, 90.0f);
    emit passengerTempChanged(m_passengerTemp);
    uint8_t d[8] = { hvacModeFlags(),
                     hvacTempRaw(m_driverTemp),
                     hvacTempRaw(m_passengerTemp),
                     0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
}

void VehicleService::setFanSpeed(int level)
{
    m_fanSpeed = qBound(0, level, 7);
    emit fanSpeedChanged(m_fanSpeed);
    // 0x541 byte 0: bits[0:2] = fan level, bit 7 = manual override
    uint8_t d[8] = { static_cast<uint8_t>(0x80 | (m_fanSpeed & 0x07)),
                     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_FAN, d, 8);
}

void VehicleService::setAcOn(bool on)
{
    m_acOn = on;
    emit acOnChanged(on);
    // AC bit is in mode flags byte — resend full 0x540 frame
    uint8_t d[8] = { hvacModeFlags(),
                     hvacTempRaw(m_driverTemp),
                     hvacTempRaw(m_passengerTemp),
                     0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
}

void VehicleService::setRecircOn(bool on)
{
    m_recircOn = on;
    emit recircOnChanged(on);
    // Recirc bit is in mode flags byte — resend full 0x540 frame
    uint8_t d[8] = { hvacModeFlags(),
                     hvacTempRaw(m_driverTemp),
                     hvacTempRaw(m_passengerTemp),
                     0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
}

void VehicleService::setClimateMode(int mode)
{
    m_climateMode = qBound(0, mode, 3);
    emit climateModeChanged(m_climateMode);
    // Airflow mode bits [3:4] in mode flags — resend full 0x540 frame
    uint8_t d[8] = { hvacModeFlags(),
                     hvacTempRaw(m_driverTemp),
                     hvacTempRaw(m_passengerTemp),
                     0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
}

void VehicleService::setDriverSeatHeat(int level)
{
    m_driverSeat = qBound(0, level, 3);
    emit driverSeatChanged(m_driverSeat);
    // Seat heat write ID unconfirmed (0x625 is read-only status)
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
    // Rear defrost: 0x5C5 byte A0 per 370Z observation (UNVERIFIED write path)
    uint8_t d[1] = { static_cast<uint8_t>(on ? 0x44 : 0x40) };
    sendCANFrame(m_vehicleCanSock, CAN_CLUSTER, d, 1);
}

// ─── Bose wake ─────────────────────────────────────────────────────────────
void VehicleService::wakeBosse()
{
    // Wake frame ID (0x3B3) is a placeholder — no confirmed public source for Q50/Q60.
    // To find the real ID: tap the multi-pin connector on the Bose amp (trunk),
    // attach a CAN sniffer to the AV-CAN lines, and capture frames sent on ignition ON.
    // The amp typically responds within 200-500ms of receiving the wake frame.
    qWarning() << "[VehicleService] Bose wake: CAN_BOSE_WAKE (0x3B3) is UNVERIFIED — sniff AV-CAN at amp connector to confirm";
    uint8_t d[8] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_avCanSock, CAN_BOSE_WAKE, d, 8);
}
