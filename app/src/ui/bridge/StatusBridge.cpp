// StatusBridge.cpp
// Zero-copy signal relay between services and both QML windows.
// Single source of truth for all cross-screen state.

#include "StatusBridge.h"
#include "../../services/navigation/NavigationService.h"
#include "../../services/vehicle/VehicleService.h"
#include "../../services/audio/AudioService.h"
#include "../../services/network/NetworkService.h"

#include <QTimer>
#include <QDateTime>
#include <QDebug>

StatusBridge::StatusBridge(NavigationService *nav,
                            VehicleService   *vehicle,
                            AudioService     *audio,
                            NetworkService   *network,
                            QObject *parent)
    : QObject(parent)
    , m_nav(nav)
    , m_vehicle(vehicle)
    , m_audio(audio)
    , m_network(network)
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
