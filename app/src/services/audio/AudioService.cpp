// AudioService.cpp
// Audio source management: BT (BlueZ A2DP/AVRCP), FM, AM, SXM, AUX
// DENSO proxy daemons handle FM/SXM hardware — we communicate via stdout parsing
// BlueZ 5 controlled via D-Bus

#include "AudioService.h"
#include "../settings/SettingsService.h"
#include "../vehicle/VehicleService.h"
#include <QDebug>
#include <QProcess>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <cmath>
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

    // Stub: wire FM/SXM proxy stdout readers. radiofc.out / sxmcgs.out are spawned
    // by start.sh — we'd attach a QSocketNotifier on /tmp/radiofc.status in the
    // final integration. For now, if QProcess instances are populated externally,
    // parse their stdout for status lines.
    connect(&m_fmProxy,  &QProcess::readyReadStandardOutput, this, &AudioService::onFmProxyData);
    connect(&m_sxmProxy, &QProcess::readyReadStandardOutput, this, &AudioService::onSxmProxyData);

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

// ─── Dependency wiring (called from main.cpp after all services constructed) ──
void AudioService::wireDependencies(SettingsService *settings, VehicleService *vehicle)
{
    m_settings = settings;
    m_vehicle  = vehicle;

    if (m_settings) {
        loadPresetsFromSettings();
        // Keep our in-memory presets in sync with external mutations (profile
        // switch, manual edit on disk).  Re-load if the blob changes from
        // anything other than our own write.
        connect(m_settings, &SettingsService::audioPresetsChanged, this, [this]() {
            if (!m_loadingPresets) loadPresetsFromSettings();
        });
    }

    if (m_vehicle) {
        connect(m_vehicle, &VehicleService::speedChanged,
                this, &AudioService::onVehicleSpeedChanged);
    }
}

// ─── Preset persistence ───────────────────────────────────────────────────────
//
// Encoding:
//   {"FM":[{"freq":101.5,"name":"WBOS"}, ...],
//    "AM":[{"freq":1010.0,"name":""}, ...],
//    "SXM":[{"freq":22.0,"name":"The Spectrum"}, ...]}
//
// SXM stores channel number in "freq" for schema simplicity.
//
void AudioService::loadPresetsFromSettings()
{
    if (!m_settings) return;

    const QString blob = m_settings->audioPresets();
    if (blob.isEmpty()) return;  // first boot — keep compiled defaults

    const QJsonDocument doc = QJsonDocument::fromJson(blob.toUtf8());
    if (!doc.isObject()) {
        qWarning() << "[AudioService] audioPresets blob is not a JSON object — ignoring";
        return;
    }

    auto applyList = [](const QJsonArray &arr, QVariantList &dst) {
        for (int i = 0; i < 6 && i < arr.size(); ++i) {
            const QJsonObject o = arr.at(i).toObject();
            QVariantMap entry = dst[i].toMap();
            entry["freq"] = o.value("freq").toDouble(0.0);
            entry["name"] = o.value("name").toString();
            dst[i] = entry;
        }
    };

    m_loadingPresets = true;
    const QJsonObject root = doc.object();
    applyList(root.value("FM").toArray(),  m_fmPresets);
    applyList(root.value("AM").toArray(),  m_amPresets);
    applyList(root.value("SXM").toArray(), m_sxmPresets);
    m_loadingPresets = false;

    emit presetsChanged();
    qDebug() << "[AudioService] Loaded presets from SettingsService";
}

void AudioService::writePresetsToSettings()
{
    if (!m_settings || m_loadingPresets) return;

    auto toArray = [](const QVariantList &src) {
        QJsonArray arr;
        for (const QVariant &v : src) {
            const QVariantMap m = v.toMap();
            QJsonObject o;
            o["freq"] = m.value("freq").toDouble();
            o["name"] = m.value("name").toString();
            arr.append(o);
        }
        return arr;
    };

    QJsonObject root;
    root["FM"]  = toArray(m_fmPresets);
    root["AM"]  = toArray(m_amPresets);
    root["SXM"] = toArray(m_sxmPresets);

    const QString blob = QString::fromUtf8(
        QJsonDocument(root).toJson(QJsonDocument::Compact));
    m_settings->setAudioPresets(blob);
}

// ─── SSV gain ─────────────────────────────────────────────────────────────────
// gain = base * (1 + (speed/50) * (sensitivity/5) * 0.3)
// Applied as a transient multiplier on top of m_volume via ALSA Master.
// Only effective when ssvLevel > 0.
void AudioService::onVehicleSpeedChanged(float kph)
{
    m_speedKph = kph;
    applySpeedGain();
}

void AudioService::applySpeedGain()
{
    if (m_ssvLevel <= 0) return;  // SSV off — leave volume alone

    const double sensitivity = m_ssvLevel;          // 1..5
    const double speed       = std::max(0.0f, m_speedKph);
    const double factor      = 1.0 + (speed / 50.0) * (sensitivity / 5.0) * 0.3;
    const int    adjusted    = qBound(0, int(std::lround(m_volume * factor)), 100);

    // Don't store as m_volume — the user's setpoint is sacred.  Apply to ALSA
    // directly so the slider continues to reflect the user's choice.
    QString cmd = QString("amixer -q sset Master %1%").arg(adjusted);
    QProcess::startDetached("sh", {"-c", cmd});
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

    if (m_ssvLevel > 0) {
        // Let applySpeedGain do the ALSA write — it factors the user setpoint
        applySpeedGain();
    } else {
        QString cmd = QString("amixer -q sset Master %1%").arg(m_volume);
        QProcess::startDetached("sh", {"-c", cmd});
    }
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
    // TODO: Bose DSP byte encoding via sound.out IPC not yet reverse-engineered.
    //       Logging the placeholder command string we'd send.
    qDebug() << "[AudioService][DSP-TODO] would send to /tmp/sound.cmd:"
             << QString("AUDIOPILOT %1").arg(on ? 1 : 0);
    sendProxyCommand("audiofc", QString("AUDIOPILOT %1").arg(on ? 1 : 0));
}

void AudioService::setCenterpoint(bool on)
{
    m_centerpointOn = on;
    emit boseChanged();
    qDebug() << "[AudioService][DSP-TODO] would send to /tmp/sound.cmd:"
             << QString("CENTERPOINT %1").arg(on ? 1 : 0);
    sendProxyCommand("audiofc", QString("CENTERPOINT %1").arg(on ? 1 : 0));
}

void AudioService::setSurround(bool on)
{
    m_surroundOn = on;
    emit boseChanged();
    qDebug() << "[AudioService][DSP-TODO] would send to /tmp/sound.cmd:"
             << QString("SURROUND %1").arg(on ? 1 : 0);
    sendProxyCommand("audiofc", QString("SURROUND %1").arg(on ? 1 : 0));
}

void AudioService::setDriverStage(bool on)
{
    m_driverStageOn = on;
    emit boseChanged();
    qDebug() << "[AudioService][DSP-TODO] would send to /tmp/sound.cmd:"
             << QString("DRIVERSTAGE %1").arg(on ? 1 : 0);
    sendProxyCommand("audiofc", QString("DRIVERSTAGE %1").arg(on ? 1 : 0));
}

// ─── SSV slot ─────────────────────────────────────────────────────────────────
void AudioService::setSSVLevel(int level)
{
    m_ssvLevel = qBound(0, level, 5);
    emit ssvChanged();
    // TODO: DSP SSV command via sound.out — string below is the placeholder
    //       IPC payload until the protocol is reverse-engineered.
    qDebug() << "[AudioService][DSP-TODO] would send to /tmp/sound.cmd:"
             << QString("SSV %1").arg(m_ssvLevel);
    sendProxyCommand("audiofc", QString("SSV %1").arg(m_ssvLevel));

    // If SSV just turned off, restore master to user's setpoint
    if (m_ssvLevel == 0) {
        QString cmd = QString("amixer -q sset Master %1%").arg(m_volume);
        QProcess::startDetached("sh", {"-c", cmd});
    } else {
        applySpeedGain();
    }
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
    if (m_source == SXM) {
        // SXM uses channel number stored in "freq"; auto-label from sxmName
        entry["freq"] = m_sxmChannel.toDouble();
        if (!m_sxmName.isEmpty()) entry["name"] = m_sxmName;
    } else {
        entry["freq"] = m_fmFrequency;
        // FM auto-label from current station name (if RDS produced one)
        if (m_source == FM && !m_fmStationName.isEmpty())
            entry["name"] = m_fmStationName;
    }
    (*list)[slot] = entry;

    m_activePresetIndex = slot;
    emit presetsChanged();
    writePresetsToSettings();

    qDebug() << "[AudioService] Saved preset" << slot << "for source" << m_source
             << "freq=" << entry["freq"].toDouble() << "name=" << entry["name"].toString();
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
    // Parse FM proxy stdout / status pipe for RDS frames.
    // Expected (stubbed) line formats from radiofc.out:
    //   "RDS PS WBOS"               → station name (program service)
    //   "RDS RT Song Title - Artist" → radio text segment
    //   "FREQ 101.5"                 → frequency confirmation
    while (m_fmProxy.canReadLine()) {
        const QString line = QString::fromUtf8(m_fmProxy.readLine()).trimmed();
        if (!line.isEmpty()) parseRdsLine(line);
    }
}

void AudioService::parseRdsLine(const QString &line)
{
    // Minimal RDS PS/RT parser — final implementation will live in the DENSO
    // proxy bridge once the radiofc.out frame format is reverse-engineered.
    if (line.startsWith("RDS PS ")) {
        const QString ps = line.mid(7).trimmed();
        if (ps != m_fmStationName) {
            m_fmStationName = ps;
            // Keep m_fmStation in sync for the existing centred-station Text
            if (m_fmStation != ps) m_fmStation = ps;
            emit fmChanged();
        }
    } else if (line.startsWith("RDS RT ")) {
        const QString rt = line.mid(7).trimmed();
        if (rt != m_fmSongTitle) {
            m_fmSongTitle = rt;
            m_rdsText     = rt;   // legacy ticker continues to bind to rdsText
            emit fmChanged();
        }
    } else if (line.startsWith("FREQ ")) {
        const double mhz = line.mid(5).toDouble();
        if (mhz > 0.0 && qAbs(mhz - m_fmFrequency) > 0.05) {
            m_fmFrequency = mhz;
            emit fmChanged();
        }
    }
}

void AudioService::onBluetoothMetadata(const QString &title, const QString &artist)
{
    if (title != m_trackTitle || artist != m_trackArtist) {
        m_trackTitle  = title;
        m_trackArtist = artist;
        emit metadataChanged();
    }
}
