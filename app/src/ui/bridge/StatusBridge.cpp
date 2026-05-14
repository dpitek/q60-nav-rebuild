// StatusBridge.cpp
// Zero-copy signal relay between services and both QML windows.
// Single source of truth for all cross-screen state.

#include "StatusBridge.h"
#include "../../services/navigation/NavigationService.h"
#include "../../services/vehicle/VehicleService.h"
#include "../../services/audio/AudioService.h"
#include "../../services/network/NetworkService.h"
#include "../../services/parking/ParkingService.h"

#include <QTimer>
#include <QDateTime>
#include <QDebug>

StatusBridge::StatusBridge(NavigationService *nav,
                            VehicleService   *vehicle,
                            AudioService     *audio,
                            NetworkService   *network,
                            ParkingService   *parking,
                            QObject *parent)
    : QObject(parent)
    , m_nav(nav)
    , m_vehicle(vehicle)
    , m_audio(audio)
    , m_network(network)
    , m_parking(parking)
    , m_clockTimer(new QTimer(this))
{
    // ── Navigation ──────────────────────────────────────────────────────
    connect(nav, &NavigationService::activeChanged, this, [this](bool active) {
        if (m_navActive != active) {
            m_navActive = active;
            emit navActiveChanged(active);
        }
    });

    connect(nav, &NavigationService::instructionChanged, this, [this]() {
        m_nextStreet   = m_nav->nextStreet();
        m_nextManeuver = m_nav->nextManeuver();
        m_nextDistance = m_nav->nextDistance();
        emit navInstructionChanged();

        // Trigger turn banner on lower screen when approaching turn
        bool approaching = m_nextDistance > 0.0 && m_nextDistance < TURN_BANNER_MILES;
        if (approaching != m_approachingTurn) {
            m_approachingTurn = approaching;
            emit approachingTurnChanged(approaching);
            if (approaching) emit showTurnBanner();
        }
    });

    connect(nav, &NavigationService::etaChanged, this, [this](const QString &eta) {
        m_eta = eta;
        emit etaChanged(eta);
    });

    connect(nav, &NavigationService::remainingChanged, this, [this](double rem) {
        Q_UNUSED(rem)
        // remaining is read directly from m_nav in QML via bridge
    });

    connect(nav, &NavigationService::positionChanged, this,
            [this](const QGeoCoordinate &pos) {
        // GPS lock derived from valid position
        bool hasLock = pos.isValid();
        if (hasLock != m_gpsLock) {
            m_gpsLock = hasLock;
            emit gpsLockChanged(hasLock);
        }
        // Expose coordinates to QML map
        if (hasLock) {
            m_latitude  = pos.latitude();
            m_longitude = pos.longitude();
            emit positionChanged();
        }
    });

    // ── Vehicle ─────────────────────────────────────────────────────────
    connect(vehicle, &VehicleService::speedChanged, this, [this](float speed) {
        m_speed = speed;
        emit speedChanged();
    });

    connect(vehicle, &VehicleService::speedLimitChanged, this, [this](float limit) {
        m_speedLimit = limit;
        emit speedChanged(); // same signal covers both
    });

    connect(vehicle, &VehicleService::reverseChanged, this, [this](bool rev) {
        if (rev != m_reverseActive) {
            m_reverseActive = rev;
            emit reverseActiveChanged(rev);
        }
    });

    connect(vehicle, &VehicleService::outsideTempChanged, this, [this](float temp) {
        m_outsideTemp = temp;
        emit outsideTempChanged(temp);
    });

    // Steering wheel → audio passthrough
    connect(vehicle, &VehicleService::volUp,   m_audio, [this]() {
        m_audio->setVolume(qMin(100, m_audio->volume() + 3));
    });
    connect(vehicle, &VehicleService::volDown, m_audio, [this]() {
        m_audio->setVolume(qMax(0, m_audio->volume() - 3));
    });
    connect(vehicle, &VehicleService::seekFwd,  m_audio, &AudioService::btNext);
    connect(vehicle, &VehicleService::seekBack, m_audio, &AudioService::btPrev);

    // ── Audio ────────────────────────────────────────────────────────────
    connect(audio, &AudioService::sourceChanged, this, [this](AudioService::AudioSource src) {
        bool sxm = (src == AudioService::SXM);
        if (sxm != m_sxmActive) {
            m_sxmActive = sxm;
            emit sxmActiveChanged(sxm);
        }
    });

    connect(audio, &AudioService::btConnectionChanged, this, [this](bool connected) {
        if (connected != m_btConnected) {
            m_btConnected = connected;
            emit btConnectedChanged(connected);
        }
    });

    // Bose wake delegation: AudioService → VehicleService
    connect(audio, &AudioService::bossWakeRequested,
            vehicle, &VehicleService::wakeBosse);

    // ── Clock ────────────────────────────────────────────────────────────
    m_clockTimer->setInterval(30000); // update every 30s
    connect(m_clockTimer, &QTimer::timeout, this, &StatusBridge::onClockTick);
    m_clockTimer->start();
    onClockTick(); // populate immediately

    // ── Parking → Navigation forwarding ─────────────────────────────────
    // ParkingService::navigateToCar() emits navigateRequested(lat, lon, label);
    // forward to NavigationService::routeTo so the existing route-start path
    // handles the request (Valhalla query, map overlay, turn-by-turn).
    if (m_parking) {
        connect(m_parking, &ParkingService::navigateRequested,
                m_nav,     &NavigationService::routeTo);
    }

    // ── Network ──────────────────────────────────────────────────────────
    if (m_network) {
        connect(m_network, &NetworkService::onlineChanged, this, [this](bool online) {
            if (online != m_networkOnline) {
                m_networkOnline = online;
                emit networkChanged();
            }
        });
        connect(m_network, &NetworkService::signalChanged, this, [this]() {
            m_signalStrength = m_network->signalStrength();
            m_networkType    = m_network->networkType();
            emit networkChanged();
        });
    }
}

// ─── Clock ─────────────────────────────────────────────────────────────────
void StatusBridge::onClockTick()
{
    QString t = QDateTime::currentDateTime().toString("h:mm AP");
    if (t != m_timeString) {
        m_timeString = t;
        emit timeChanged(t);
    }
}

// ─── Nav instruction relay ─────────────────────────────────────────────────
void StatusBridge::onNavInstruction()
{
    // Already handled in lambda above — keep this slot for explicit wiring
}

// ─── Speed relay ───────────────────────────────────────────────────────────
void StatusBridge::onSpeedUpdate(double speed)
{
    m_speed = speed;
    emit speedChanged();
}

// ─── Reverse ───────────────────────────────────────────────────────────────
void StatusBridge::onReverseEngaged(bool reverse)
{
    m_reverseActive = reverse;
    emit reverseActiveChanged(reverse);
    // Lower screen camera view is triggered in QML by binding reverseActive
}

// ─── AVM activation ────────────────────────────────────────────────────────
// Triggered from QML by corner-badge tap or, eventually, from VehicleService
// when gear=R AND the AVM steering-wheel button is held. The actual camera
// pipeline (4× V4L2 feeds) wires later — this is the activation channel that
// both screens listen on so the upper-screen overlay and lower-screen tab can
// react in lockstep.
void StatusBridge::setAvmActive(bool active)
{
    if (m_avmActive == active) return;
    m_avmActive = active;
    emit avmActiveChanged(active);
}

// ─── Phone call events ─────────────────────────────────────────────────────
void StatusBridge::onCallStarted()
{
    m_callActive = true;
    emit callActiveChanged(true);
    emit switchLowerToPhone();
    emit showAlertBanner("Incoming Call");
}

void StatusBridge::onCallEnded()
{
    m_callActive = false;
    emit callActiveChanged(false);
    emit restoreLowerScreen();
}

// ─── Phone control (QML-facing) ────────────────────────────────────────────
// Stubs until BlueZ HFP profile is wired through AudioService. Local state +
// signals are kept consistent so the PhoneView UX is fully responsive.
void StatusBridge::answerCall()
{
    if (m_callActive) return;
    m_callActive = true;
    emit callActiveChanged(true);
    emit switchLowerToPhone();
    qInfo() << "[StatusBridge] answerCall — HFP stub";
}

void StatusBridge::endCall()
{
    if (!m_callActive) return;
    m_callActive = false;
    m_muted = false;
    emit callActiveChanged(false);
    emit muteChanged(false);
    emit restoreLowerScreen();
    qInfo() << "[StatusBridge] endCall — HFP stub";
}

void StatusBridge::toggleMute()
{
    m_muted = !m_muted;
    emit muteChanged(m_muted);
    if (m_audio) m_audio->setMuted(m_muted);
    qInfo() << "[StatusBridge] toggleMute →" << m_muted;
}

void StatusBridge::toggleSpeaker()
{
    m_speakerOn = !m_speakerOn;
    emit speakerChanged(m_speakerOn);
    qInfo() << "[StatusBridge] toggleSpeaker →" << m_speakerOn
            << "(BlueZ HFP routing stub — no ALSA hand-off yet)";
}

void StatusBridge::sendDtmf(const QString &digit)
{
    // Real BT HFP DTMF (AT+VTS) routing comes with BlueZ HFP profile work.
    // For now we emit a signal so any future listener (AudioService, an
    // off-device tester, or a beep generator) can consume it.
    qInfo() << "[StatusBridge] DTMF" << digit;
    emit dtmfSent(digit);
}

void StatusBridge::dial(const QString &number)
{
    // Same stub — outgoing call initiation requires BT HFP. Surface the
    // intent so test harnesses can verify the button works.
    qInfo() << "[StatusBridge] dial" << number << "— HFP outgoing stub";
    emit outgoingCallInitiated(number);
    if (!m_callActive) {
        m_callActive = true;
        emit callActiveChanged(true);
    }
}
