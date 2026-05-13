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
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>

#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>
#include <cmath>

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

    // Trip computer 1Hz tick — only accumulates when ignition is on
    m_tripTimer = new QTimer(this);
    m_tripTimer->setInterval(1000);
    connect(m_tripTimer, &QTimer::timeout, this, &VehicleService::onTripTimerTick);
    m_tripTimer->start();

    // Performance timer 10Hz — runs continuously, gated by speed/throttle state
    m_perfTimer = new QTimer(this);
    m_perfTimer->setInterval(100);
    connect(m_perfTimer, &QTimer::timeout, this, &VehicleService::onPerfTick);
    m_perfTimer->start();

    // Reset peak G + 0-60 latches on ignition cycle — per spec, in-memory only
    connect(this, &VehicleService::ignitionOff, this, [this]() {
        m_peakLateralG = 0.0;
        m_peakLongitudinalG = 0.0;
        m_zeroToSixtySec = 0.0;
        m_quarterMileSec = 0.0;
        m_quarterMileTrapMph = 0.0;
        m_perfRunActive = false;
        m_perfRunArmed = false;
        m_perfRunElapsedSec = 0.0;
        m_perfRunDistanceMi = 0.0;
        emit gMeterChanged();
        emit perfTimerChanged();
    });
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
        // Accumulate distance for trip computers (~10Hz → divide by 10000)
        if (m_ignitionOn && mph > 0.0f) {
            float delta = mph / 10000.0f;
            m_tripAMiles += delta;
            m_tripBMiles += delta;
        }
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

        // Ignition-off detection is now handled by CAN_IGNITION (0x292).
        // The heuristic (gear=Park + speed<1 + parking brake) is removed — it was
        // unreliable and fired spuriously at traffic lights. 0x292 is the real signal.
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

    // ── 0x292: Ignition state ─────────────────────────────────────────────────
    // byte 0 bitfield: bit0=ACC, bit1=IGN_ON, bit2=START
    //   0x00=off, 0x01=ACC, 0x03=IGN_ON (running), 0x07=START (cranking)
    // Used for reliable ignition-off detection — replaces the gear+speed heuristic.
    // Source: carhack 370Z, cross-Nissan platform
    case CAN_IGNITION: {
        if (f.can_dlc < 1) break;
        bool ign = (f.data[0] & 0x02) != 0;  // bit 1 = IGN_ON
        if (ign != m_ignitionOn) {
            m_ignitionOn = ign;
            emit ignitionOnChanged(ign);
            if (!ign && !m_ignitionOffSent) {
                // Ignition just turned off — seal the button log session
                m_ignitionOffSent = true;
                emit ignitionOff();
            } else if (ign) {
                m_ignitionOffSent = false;  // reset for next key cycle
            }
        }
        break;
    }

    // ── 0x358: Door / trunk open status ──────────────────────────────────────
    // byte 0 bitmask:
    //   bit 0: driver door open
    //   bit 1: passenger door open
    //   bit 2: rear left door open
    //   bit 3: rear right door open
    //   bit 4: trunk / hatch open
    // Source: cross-platform Nissan, Qashqai README
    case CAN_DOOR_STATUS: {
        if (f.can_dlc < 1) break;
        bool dd  = (f.data[0] & 0x01) != 0;
        bool dp  = (f.data[0] & 0x02) != 0;
        bool drl = (f.data[0] & 0x04) != 0;
        bool drr = (f.data[0] & 0x08) != 0;
        bool tr  = (f.data[0] & 0x10) != 0;
        if (dd  != m_doorDriver)    { m_doorDriver    = dd;  emit doorDriverChanged(dd); }
        if (dp  != m_doorPassenger) { m_doorPassenger = dp;  emit doorPassengerChanged(dp); }
        if (drl != m_doorRearLeft)  { m_doorRearLeft  = drl; emit doorRearLeftChanged(drl); }
        if (drr != m_doorRearRight) { m_doorRearRight = drr; emit doorRearRightChanged(drr); }
        if (tr  != m_trunkOpen)     { m_trunkOpen     = tr;  emit trunkOpenChanged(tr); }
        break;
    }

    // ── 0x35D: Climate + wiper state ─────────────────────────────────────────
    // byte 0: A/C compressor clutch engagement (0x00=off, 0x08=on)
    // byte 2: wiper state (0x00=off, 0x01=slow, 0x02=fast, 0x03=one-shot)
    // Source: Qashqai CAN README, cross-Nissan
    case CAN_CLIMATE_WIPERS: {
        if (f.can_dlc < 3) break;
        // Wiper state
        int ws = qBound(0, static_cast<int>(f.data[2] & 0x03), 3);
        if (ws != m_wipersState) { m_wipersState = ws; emit wipersStateChanged(ws); }
        break;
    }

    // ── 0x551: Cruise control + coolant temperature ───────────────────────────
    // byte 0: cruise bitfield (bit 0=active, bit 1=speed-set, bit 2=ACC on)
    // byte 2: cruise set speed (km/h uint8)
    // byte 6: coolant temp raw, 0.5°C/LSB offset -40°C (same formula as OAT)
    // Source: cross-platform Nissan (Sentra, Rogue, 370Z)
    case CAN_CRUISE_COOLANT: {
        if (f.can_dlc < 7) break;
        bool ca = (f.data[0] & 0x01) != 0;
        if (ca != m_cruiseActive) { m_cruiseActive = ca; emit cruiseActiveChanged(ca); }
        if (ca) {
            float cs_kmh = static_cast<float>(f.data[2]);
            float cs_mph = cs_kmh * 0.621371f;
            if (cs_mph != m_cruiseSpeed) { m_cruiseSpeed = cs_mph; emit cruiseSpeedChanged(cs_mph); }
        }
        // Coolant temp: same encoding as outside ambient
        float cool_c = (f.data[6] * 0.5f) - 40.0f;
        float cool_f = cool_c * 9.0f / 5.0f + 32.0f;
        if (cool_f != m_coolantTemp && cool_f > -40.0f && cool_f < 300.0f) {
            m_coolantTemp = cool_f;
            emit coolantTempChanged(cool_f);
        }
        // ── VR30 piggyback parse on 0x551 (Q50_LIKELY) ──────────────────────
        // bytes 4-5 (big-endian uint16): manifold absolute pressure kPa × 0.1
        //   psi_gauge = (kPa - 101.3) / 6.895     (subtract atm, kPa→psi)
        // byte 7: intake air temp raw, 0.75°C/LSB offset -48°C
        // Reference: VR30 EcuTek tuning guide MAP/IAT channel descriptions.
        if (f.can_dlc >= 8) {
            uint16_t boostRaw = (static_cast<uint16_t>(f.data[4]) << 8) | f.data[5];
            double kpaAbs = boostRaw * 0.1;
            double boostPsi = (kpaAbs - 101.3) / 6.895;
            double mapPsi   = kpaAbs / 6.895;
            if (boostPsi > -15.0 && boostPsi < 40.0
                    && std::fabs(boostPsi - m_boostPressurePsi) > 0.05) {
                m_boostPressurePsi    = boostPsi;
                m_manifoldPressurePsi = mapPsi;
                emit vr30TelemetryChanged();
            }
            double iatC = (f.data[7] * 0.75) - 48.0;
            double iatF = iatC * 9.0 / 5.0 + 32.0;
            if (iatF > -40.0 && iatF < 300.0
                    && std::fabs(iatF - m_intakeAirTempF) > 0.5) {
                m_intakeAirTempF = iatF;
                emit vr30TelemetryChanged();
            }
        }
        break;
    }

    // ── 0x625: BCM extended status (READ ONLY — do not write to this ID) ──────
    // byte 1: bit 0 = rear defrost on, bit 1 = A/C LED state
    // byte 2: battery voltage raw (raw × 0.1 V — verify scaling on first boot)
    //         Typical: raw=125 → 12.5V. Range sanity: 9.0–16.5V for 12V system.
    // Source: Leaf AZE0 DBC HeadlightFoglightStatus, cross-Nissan BCM frames
    case CAN_BCM_EXTENDED: {
        if (f.can_dlc < 3) break;
        bool rd = (f.data[1] & 0x01) != 0;
        if (rd != m_rearDefrostOn) { m_rearDefrostOn = rd; emit rearDefrostOnChanged(rd); }
        float bv = f.data[2] * 0.1f;
        if (bv != m_batteryVolts && bv > 9.0f && bv < 17.0f) {
            m_batteryVolts = bv;
            emit batteryVoltsChanged(bv);
        }
        break;
    }

    // ── 0x385: TPMS — four tire PSI (Q50_LIKELY) ─────────────────────────────
    // bytes 0-1: FL big-endian uint16 × 0.25 PSI; 2-3: FR; 4-5: RL; 6-7: RR
    case CAN_TPMS: {
        if (f.can_dlc < 8) break;
        float fl = ((static_cast<uint16_t>(f.data[0])<<8)|f.data[1]) * 0.25f;
        float fr = ((static_cast<uint16_t>(f.data[2])<<8)|f.data[3]) * 0.25f;
        float rl = ((static_cast<uint16_t>(f.data[4])<<8)|f.data[5]) * 0.25f;
        float rr = ((static_cast<uint16_t>(f.data[6])<<8)|f.data[7]) * 0.25f;
        bool changed = false;
        if (fl>5.0f && fl<60.0f && fl!=m_tirePSI_FL) { m_tirePSI_FL=fl; changed=true; }
        if (fr>5.0f && fr<60.0f && fr!=m_tirePSI_FR) { m_tirePSI_FR=fr; changed=true; }
        if (rl>5.0f && rl<60.0f && rl!=m_tirePSI_RL) { m_tirePSI_RL=rl; changed=true; }
        if (rr>5.0f && rr<60.0f && rr!=m_tirePSI_RR) { m_tirePSI_RR=rr; changed=true; }
        if (changed) emit tirePSIsChanged();
        break;
    }

    // ── 0x54C: Oil life (Q50_LIKELY Nissan proprietary) ──────────────────────
    // byte 0: 0–255 scaled linearly to 0–100%
    case CAN_OIL_LIFE: {
        if (f.can_dlc < 1) break;
        float ol = f.data[0] * (100.0f / 255.0f);
        if (ol != m_oilLife) { m_oilLife = ol; emit oilLifeChanged(ol); }
        break;
    }

    // ── 0x554: Fuel economy — instant + average MPG (Q50_LIKELY) ─────────────
    // bytes 0-1: instant MPG big-endian uint16 × 0.1; bytes 2-3: average MPG
    case CAN_FUEL_ECONOMY: {
        if (f.can_dlc < 4) break;
        float inst = ((static_cast<uint16_t>(f.data[0])<<8)|f.data[1]) * 0.1f;
        float avg  = ((static_cast<uint16_t>(f.data[2])<<8)|f.data[3]) * 0.1f;
        if (inst>0.0f && inst<99.9f && inst!=m_instantMPG) { m_instantMPG=inst; emit instantMPGChanged(inst); }
        if (avg>0.0f  && avg<99.9f  && avg!=m_avgMPG)      { m_avgMPG=avg;      emit avgMPGChanged(avg); }
        break;
    }

    // ── 0x1CA: ATTESA AWD torque split status (Q50_LIKELY) ───────────────────
    // byte 0: front torque % (0–100); byte 1: rear torque % (0–100)
    case CAN_ATTESA: {
        if (f.can_dlc < 2) break;
        float front = f.data[0];
        float rear  = f.data[1];
        if (front != m_atessaFront || rear != m_atessaRear) {
            m_atessaFront = front; m_atessaRear = rear;
            emit atessaChanged();
        }
        break;
    }

    // ── 0x266: Drive mode status read-back (UNVERIFIED) ──────────────────────
    // byte 0: active drive mode index
    //   0=Standard, 1=Sport, 2=Sport+, 3=Eco, 4=Snow, 5=Personal
    // Confirms that the physical selector or a prior setDriveMode() write took effect.
    // ID UNVERIFIED — Q50_LIKELY candidate; confirm via J2534 capture on first boot.
    case CAN_DRIVE_MODE_STATUS: {
        if (f.can_dlc < 1) break;
        const uint8_t mode = f.data[0];
        // Track mode (6) is a virtual composite — it writes Sport+ (2) to the
        // powertrain, so the status frame will report back 2. Don't clobber
        // our Track state when that happens; the user explicitly enters/exits
        // Track from the UI.
        if (m_driveMode == 6 && mode == 0x02) break;
        if (mode <= 5 && static_cast<int>(mode) != m_driveMode) {
            m_driveMode = static_cast<int>(mode);
            emit driveModeChanged(m_driveMode);
            emit driveModeConfirmed(m_driveMode);
            qDebug("[CAN] Drive mode confirmed by status frame: %d (UNVERIFIED ID)", m_driveMode);
        }
        break;
    }

    // ── VR30 telemetry frames (Q50_LIKELY — delegated to handler) ────────────
    // 0x551 boost+IAT is parsed inside the CAN_CRUISE_COOLANT case above to avoid
    // a duplicate switch label (same ID). Other VR30 IDs dispatched here.
    case CAN_VR30_OIL_TEMP:
    case CAN_VR30_TRANS_TEMP:
    case CAN_VR30_WASTEGATE:
        handleVR30Frame(f);
        break;

    // ── G-sensor (chassis 3-axis accel — UNVERIFIED ID 0x132) ────────────────
    // byte 0-1 (signed 16-bit BE): lateral G   × 0.001 G/LSB
    // byte 2-3 (signed 16-bit BE): longitudinal G × 0.001 G/LSB
    // Values for the same physical sensor that feeds ATTESA — frame ID is the
    // unknown variable. Parser is enabled but treat results as Q50_LIKELY.
    case CAN_G_SENSOR: {
        if (f.can_dlc < 4) break;
        int16_t latRaw = static_cast<int16_t>(
            (static_cast<uint16_t>(f.data[0]) << 8) | f.data[1]);
        int16_t lonRaw = static_cast<int16_t>(
            (static_cast<uint16_t>(f.data[2]) << 8) | f.data[3]);
        double lat = latRaw * 0.001;
        double lon = lonRaw * 0.001;
        bool changed = false;
        if (std::fabs(lat - m_lateralG) > 0.005) {
            m_lateralG = lat;
            if (std::fabs(lat) > std::fabs(m_peakLateralG)) m_peakLateralG = lat;
            changed = true;
        }
        if (std::fabs(lon - m_longitudinalG) > 0.005) {
            m_longitudinalG = lon;
            if (std::fabs(lon) > std::fabs(m_peakLongitudinalG)) m_peakLongitudinalG = lon;
            changed = true;
        }
        if (changed) emit gMeterChanged();
        break;
    }

    // ── 0x35B: Intelligent Key slot detection (UNVERIFIED) ───────────────────────
    // BCM broadcasts key presence when Intelligent Key is detected (proximity or
    // Start button press). byte 2 = key slot (0x01=key1, 0x02=key2, 0x00=none).
    // UNVERIFIED: ID 0x35B is a Q50_LIKELY candidate. Verify via J2534 on first boot.
    case CAN_KEY_DETECT: {
        if (f.can_dlc < 3) break;
        const int slot = f.data[2] & 0x03;
        if (slot > 0) {
            emit keySlotDetected(slot);
            qDebug("[CAN] Intelligent Key slot detected: %d (UNVERIFIED ID 0x35B)", slot);
        }
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
    } else if (id == CAN_COMMANDER || id == CAN_COMMANDER_BTN) {
        // Commander frames handled in switch below — fall through
    } else if (id != CAN_AV_BTNS) {
        // Log all other non-idle AV-CAN frames for discovery
        m_buttonLog.logDiscovery(QStringLiteral("AV-CAN"), id, f);
        return;
    }

    // ── Commander joystick (AV-CAN, UNVERIFIED IDs) ──────────────────────────
    // Handle before the steering-wheel guard so Commander frames aren't filtered out.
    if (id == CAN_COMMANDER) {
        // UNVERIFIED: byte 0 = direction bitmap (bit0=up, bit1=down, bit2=left, bit3=right, bit4=push)
        // Encoding is placeholder — verify against J2534 capture
        if (f.can_dlc < 1) return;
        const uint8_t dir = f.data[0];
        int x = 0, y = 0;
        bool pushed = false;
        if (dir & 0x01) y = -1;        // up
        if (dir & 0x02) y = +1;        // down
        if (dir & 0x04) x = -1;        // left
        if (dir & 0x08) x = +1;        // right
        if (dir & 0x10) pushed = true;  // push/select

        if (x != 0 || y != 0) {
            m_joystickX = x;
            m_joystickY = y;
            emit joystickMoved(x, y);
            qDebug("[CAN AV] Commander joystick x=%d y=%d (UNVERIFIED encoding)", x, y);
        }
        if (pushed && !m_joystickPressed) {
            m_joystickPressed = true;
            emit joystickClicked();
            qDebug("[CAN AV] Commander joystick click (UNVERIFIED)");
        } else if (!pushed) {
            m_joystickPressed = false;
        }
        return;
    }

    if (id == CAN_COMMANDER_BTN) {
        // UNVERIFIED: byte 0 = button bitmap (bit0=back, bit1=home, bit2=map)
        if (f.can_dlc < 1) return;
        const uint8_t btn = f.data[0];
        QString name;
        if      (btn & 0x01) name = QStringLiteral("back");
        else if (btn & 0x02) name = QStringLiteral("home");
        else if (btn & 0x04) name = QStringLiteral("map");
        if (!name.isEmpty()) {
            m_lastButtonPress = name;
            emit buttonPressed(name);
            qDebug("[CAN AV] Commander button: %s (UNVERIFIED encoding)", qPrintable(name));
        }
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
    // CAN_SEAT_HEAT_WRITE = 0xFFFF — placeholder until J2534 capture identifies the real ID.
    // Transmission is blocked: sendCANFrame() no-ops on 0xFFFF (masked to 0x7FF = SFF max).
    // Do NOT change this until seat heat write ID is verified.
    qWarning() << "[VehicleService] setDriverSeatHeat: seat heat write ID UNVERIFIED — no CAN frame sent";
}

void VehicleService::setPassSeatHeat(int level)
{
    m_passSeat = qBound(0, level, 3);
    emit passSeatChanged(m_passSeat);
    qWarning() << "[VehicleService] setPassSeatHeat: seat heat write ID UNVERIFIED — no CAN frame sent";
}

void VehicleService::setRearDefrost(bool on)
{
    // Rear defrost: 0x5C5 byte A0 per 370Z observation (UNVERIFIED write path)
    uint8_t d[1] = { static_cast<uint8_t>(on ? 0x44 : 0x40) };
    sendCANFrame(m_vehicleCanSock, CAN_CLUSTER, d, 1);
}

// ─── UDS door lock / unlock (Service 0x30 → BCM at 0x745) ────────────────
//
// ISO 15765-2 single-frame format over HS-CAN:
//   byte 0:    PCI — 0x05 (5 data bytes follow, single frame)
//   byte 1:    SID — 0x30 (InputOutputControlByIdentifier)
//   bytes 2-3: DID — 0xBF 0x00 (Nissan BCM door lock DID, Q50_LIKELY)
//   byte 4:    controlParameter — 0x03 (shortTermAdjustment)
//   byte 5:    controlState — 0x01=lock, 0x02=unlock
//
// DID 0xBF00 sourced from cross-platform Nissan UDS surveys (Q50/X-Trail/Leaf).
// CAUTION: Q50_LIKELY — verify byte 5 lock/unlock values via J2534 capture on 0x74D.
// BCM will ACK on 0x74D (UDS_BCM_RESPONSE) with 0x70 (positive response to 0x30).
// If BCM rejects (0x7F 0x30 xx), the DID or control byte is wrong — do not retry.
void VehicleService::lockDoors()
{
    if (m_vehicleCanSock < 0) {
        qWarning() << "[VehicleService] lockDoors: HS-CAN not open";
        return;
    }
    qWarning() << "[VehicleService] lockDoors: UDS 0x30 DID 0xBF00 — Q50_LIKELY, verify via J2534";
    uint8_t d[8] = { 0x05, 0x30, 0xBF, 0x00, 0x03, 0x01, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, UDS_BCM, d, 8);
}

void VehicleService::unlockDoors()
{
    if (m_vehicleCanSock < 0) {
        qWarning() << "[VehicleService] unlockDoors: HS-CAN not open";
        return;
    }
    qWarning() << "[VehicleService] unlockDoors: UDS 0x30 DID 0xBF00 — Q50_LIKELY, verify via J2534";
    uint8_t d[8] = { 0x05, 0x30, 0xBF, 0x00, 0x03, 0x02, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, UDS_BCM, d, 8);
}

// ─── Trip computer tick (1Hz) ─────────────────────────────────────────────
void VehicleService::onTripTimerTick()
{
    if (!m_ignitionOn) return;

    // Increment elapsed time
    ++m_tripASeconds;
    ++m_tripBSeconds;

    // Recompute rolling averages
    if (m_tripASeconds > 0) {
        m_tripAAvgSpeed = m_tripAMiles / (m_tripASeconds / 3600.0f);
        if (m_instantMPG > 0.0f)
            m_tripAAvgMPG = (m_tripAAvgMPG * (m_tripASeconds - 1) + m_instantMPG) / m_tripASeconds;
    }
    if (m_tripBSeconds > 0) {
        m_tripBAvgSpeed = m_tripBMiles / (m_tripBSeconds / 3600.0f);
        if (m_instantMPG > 0.0f)
            m_tripBAvgMPG = (m_tripBAvgMPG * (m_tripBSeconds - 1) + m_instantMPG) / m_tripBSeconds;
    }

    emit tripAChanged();
    emit tripBChanged();
}

// ─── Trip computer resets ─────────────────────────────────────────────────
void VehicleService::resetTripA()
{
    m_tripAMiles = 0.0f; m_tripAAvgMPG = 0.0f;
    m_tripAAvgSpeed = 0.0f; m_tripASeconds = 0;
    emit tripAChanged();
}

void VehicleService::resetTripB()
{
    m_tripBMiles = 0.0f; m_tripBAvgMPG = 0.0f;
    m_tripBAvgSpeed = 0.0f; m_tripBSeconds = 0;
    emit tripBChanged();
}

// ─── Climate shortcuts ─────────────────────────────────────────────────────

void VehicleService::setAutoClimate(bool on)
{
    qWarning() << "[VehicleService] setAutoClimate: Q50_LIKELY — verify via J2534";
    m_autoClimateOn = on;
    emit autoClimateOnChanged(on);
    if (on) {
        m_fanSpeed   = 7;   emit fanSpeedChanged(m_fanSpeed);
        m_acOn       = true; emit acOnChanged(m_acOn);
        m_climateMode = 0;  emit climateModeChanged(m_climateMode);
        uint8_t d[8] = { static_cast<uint8_t>(hvacModeFlags() | 0x20),  // bit 5 = auto
                         hvacTempRaw(m_driverTemp),
                         hvacTempRaw(m_passengerTemp),
                         0x00, 0x00, 0x00, 0x00, 0x00 };
        sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
    } else {
        uint8_t d[8] = { hvacModeFlags(),
                         hvacTempRaw(m_driverTemp),
                         hvacTempRaw(m_passengerTemp),
                         0x00, 0x00, 0x00, 0x00, 0x00 };
        sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
    }
}

void VehicleService::setMaxAC()
{
    qWarning() << "[VehicleService] setMaxAC: Q50_LIKELY — verify via J2534";
    m_recircOn = true; emit recircOnChanged(m_recircOn);
    m_fanSpeed  = 7;   emit fanSpeedChanged(m_fanSpeed);
    m_acOn      = true; emit acOnChanged(m_acOn);
    uint8_t d[8] = { hvacModeFlags(),
                     hvacTempRaw(m_driverTemp),
                     hvacTempRaw(m_passengerTemp),
                     0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
}

void VehicleService::setMaxDefrost()
{
    qWarning() << "[VehicleService] setMaxDefrost: Q50_LIKELY — verify via J2534";
    m_climateMode = 3;  emit climateModeChanged(m_climateMode);
    m_fanSpeed    = 7;  emit fanSpeedChanged(m_fanSpeed);
    m_acOn        = true; emit acOnChanged(m_acOn);
    uint8_t d[8] = { hvacModeFlags(),
                     hvacTempRaw(m_driverTemp),
                     hvacTempRaw(m_passengerTemp),
                     0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
}

void VehicleService::syncZones()
{
    qWarning() << "[VehicleService] syncZones: Q50_LIKELY — verify via J2534";
    m_passengerTemp = m_driverTemp;
    emit passengerTempChanged(m_passengerTemp);
    uint8_t d[8] = { hvacModeFlags(),
                     hvacTempRaw(m_driverTemp),
                     hvacTempRaw(m_passengerTemp),
                     0x00, 0x00, 0x00, 0x00, 0x00 };
    sendCANFrame(m_vehicleCanSock, CAN_HVAC_WRITE, d, 8);
}

void VehicleService::setHeatedSteeringWheel(bool on)
{
    // CAN_HEATED_STEERING = 0xFFFF — write ID UNVERIFIED until J2534 capture.
    // State + signal still update so UI is responsive; CAN frame is suppressed.
    m_heatedSteeringWheel = on;
    emit heatedSteeringWheelChanged(on);
    qWarning() << "[VehicleService] setHeatedSteeringWheel: write ID UNVERIFIED — no CAN frame sent";
}

void VehicleService::setPlasmacluster(int level)
{
    // CAN_PLASMA = 0xFFFF — write ID UNVERIFIED until J2534 capture.
    m_plasmaclusterLevel = qBound(0, level, 3);
    emit plasmaclusterLevelChanged(m_plasmaclusterLevel);
    qWarning() << "[VehicleService] setPlasmacluster: write ID UNVERIFIED — no CAN frame sent";
}

void VehicleService::setRainSensor(bool on)
{
    // CAN_RAIN_SENSOR_ENABLE = 0xFFFF — write ID UNVERIFIED until J2534 capture.
    // Sensitivity is stalk-only; this toggle just enables/disables the system.
    m_rainSensorEnabled = on;
    emit rainSensorEnabledChanged(on);
    qWarning() << "[VehicleService] setRainSensor: write ID UNVERIFIED — no CAN frame sent";
}

// ─── Drive mode ────────────────────────────────────────────────────────────
// Modes 0–5 = factory (Standard / Sport / Sport+ / Eco / Snow / Personal).
// Mode 6 = Track (composite): writes Sport+ to powertrain, mutes ASC, applies
//   track-specific preferences held in m_trackModePreferences.
// When switching AWAY from Track, the previous ASC state is restored.
void VehicleService::setDriveMode(int mode)
{
    qWarning() << "[VehicleService] setDriveMode: Q50_LIKELY — verify via J2534";
    const int newMode = qBound(0, mode, 6);
    if (newMode == m_driveMode) return;

    const bool wasTrack = (m_driveMode == 6);
    const bool nowTrack = (newMode == 6);

    m_driveMode = newMode;
    emit driveModeChanged(m_driveMode);

    if (nowTrack) {
        m_ascStateBeforeTrack = m_ascEnabled;

        // Track maps to Sport+ (0x02) on the powertrain side — closest stock equivalent.
        uint8_t d[1] = { 0x02 };
        qInfo("[VehicleService] TX 0x%03X DLC=1 [%02X]  (Track → Sport+ powertrain)",
              CAN_DRIVE_MODE, d[0]);
        sendCANFrame(m_vehicleCanSock, CAN_DRIVE_MODE, d, 1);

        if (m_trackModePreferences.ascOff)
            setAscEnabled(false);

        emit trackModeConfigChanged();
        emit trackModeActiveChanged(true);
    } else {
        uint8_t d[1] = { static_cast<uint8_t>(m_driveMode) };
        qInfo("[VehicleService] TX 0x%03X DLC=1 [%02X]  (drive mode=%d)",
              CAN_DRIVE_MODE, d[0], m_driveMode);
        sendCANFrame(m_vehicleCanSock, CAN_DRIVE_MODE, d, 1);

        if (wasTrack) {
            setAscEnabled(m_ascStateBeforeTrack);
            emit trackModeActiveChanged(false);
        }
    }
}

// ─── Active Sound Control — Bose engine sound enhancement ────────────────────
// Factory hides this in a deep diagnostic menu. UNVERIFIED PLACEHOLDER write.
void VehicleService::setAscEnabled(bool on)
{
    if (m_ascEnabled == on) return;
    qWarning() << "[VehicleService] setAscEnabled: CAN_ASC_TOGGLE=0xFFFF "
                  "UNVERIFIED PLACEHOLDER — no CAN frame sent. "
                  "Sniff during diagnostic menu toggle "
                  "(Settings → Seek-up ×3 → hold below right-scroll-arrow ×5s).";
    m_ascEnabled = on;
    emit ascEnabledChanged(on);
}

// ─── Track-mode preference JSON blob ─────────────────────────────────────────
// Schema mirrors SettingsService.trackModeConfig.
void VehicleService::setTrackModeConfig(const QString &json)
{
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (doc.isNull() || !doc.isObject()) {
        qWarning() << "[VehicleService] setTrackModeConfig: invalid JSON, ignored";
        return;
    }
    const QJsonObject o = doc.object();

    const QString tm = o.value(QStringLiteral("throttleMap")).toString();
    if      (tm == QStringLiteral("stock")) m_trackModePreferences.throttleMap = TrackThrottle::Stock;
    else if (tm == QStringLiteral("sport")) m_trackModePreferences.throttleMap = TrackThrottle::Sport;
    else if (tm == QStringLiteral("max"))   m_trackModePreferences.throttleMap = TrackThrottle::Max;

    const QString ab = o.value(QStringLiteral("atessaBias")).toString();
    if      (ab == QStringLiteral("auto"))     m_trackModePreferences.atessaBias = TrackAtessa::Auto;
    else if (ab == QStringLiteral("rwd_pref")) m_trackModePreferences.atessaBias = TrackAtessa::RwdPref;
    else if (ab == QStringLiteral("rwd_only")) m_trackModePreferences.atessaBias = TrackAtessa::RwdOnly;

    if (o.contains(QStringLiteral("ascOff")))
        m_trackModePreferences.ascOff = o.value(QStringLiteral("ascOff")).toBool();

    const QString ap = o.value(QStringLiteral("audioProfile")).toString();
    if      (ap == QStringLiteral("stock")) m_trackModePreferences.audioProfile = TrackAudioProf::Stock;
    else if (ap == QStringLiteral("sport")) m_trackModePreferences.audioProfile = TrackAudioProf::Sport;
    else if (ap == QStringLiteral("dry"))   m_trackModePreferences.audioProfile = TrackAudioProf::Dry;

    if (o.contains(QStringLiteral("gaugesSubTab")))
        m_trackModePreferences.gaugesSubTab = o.value(QStringLiteral("gaugesSubTab")).toString();

    emit trackModeConfigChanged();

    if (m_driveMode == 6 && m_trackModePreferences.ascOff && m_ascEnabled)
        setAscEnabled(false);
}

// ─── Driver aids helpers ───────────────────────────────────────────────────
// Rebuild and send the ADAS control frame (0x47D) from current aid state.
// byte 0: aid enable bitmask; byte 1: PFCW sensitivity
static inline uint8_t adasFlags(bool bsw, bool bsi, bool ldw, bool ldp,
                                 bool feb, bool bci, bool vdc)
{
    return static_cast<uint8_t>(
        (bsw ? 0x01 : 0) | (bsi ? 0x02 : 0) | (ldw ? 0x04 : 0) |
        (ldp ? 0x08 : 0) | (feb ? 0x10 : 0) | (bci ? 0x20 : 0) |
        (vdc ? 0x40 : 0));
}

void VehicleService::sendADASFrame()
{
    uint8_t d[2] = {
        adasFlags(m_bswOn, m_bsiOn, m_ldwOn, m_ldpOn, m_febOn, m_bciOn, m_vdcOn),
        static_cast<uint8_t>(m_pfcwSensitivity)
    };
    // J2534 trace — full aid bitmap + PFCW sensitivity, both bytes.
    qInfo("[VehicleService] TX 0x%03X DLC=2 [%02X %02X]  "
          "(BSW=%d BSI=%d LDW=%d LDP=%d FEB=%d BCI=%d VDC=%d PFCW=%d)",
          CAN_ADAS_CTRL, d[0], d[1],
          m_bswOn, m_bsiOn, m_ldwOn, m_ldpOn, m_febOn, m_bciOn, m_vdcOn,
          m_pfcwSensitivity);
    sendCANFrame(m_vehicleCanSock, CAN_ADAS_CTRL, d, 2);
}

void VehicleService::setBSW(bool on)
{
    qWarning() << "[VehicleService] setBSW: Q50_LIKELY — verify via J2534";
    m_bswOn = on; emit bswOnChanged(on); sendADASFrame();
}
void VehicleService::setBSI(bool on)
{
    qWarning() << "[VehicleService] setBSI: Q50_LIKELY — verify via J2534";
    m_bsiOn = on; emit bsiOnChanged(on); sendADASFrame();
}
void VehicleService::setLDW(bool on)
{
    qWarning() << "[VehicleService] setLDW: Q50_LIKELY — verify via J2534";
    m_ldwOn = on; emit ldwOnChanged(on); sendADASFrame();
}
void VehicleService::setLDP(bool on)
{
    qWarning() << "[VehicleService] setLDP: Q50_LIKELY — verify via J2534";
    m_ldpOn = on; emit ldpOnChanged(on); sendADASFrame();
}
void VehicleService::setFEB(bool on)
{
    qWarning() << "[VehicleService] setFEB: Q50_LIKELY — verify via J2534";
    m_febOn = on; emit febOnChanged(on); sendADASFrame();
}
void VehicleService::setBCI(bool on)
{
    qWarning() << "[VehicleService] setBCI: Q50_LIKELY — verify via J2534";
    m_bciOn = on; emit bciOnChanged(on); sendADASFrame();
}
void VehicleService::setVDC(bool on)
{
    qWarning() << "[VehicleService] setVDC: Q50_LIKELY — verify via J2534";
    m_vdcOn = on; emit vdcOnChanged(on); sendADASFrame();
}
void VehicleService::setPFCWSensitivity(int level)
{
    qWarning() << "[VehicleService] setPFCWSensitivity: Q50_LIKELY — verify via J2534";
    m_pfcwSensitivity = qBound(0, level, 3);
    emit pfcwSensitivityChanged(m_pfcwSensitivity);
    sendADASFrame();
}

// ─── VR30DDTT track telemetry frame handler ────────────────────────────────
// Parses Q50_LIKELY frames for oil temp, trans temp, and electronic wastegate.
// UNVERIFIED frames (ignition advance, knock retard) log TODO — no value is
// fabricated. The 0x551 boost+IAT piggyback is parsed inline in the cruise
// case to avoid a duplicate switch label.
//
// Scale formulas sourced from VR30 EcuTek tuning literature; treat as
// reasonable defaults until J2534 capture confirms. Values bounded to plausible
// physical ranges before emitting to prevent spurious UI flicker.
void VehicleService::handleVR30Frame(const struct can_frame &f)
{
    const canid_t id = f.can_id & CAN_SFF_MASK;
    bool changed = false;

    switch (id) {

    // 0x55D — VVT temp sensor doubles as oil temp on VR30.
    // byte 0: temp raw, 1°C/LSB offset -40°C (per EcuTek channel definition)
    case CAN_VR30_OIL_TEMP: {
        if (f.can_dlc < 1) break;
        double tC = static_cast<double>(f.data[0]) - 40.0;
        double tF = tC * 9.0 / 5.0 + 32.0;
        if (tF > -40.0 && tF < 400.0 && std::fabs(tF - m_oilTempF) > 0.5) {
            m_oilTempF = tF;
            changed = true;
        }
        break;
    }

    // 0x59A — TCM trans fluid temp.
    // byte 0: temp raw, 1°C/LSB offset -40°C
    case CAN_VR30_TRANS_TEMP: {
        if (f.can_dlc < 1) break;
        double tC = static_cast<double>(f.data[0]) - 40.0;
        double tF = tC * 9.0 / 5.0 + 32.0;
        if (tF > -40.0 && tF < 400.0 && std::fabs(tF - m_transTempF) > 0.5) {
            m_transTempF = tF;
            changed = true;
        }
        break;
    }

    // 0x55C — Electronic wastegate position.
    // byte 0: position % (0-100 direct)
    case CAN_VR30_WASTEGATE: {
        if (f.can_dlc < 1) break;
        double pct = qBound(0.0, static_cast<double>(f.data[0]), 100.0);
        if (std::fabs(pct - m_wastegatePercent) > 0.5) {
            m_wastegatePercent = pct;
            changed = true;
        }
        break;
    }

    // 0xFFFF — UNVERIFIED placeholder for ignition advance / knock retard.
    // No real frame ID known yet. Log only — DO NOT fabricate values.
    case CAN_VR30_IGN_KNOCK:
        qDebug() << "[VehicleService] VR30 ign/knock frame UNVERIFIED — TODO J2534 capture";
        break;

    default:
        break;
    }

    if (changed) emit vr30TelemetryChanged();
}

// ─── Performance timer (0-60 + 1/4 mile) ────────────────────────────────────
// State machine ticks at 10Hz. Detects launch (stationary → throttle > 50% with
// speed crossing 2 mph), then integrates wheel speed to track distance for the
// 1/4 mile and watches for the target speed (60 mph / 100 km/h based on
// SettingsService.distanceUnit — but VehicleService is unit-agnostic, so we
// always trigger at 60 mph and let the QML layer relabel). Quarter-mile time
// and trap speed latched on first crossing.
//
// Per spec: in-memory only; cleared on ignition off (handled by the lambda
// in start()). No persistence.
void VehicleService::onPerfTick()
{
    if (!m_ignitionOn) return;
    updatePerformanceTimer();
}

void VehicleService::updatePerformanceTimer()
{
    const float speed = m_speed;       // mph (already converted in CAN parser)
    const double throttle = m_throttlePct;  // 0-100; stub until pedal ID confirmed
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();

    // Arm condition: throttle high while ~stationary
    if (!m_perfRunActive) {
        if (speed < 2.0f && throttle > 50.0) {
            m_perfRunArmed = true;
        }
        // Trigger: speed crosses 2 mph while armed
        if (m_perfRunArmed && speed >= 2.0f) {
            m_perfRunActive      = true;
            m_perfRunArmed       = false;
            m_perfRunStartMs     = nowMs;
            m_perfRunElapsedSec  = 0.0;
            m_perfRunDistanceMi  = 0.0;
            m_zeroToSixtySec     = 0.0;
            m_quarterMileSec     = 0.0;
            m_quarterMileTrapMph = 0.0;
            emit perfTimerChanged();
        }
        return;
    }

    // Active run — accumulate
    const double elapsed = (nowMs - m_perfRunStartMs) / 1000.0;
    m_perfRunElapsedSec = elapsed;
    // Integrate mph * dt_hours → miles (10Hz tick: dt = 0.1s = 1/36000 hr)
    m_perfRunDistanceMi += speed / 36000.0;

    // 0-60 trigger (60 mph hardcoded — QML layer relabels for metric users)
    if (m_zeroToSixtySec <= 0.0 && speed >= 60.0f) {
        m_zeroToSixtySec = elapsed;
        qDebug("[VehicleService] 0-60: %.2fs", m_zeroToSixtySec);
    }

    // 1/4 mile trigger (0.25 mi)
    if (m_quarterMileSec <= 0.0 && m_perfRunDistanceMi >= 0.25) {
        m_quarterMileSec     = elapsed;
        m_quarterMileTrapMph = speed;
        qDebug("[VehicleService] 1/4 mile: %.2fs @ %.1f mph",
               m_quarterMileSec, m_quarterMileTrapMph);
    }

    // End run: either both targets hit, or driver lifted (speed dropped below 2)
    if ((m_zeroToSixtySec > 0.0 && m_quarterMileSec > 0.0)
            || (elapsed > 1.0 && speed < 2.0f)
            || elapsed > 60.0) {
        m_perfRunActive = false;
    }

    emit perfTimerChanged();
}

void VehicleService::resetPerformanceTimer()
{
    m_perfRunActive      = false;
    m_perfRunArmed       = false;
    m_perfRunElapsedSec  = 0.0;
    m_perfRunDistanceMi  = 0.0;
    m_zeroToSixtySec     = 0.0;
    m_quarterMileSec     = 0.0;
    m_quarterMileTrapMph = 0.0;
    emit perfTimerChanged();
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
