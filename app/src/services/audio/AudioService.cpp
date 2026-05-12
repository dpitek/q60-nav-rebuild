// AudioService.cpp
// Audio source management: BT (BlueZ A2DP/AVRCP), FM, AM, SXM, AUX
// DENSO proxy daemons handle FM/SXM hardware — we communicate via stdout parsing
// BlueZ 5 controlled via D-Bus

#include "AudioService.h"
#include <QDebug>
#include <QProcess>
#ifdef HAVE_QT_DBUS
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#endif

// BlueZ D-Bus paths (used only when HAVE_QT_DBUS is defined)
static const char *BT_SERVICE    = "org.bluez";
#ifdef HAVE_QT_DBUS
static const char *BT_MEDIA_CTRL = "org.bluez.MediaControl1";
static const char *BT_MEDIA_PLYR = "org.bluez.MediaPlayer1";
#endif

AudioService::AudioService(QObject *parent)
    : QObject(parent)
#ifdef HAVE_QT_DBUS
    , m_btMediaPlayer(nullptr)
#endif
{
}

AudioService::~AudioService()
{
    m_sxmProxy.kill();
    m_fmProxy.kill();
}

void AudioService::start()
{
    // DENSO proxies are started in start.sh — we just connect to their stdout
    // for status updates. They're long-running daemons; we QProcess::startDetached
    // won't work here — they're already running. Connect via named pipes or D-Bus.
    // For now: connect to their socket on /tmp/sxm.sock, /tmp/fm.sock if present.

#ifdef HAVE_QT_DBUS
    // BlueZ D-Bus monitoring
    QDBusConnection bus = QDBusConnection::systemBus();
    bus.connect(BT_SERVICE, QString(), "org.freedesktop.DBus.Properties",
                "PropertiesChanged", this, SLOT(onBluetoothProperties(QString,QVariantMap,QStringList)));
#endif

    // Set ALSA card for A2DP output
    qputenv("PULSE_SINK", "bluez_sink.auto");

    qDebug() << "[AudioService] started";
}

// ─── Source control ────────────────────────────────────────────────────────
void AudioService::setSource(AudioSource src)
{
    if (m_source == src) return;
    m_source = src;
    emit sourceChanged(src);

    switch (src) {
    case Bluetooth:
        // Route audio through BlueZ A2DP — ALSA card switch
        qDebug() << "[AudioService] Source: Bluetooth";
        break;
    case FM:
        // Signal DENSO radiofc.out daemon
        sendProxyCommand("radiofc", "SOURCE FM");
        qDebug() << "[AudioService] Source: FM";
        break;
    case AM:
        sendProxyCommand("radiofc", "SOURCE AM");
        qDebug() << "[AudioService] Source: AM";
        break;
    case SXM:
        sendProxyCommand("sxmcgs", "SOURCE SXM");
        qDebug() << "[AudioService] Source: SXM";
        break;
    case AUX:
        qDebug() << "[AudioService] Source: AUX";
        break;
    case None:
        break;
    }
}

void AudioService::setVolume(int vol)
{
    m_volume = qBound(0, vol, 100);
    emit volumeChanged(m_volume);

    // ALSA master volume
    QString cmd = QString("amixer -q sset Master %1%").arg(m_volume);
    QProcess::startDetached("sh", {"-c", cmd});
}

void AudioService::setMuted(bool muted)
{
    m_muted = muted;
    emit mutedChanged(muted);
    QString cmd = muted ? "amixer -q sset Master mute"
                        : "amixer -q sset Master unmute";
    QProcess::startDetached("sh", {"-c", cmd});
}

// ─── FM ───────────────────────────────────────────────────────────────────
void AudioService::setFMFrequency(double mhz)
{
    m_fmFrequency = mhz;
    emit fmChanged();
    sendProxyCommand("radiofc", QString("TUNE FM %1").arg(mhz, 0, 'f', 1));
}

void AudioService::seekFM(bool forward)
{
    sendProxyCommand("radiofc", forward ? "SEEK UP" : "SEEK DOWN");
}

// ─── SXM ──────────────────────────────────────────────────────────────────
void AudioService::setSXMChannel(int ch)
{
    sendProxyCommand("sxmcgs", QString("CHANNEL %1").arg(ch));
}

// ─── Bluetooth AVRCP ──────────────────────────────────────────────────────
void AudioService::btPlay()
{
    blueZMediaCmd("Play");
}

void AudioService::btPause()
{
    blueZMediaCmd("Pause");
}

void AudioService::btNext()
{
    blueZMediaCmd("Next");
}

void AudioService::btPrev()
{
    blueZMediaCmd("Previous");
}

void AudioService::blueZMediaCmd(const QString &method)
{
#ifdef HAVE_QT_DBUS
    if (!m_btMediaPlayer) {
        // Discover connected player
        QDBusInterface mgr(BT_SERVICE, "/", "org.freedesktop.DBus.ObjectManager",
                           QDBusConnection::systemBus());
        QDBusReply<QMap<QDBusObjectPath,
                        QMap<QString, QVariantMap>>> reply = mgr.call("GetManagedObjects");
        if (!reply.isValid()) {
            qWarning() << "[AudioService] BlueZ GetManagedObjects failed";
            return;
        }
        for (auto it = reply.value().begin(); it != reply.value().end(); ++it) {
            if (it.value().contains(BT_MEDIA_PLYR)) {
                m_btPlayerPath = it.key().path();
                break;
            }
        }
        if (m_btPlayerPath.isEmpty()) {
            qWarning() << "[AudioService] No BlueZ media player found";
            return;
        }
        m_btMediaPlayer = new QDBusInterface(BT_SERVICE, m_btPlayerPath,
                                             BT_MEDIA_PLYR,
                                             QDBusConnection::systemBus(), this);
    }
    m_btMediaPlayer->asyncCall(method);
#else
    qWarning() << "[AudioService] BlueZ AVRCP not available (Qt DBus disabled):" << method;
#endif
}

// ─── Bose wake ────────────────────────────────────────────────────────────
void AudioService::wakeBosse()
{
    // Delegated to VehicleService — AudioService calls VehicleService::wakeBosse()
    // via signal connection set up in main.cpp. No direct CAN access here.
    qDebug() << "[AudioService] Bose wake requested (delegating to VehicleService)";
    emit bossWakeRequested();
}

// ─── D-Bus property monitoring ────────────────────────────────────────────
void AudioService::onBluetoothProperties(const QString &iface,
                                          const QVariantMap &props,
                                          const QStringList &invalidated)
{
    Q_UNUSED(invalidated)
#ifdef HAVE_QT_DBUS
    if (iface != BT_MEDIA_PLYR) return;
#else
    Q_UNUSED(iface)
    return;  // DBus disabled — no BlueZ property monitoring
#endif

    if (props.contains("Track")) {
        QVariantMap track = props["Track"].toMap();
        QString title  = track["Title"].toString();
        QString artist = track["Artist"].toString();
        if (title != m_trackTitle || artist != m_trackArtist) {
            m_trackTitle  = title;
            m_trackArtist = artist;
            emit metadataChanged();
            qDebug() << "[AudioService] BT track:" << artist << "-" << title;
        }
    }
    if (props.contains("Connected")) {
        bool connected = props["Connected"].toBool();
        emit btConnectionChanged(connected);
    }
}

// ─── DENSO proxy IPC ──────────────────────────────────────────────────────
void AudioService::sendProxyCommand(const QString &daemon, const QString &cmd)
{
    // DENSO daemons accept commands via named pipes or D-Bus
    // Pipe path convention: /tmp/<daemon>.cmd
    QString pipePath = QString("/tmp/%1.cmd").arg(daemon);
    QFile pipe(pipePath);
    if (pipe.open(QIODevice::WriteOnly)) {
        pipe.write((cmd + "\n").toUtf8());
        pipe.close();
    } else {
        qWarning() << "[AudioService] Cannot write to" << pipePath;
    }
}

void AudioService::onSxmProxyData()
{
    // Parse SXM proxy status: channel name, artist, title
    // Format TBD from DENSO protocol reverse
}

void AudioService::onFmProxyData()
{
    // Parse FM proxy: RDS station name, frequency confirmation
}

void AudioService::onBluetoothMetadata(const QString &title, const QString &artist)
{
    if (title != m_trackTitle || artist != m_trackArtist) {
        m_trackTitle  = title;
        m_trackArtist = artist;
        emit metadataChanged();
    }
}
