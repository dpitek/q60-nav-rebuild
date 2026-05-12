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

// ─── Helpers ──────────────────────────────────────────────────────────────────
QVariantMap AudioService::makePreset(double freq, const QString &name)
{
    QVariantMap m;
    m["freq"] = freq;
    m["name"] = name;
    return m;
}

void AudioService::initPresets()
{
    // FM: 6 presets — first slot seeded with NPR
    m_fmPresets.clear();
    m_fmPresets << makePreset(88.5, "NPR")
                << makePreset(93.9, "")
                << makePreset(96.1, "")
                << makePreset(99.9, "")
                << makePreset(101.5, "")
                << makePreset(104.7, "");

    // AM: 6 empty presets
    m_amPresets.clear();
    for (int i = 0; i < 6; ++i)
        m_amPresets << makePreset(0.0, "");

    // SXM: 6 empty presets
    m_sxmPresets.clear();
    for (int i = 0; i < 6; ++i)
        m_sxmPresets << makePreset(0.0, "");
}

// ─── Constructor / destructor ─────────────────────────────────────────────────
AudioService::AudioService(QObject *parent)
    : QObject(parent)
#ifdef HAVE_QT_DBUS
    , m_btMediaPlayer(nullptr)
#endif
{
    initPresets();
}

AudioService::~AudioService()
{
    m_sxmProxy.kill();
    m_fmProxy.kill();
}

void AudioService::start()
{
    // DENSO proxies are started in start.sh — connect to their stdout
    // for status updates via named pipes on /tmp/sxm.sock, /tmp/fm.sock if present.

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

// ─── Source control ────────────────────────────────────────────────────────────
void AudioService::setSource(AudioSource src)
{
    if (m_source == src) return;
    m_source = src;
    emit sourceChanged(src);

    switch (src) {
    case Bluetooth:
        qDebug() << "[AudioService] Source: Bluetooth";
        break;
    case FM:
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

// ─── FM ───────────────────────────────────────────────────────────────────────
void AudioService::setFMFrequency(double mhz)
{
    m_fmFrequency = mhz;
    m_activePresetIndex = -1;
    emit fmChanged();
    emit presetsChanged();
    sendProxyCommand("radiofc", QString("TUNE FM %1").arg(mhz, 0, 'f', 1));
}

void AudioService::seekFM(bool forward)
{
    sendProxyCommand("radiofc", forward ? "SEEK UP" : "SEEK DOWN");
}

// ─── SXM ──────────────────────────────────────────────────────────────────────
void AudioService::setSXMChannel(int ch)
{
    sendProxyCommand("sxmcgs", QString("CHANNEL %1").arg(ch));
    m_sxmChannel = QString::number(ch);
    emit sxmChanged();
}

// ─── Bluetooth AVRCP ──────────────────────────────────────────────────────────
void AudioService::btPlay()  { blueZMediaCmd("Play"); }
void AudioService::btPause() { blueZMediaCmd("Pause"); }
void AudioService::btNext()  { blueZMediaCmd("Next"); }
void AudioService::btPrev()  { blueZMediaCmd("Previous"); }

void AudioService::blueZMediaCmd(const QString &method)
{
#ifdef HAVE_QT_DBUS
    if (!m_btMediaPlayer) {
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

// ─── Bose wake ────────────────────────────────────────────────────────────────
void AudioService::wakeBosse()
{
    qDebug() << "[AudioService] Bose wake requested (delegating to VehicleService)";
    emit bossWakeRequested();
}

// ─── EQ slots ─────────────────────────────────────────────────────────────────
void AudioService::setBass(int v)
{
    m_bass = qBound(-7, v, 7);
    emit eqChanged();
    sendProxyCommand("audiofc", QString("BASS %1").arg(m_bass));
}

void AudioService::setTreble(int v)
{
    m_treble = qBound(-7, v, 7);
    emit eqChanged();
    sendProxyCommand("audiofc", QString("TREBLE %1").arg(m_treble));
}

void AudioService::setBalance(int v)
{
    m_balance = qBound(-9, v, 9);
    emit eqChanged();
    sendProxyCommand("audiofc", QString("BALANCE %1").arg(m_balance));
}

void AudioService::setFade(int v)
{
    m_fade = qBound(-9, v, 9);
    emit eqChanged();
    sendProxyCommand("audiofc", QString("FADE %1").arg(m_fade));
}

// ─── Bose DSP slots ───────────────────────────────────────────────────────────
void AudioService::setAudioPilot(bool on)
{
    m_audioPilotOn = on;
    emit boseChanged();
    sendProxyCommand("audiofc", QString("AUDIOPILOT %1").arg(on ? 1 : 0));
}

void AudioService::setCenterpoint(bool on)
{
    m_centerpointOn = on;
    emit boseChanged();
    sendProxyCommand("audiofc", QString("CENTERPOINT %1").arg(on ? 1 : 0));
}

void AudioService::setSurround(bool on)
{
    m_surroundOn = on;
    emit boseChanged();
    sendProxyCommand("audiofc", QString("SURROUND %1").arg(on ? 1 : 0));
}

void AudioService::setDriverStage(bool on)
{
    m_driverStageOn = on;
    emit boseChanged();
    sendProxyCommand("audiofc", QString("DRIVERSTAGE %1").arg(on ? 1 : 0));
}

// ─── SSV slot ─────────────────────────────────────────────────────────────────
void AudioService::setSSVLevel(int level)
{
    m_ssvLevel = qBound(0, level, 5);
    emit ssvChanged();
    sendProxyCommand("audiofc", QString("SSV %1").arg(m_ssvLevel));
}

// ─── Preset slots ─────────────────────────────────────────────────────────────
void AudioService::savePreset(int slot)
{
    if (slot < 0 || slot > 5) return;

    QVariantList *list = nullptr;
    if (m_source == FM)      list = &m_fmPresets;
    else if (m_source == AM) list = &m_amPresets;
    else if (m_source == SXM) list = &m_sxmPresets;
    if (!list) return;

    QVariantMap entry = (*list)[slot].toMap();
    entry["freq"] = m_fmFrequency;
    // Name: leave blank for user to edit later (hardware UI doesn't have text entry)
    (*list)[slot] = entry;

    m_activePresetIndex = slot;
    emit presetsChanged();

    qDebug() << "[AudioService] Saved preset" << slot << "=" << m_fmFrequency;
}

void AudioService::recallPreset(int slot)
{
    if (slot < 0 || slot > 5) return;

    QVariantList *list = nullptr;
    if (m_source == FM)      list = &m_fmPresets;
    else if (m_source == AM) list = &m_amPresets;
    else if (m_source == SXM) list = &m_sxmPresets;
    if (!list) return;

    QVariantMap entry = (*list)[slot].toMap();
    double freq = entry["freq"].toDouble();
    if (freq <= 0.0) return;  // Unset slot

    m_activePresetIndex = slot;
    emit presetsChanged();

    if (m_source == FM || m_source == AM) {
        setFMFrequency(freq);
        // Restore preset index overridden by setFMFrequency
        m_activePresetIndex = slot;
        emit presetsChanged();
    } else if (m_source == SXM) {
        setSXMChannel(static_cast<int>(freq));
    }

    qDebug() << "[AudioService] Recalled preset" << slot << "=" << freq;
}

// ─── D-Bus property monitoring ────────────────────────────────────────────────
void AudioService::onBluetoothProperties(const QString &iface,
                                          const QVariantMap &props,
                                          const QStringList &invalidated)
{
    Q_UNUSED(invalidated)
#ifdef HAVE_QT_DBUS
    if (iface != BT_MEDIA_PLYR) return;
#else
    Q_UNUSED(iface)
    return;
#endif

    if (props.contains("Track")) {
        QVariantMap track = props["Track"].toMap();
        QString title  = track["Title"].toString();
        QString artist = track["Artist"].toString();
        QString album  = track["Album"].toString();
        bool changed = (title != m_trackTitle || artist != m_trackArtist || album != m_trackAlbum);
        if (changed) {
            m_trackTitle  = title;
            m_trackArtist = artist;
            m_trackAlbum  = album;
            emit metadataChanged();
            qDebug() << "[AudioService] BT track:" << artist << "-" << title;
        }
    }
    if (props.contains("Connected")) {
        bool connected = props["Connected"].toBool();
        if (connected != m_btConnected) {
            m_btConnected = connected;
            emit btConnectionChanged(connected);
        }
    }
    if (props.contains("Name")) {
        m_btDeviceName = props["Name"].toString();
        emit btConnectionChanged(m_btConnected);
    }
}

// ─── DENSO proxy IPC ──────────────────────────────────────────────────────────
void AudioService::sendProxyCommand(const QString &daemon, const QString &cmd)
{
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
    // Parse SXM proxy status: channel name, artist, title, category, signal
    // Format TBD from DENSO protocol reverse
}

void AudioService::onFmProxyData()
{
    // Parse FM proxy: RDS station name, frequency confirmation, RDS text
}

void AudioService::onBluetoothMetadata(const QString &title, const QString &artist)
{
    if (title != m_trackTitle || artist != m_trackArtist) {
        m_trackTitle  = title;
        m_trackArtist = artist;
        emit metadataChanged();
    }
}
