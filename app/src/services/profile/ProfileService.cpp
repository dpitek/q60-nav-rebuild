// ProfileService.cpp — Driver profile management
// Singleton instantiated in main.cpp; exposed to QML as "ProfileService".
//
// Storage: QStandardPaths::AppDataLocation + "/profiles.json"
//   On DCU (root user): /root/.local/share/Q60Rebuild/q60nav/profiles.json
//   Dev desktop: ~/.local/share/Q60Rebuild/q60nav/profiles.json
//
// Thread safety: all CAN callbacks arrive on the Qt main thread via QSocketNotifier.
// Profile load is synchronous (< 1 ms on DCU flash) but file write uses QSaveFile
// for atomicity — no partial writes survive power loss.
//
// CAN key detection: CAN_KEY_DETECT (0x35B) — UNVERIFIED — see VehicleService.h.
// The signal keySlotDetected(int) is emitted by VehicleService; ProfileService
// subscribes in start(). Profile matching: keySlots[] in profile JSON contains
// the slot numbers (1 or 2) the profile is assigned to.

#include "ProfileService.h"
#include "services/vehicle/VehicleService.h"

#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QSaveFile>
#include <QDateTime>
#include <QDebug>
#include <QTimer>

// ─── Construction ─────────────────────────────────────────────────────────────

ProfileService::ProfileService(QObject *parent)
    : QObject(parent)
{
    m_autoSaveTimer = new QTimer(this);
    m_autoSaveTimer->setSingleShot(true);
    m_autoSaveTimer->setInterval(5000);  // 5s debounce
    connect(m_autoSaveTimer, &QTimer::timeout, this, &ProfileService::autoSaveTimerFired);
}

void ProfileService::start(VehicleService *vehicleSvc)
{
    m_vehicleSvc = vehicleSvc;

    // Subscribe to key slot detection from VehicleService
    if (m_vehicleSvc) {
        connect(m_vehicleSvc, &VehicleService::keySlotDetected,
                this, &ProfileService::onKeySlotDetected);
        connect(m_vehicleSvc, &VehicleService::ignitionOff,
                this, &ProfileService::onIgnitionOff);
    }

    // Load profiles from disk
    if (!loadFromDisk()) {
        qDebug() << "[ProfileService] No existing profiles — first boot";
    }

    // If no profiles exist, enter no-profile mode so welcome shows "Who's driving?"
    if (m_profileData.isEmpty()) {
        m_noProfileMode  = true;
        m_welcomeVisible = true;
        emit welcomeVisibilityChanged();
    } else {
        // Auto-load profile 0 as default until key detection fires
        applyProfile(0);
        m_welcomeVisible = true;
        emit welcomeVisibilityChanged();
        // Welcome auto-dismisses via QML timer — 3s
    }
}

// ─── Property accessors ───────────────────────────────────────────────────────

QVariantMap ProfileService::activeProfile() const
{
    if (m_activeProfileIndex < 0 || m_activeProfileIndex >= m_profiles.size())
        return {};
    return m_profiles.at(m_activeProfileIndex).toMap();
}

QVariantMap ProfileService::profileAt(int index) const
{
    if (index < 0 || index >= m_profiles.size())
        return {};
    return m_profiles.at(index).toMap();
}

// ─── CAN key detection ────────────────────────────────────────────────────────

void ProfileService::onKeySlotDetected(int slot)
{
    if (slot < 1 || slot > 2) return;
    qDebug("[ProfileService] Key slot detected: %d (CAN_KEY_DETECT UNVERIFIED)", slot);

    // Search profiles for one that includes this key slot
    for (int i = 0; i < m_profileData.size(); ++i) {
        QJsonObject p = m_profileData[i].toObject();
        QJsonArray  slots = p.value("keySlots").toArray();
        for (const auto &s : slots) {
            if (s.toInt() == slot) {
                // Found a match
                if (i != m_activeProfileIndex) {
                    applyProfile(i);
                    emit profileLoaded(slot);
                    emit profileSwitched();
                }
                // Show welcome overlay
                m_noProfileMode  = false;
                m_welcomeVisible = true;
                emit welcomeVisibilityChanged();
                return;
            }
        }
    }

    // No matching profile
    qDebug("[ProfileService] No profile for key slot %d — showing creation prompt", slot);
    m_noProfileMode  = true;
    m_welcomeVisible = true;
    emit welcomeVisibilityChanged();
    emit noProfileFound(slot);
}

// ─── Profile CRUD ─────────────────────────────────────────────────────────────

void ProfileService::createProfile(const QString &name,
                                    const QString &avatar,
                                    const QString &accent,
                                    const QVariantList &keySlots)
{
    if (name.trimmed().isEmpty()) {
        qWarning() << "[ProfileService] createProfile: name is empty";
        return;
    }

    QJsonObject p = buildDefaultProfile(name, avatar, accent, keySlots);
    m_profileData.append(p);
    m_profiles.append(jsonToVariant(p));
    emit profilesChanged();

    // Auto-switch to the newly created profile
    const int newIdx = m_profileData.size() - 1;
    applyProfile(newIdx);
    saveToDisk();

    qDebug() << "[ProfileService] Created profile:" << name;
}

void ProfileService::deleteProfile(int index)
{
    if (index < 0 || index >= m_profileData.size()) return;

    QString name = m_profileData[index].toObject().value("name").toString();
    m_profileData.removeAt(index);
    m_profiles.removeAt(index);
    emit profilesChanged();

    // Adjust active index
    if (m_activeProfileIndex == index) {
        m_activeProfileIndex = m_profileData.isEmpty() ? -1 : 0;
        if (m_activeProfileIndex >= 0) {
            applyProfile(m_activeProfileIndex);
        } else {
            m_profileLoaded = false;
            m_activeProfileName   = QString();
            m_activeProfileAvatar = QString();
            m_noProfileMode  = true;
            m_welcomeVisible = true;
            emit welcomeVisibilityChanged();
            emit profileChanged();
        }
    } else if (m_activeProfileIndex > index) {
        m_activeProfileIndex--;
    }

    saveToDisk();
    qDebug() << "[ProfileService] Deleted profile:" << name;
}

void ProfileService::loadProfile(int index)
{
    applyProfile(index);
}

void ProfileService::switchProfile(int index)
{
    if (index < 0 || index >= m_profileData.size()) return;
    applyProfile(index);
    emit profileSwitched();

    // Show welcome for manual switch
    m_noProfileMode  = false;
    m_welcomeVisible = true;
    emit welcomeVisibilityChanged();
}

void ProfileService::saveCurrentProfile()
{
    saveToDisk();
}

void ProfileService::setProfileField(const QString &section,
                                      const QString &key,
                                      const QVariant &value)
{
    if (m_activeProfileIndex < 0 || m_activeProfileIndex >= m_profileData.size()) return;

    QJsonObject profile = m_profileData[m_activeProfileIndex].toObject();

    if (section.isEmpty()) {
        // Top-level field (name, avatar, accentColor, pinEnabled, etc.)
        profile.insert(key, QJsonValue::fromVariant(value));
    } else {
        QJsonObject sec = profile.value(section).toObject();
        sec.insert(key, QJsonValue::fromVariant(value));
        profile.insert(section, sec);
    }

    m_profileData[m_activeProfileIndex] = profile;
    m_profiles[m_activeProfileIndex] = jsonToVariant(profile);

    // Refresh active name/avatar/accent in case those changed
    m_activeProfileName   = profile.value("name").toString();
    m_activeProfileAvatar = profile.value("avatar").toString();
    m_activeAccentColor   = profile.value("accentColor").toString();

    emit profileChanged();
    emit profilesChanged();

    // Debounced auto-save
    m_autoSaveTimer->start();
}

// ─── PIN verification ─────────────────────────────────────────────────────────

bool ProfileService::verifyPin(int profileIndex, const QString &pin)
{
    if (profileIndex < 0 || profileIndex >= m_profileData.size()) return false;
    QJsonObject p = m_profileData[profileIndex].toObject();
    if (!p.value("pinEnabled").toBool()) return true;  // no PIN = always pass
    return p.value("pin").toString() == pin;
}

// ─── Guest mode ───────────────────────────────────────────────────────────────

void ProfileService::activateGuestMode()
{
    m_guestMode           = true;
    m_profileLoaded       = true;
    m_activeProfileIndex  = -1;
    m_activeProfileName   = "Guest";
    m_activeProfileAvatar = "👤";
    m_activeAccentColor   = "#8E8E93";
    m_noProfileMode       = false;
    m_welcomeVisible      = false;
    emit profileChanged();
    emit welcomeVisibilityChanged();
    qDebug() << "[ProfileService] Guest mode activated";
}

// ─── Welcome overlay ─────────────────────────────────────────────────────────

void ProfileService::dismissWelcome()
{
    m_welcomeVisible = false;
    emit welcomeVisibilityChanged();
}

// ─── Export / Import ─────────────────────────────────────────────────────────

void ProfileService::exportProfile(int index, const QString &path)
{
    if (index < 0 || index >= m_profileData.size()) {
        emit exportComplete(false, path);
        return;
    }

    QJsonObject p = m_profileData[index].toObject();
    // Strip PIN before export for safety
    p.remove("pin");
    p.insert("pinEnabled", false);

    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning() << "[ProfileService] exportProfile: cannot open" << path;
        emit exportComplete(false, path);
        return;
    }
    f.write(QJsonDocument(p).toJson(QJsonDocument::Indented));
    if (!f.commit()) {
        qWarning() << "[ProfileService] exportProfile: commit failed for" << path;
        emit exportComplete(false, path);
        return;
    }

    qDebug() << "[ProfileService] Exported profile" << p.value("name").toString() << "to" << path;
    emit exportComplete(true, path);
}

void ProfileService::importProfile(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        qWarning() << "[ProfileService] importProfile: cannot open" << path;
        emit importComplete(false, QString());
        return;
    }

    QJsonParseError err;
    QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        qWarning() << "[ProfileService] importProfile: parse error:" << err.errorString();
        emit importComplete(false, QString());
        return;
    }

    QJsonObject p = doc.object();
    // Assign a new UUID to avoid conflicts
    p.insert("id", QUuid::createUuid().toString(QUuid::WithoutBraces));
    // Clear key slot assignment — user must reassign manually
    p.insert("keySlots", QJsonArray());

    QString name = p.value("name").toString();
    if (name.isEmpty()) name = "Imported";
    p.insert("name", name);

    m_profileData.append(p);
    m_profiles.append(jsonToVariant(p));
    emit profilesChanged();
    saveToDisk();

    qDebug() << "[ProfileService] Imported profile:" << name;
    emit importComplete(true, name);
}

// ─── Session summary ─────────────────────────────────────────────────────────

void ProfileService::onIgnitionOff()
{
    if (!m_vehicleSvc || m_guestMode || m_activeProfileIndex < 0) return;

    // Compute session stats
    const float miles    = m_vehicleSvc->tripAMiles();
    const float mpg      = m_vehicleSvc->tripAAvgMPG();
    const int   seconds  = m_vehicleSvc->tripASeconds();

    // Persist to lastSession in the active profile
    if (m_activeProfileIndex >= 0 && m_activeProfileIndex < m_profileData.size()) {
        QJsonObject profile = m_profileData[m_activeProfileIndex].toObject();
        QJsonObject session;
        session.insert("timestamp", QDateTime::currentDateTime().toString(Qt::ISODate));
        session.insert("distance",  static_cast<double>(miles));
        session.insert("avgMpg",    static_cast<double>(mpg));
        session.insert("duration",  seconds);
        profile.insert("lastSession", session);
        m_profileData[m_activeProfileIndex] = profile;
        m_profiles[m_activeProfileIndex]    = jsonToVariant(profile);
        emit profilesChanged();
        updateLastSessionSummary();
    }

    saveToDisk();
    qDebug("[ProfileService] Session saved: %.1f mi, %.1f mpg, %ds", miles, mpg, seconds);
}

void ProfileService::updateLastSessionSummary()
{
    if (m_activeProfileIndex < 0 || m_activeProfileIndex >= m_profileData.size()) return;

    QJsonObject ses = m_profileData[m_activeProfileIndex].toObject()
                          .value("lastSession").toObject();

    if (ses.isEmpty() || ses.value("distance").toDouble() < 0.1) {
        m_lastSessionSummary = QString();
        return;
    }

    const double  mi  = ses.value("distance").toDouble();
    const double  mpg = ses.value("avgMpg").toDouble();
    const int     sec = ses.value("duration").toInt();

    QString timeStr;
    if (sec < 3600)
        timeStr = QString("%1 min").arg(sec / 60);
    else
        timeStr = QString("%1h %2m").arg(sec / 3600).arg((sec % 3600) / 60);

    if (mpg > 0.1)
        m_lastSessionSummary = QString("Last drive · %1 mi · %2 mpg · %3")
                                   .arg(static_cast<int>(mi))
                                   .arg(mpg, 0, 'f', 1)
                                   .arg(timeStr);
    else
        m_lastSessionSummary = QString("Last drive · %1 mi · %2")
                                   .arg(static_cast<int>(mi))
                                   .arg(timeStr);
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

void ProfileService::applyProfile(int index)
{
    if (index < 0 || index >= m_profileData.size()) return;

    m_activeProfileIndex  = index;
    QJsonObject p = m_profileData[index].toObject();
    m_activeProfileName   = p.value("name").toString();
    m_activeProfileAvatar = p.value("avatar").toString("🏎️");
    m_activeAccentColor   = p.value("accentColor").toString("#0A84FF");
    m_profileLoaded       = true;
    m_guestMode           = false;

    updateLastSessionSummary();
    emit profileChanged();

    qDebug() << "[ProfileService] Loaded profile:" << m_activeProfileName
             << "(index" << index << ")";
}

void ProfileService::autoSaveTimerFired()
{
    saveToDisk();
}

// ─── Disk I/O ─────────────────────────────────────────────────────────────────

QString ProfileService::profilesFilePath() const
{
    // AppDataLocation on DCU (root) = /root/.local/share/Q60Rebuild/q60nav/
    const QString dir = QStandardPaths::writableLocation(
        QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    return dir + "/profiles.json";
}

bool ProfileService::loadFromDisk()
{
    const QString path = profilesFilePath();
    QFile f(path);
    if (!f.exists()) {
        qDebug() << "[ProfileService] No profiles file at" << path;
        return false;
    }
    if (!f.open(QIODevice::ReadOnly)) {
        qWarning() << "[ProfileService] Cannot open profiles file:" << path;
        return false;
    }

    QJsonParseError err;
    QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
    if (err.error != QJsonParseError::NoError) {
        qWarning() << "[ProfileService] JSON parse error in profiles:" << err.errorString();
        return false;
    }

    QJsonObject root = doc.object();
    m_profileData = root.value("profiles").toArray();

    // Rebuild QVariantList for QML
    m_profiles.clear();
    for (const auto &entry : m_profileData)
        m_profiles.append(jsonToVariant(entry.toObject()));

    emit profilesChanged();
    qDebug() << "[ProfileService] Loaded" << m_profileData.size() << "profiles from disk";
    return !m_profileData.isEmpty();
}

bool ProfileService::saveToDisk()
{
    QJsonObject root;
    root.insert("profiles", m_profileData);
    root.insert("version", 1);

    const QString path = profilesFilePath();
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning() << "[ProfileService] Cannot open QSaveFile:" << path;
        return false;
    }
    f.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    if (!f.commit()) {
        qWarning() << "[ProfileService] QSaveFile commit failed:" << path;
        return false;
    }

    qDebug() << "[ProfileService] Saved" << m_profileData.size() << "profiles to" << path;
    return true;
}

// ─── Default profile builder ──────────────────────────────────────────────────

QJsonObject ProfileService::buildDefaultProfile(const QString &name,
                                                 const QString &avatar,
                                                 const QString &accent,
                                                 const QVariantList &keySlots) const
{
    QJsonArray slots;
    for (const auto &s : keySlots)
        slots.append(s.toInt());

    QJsonObject profile;
    profile.insert("id",          QUuid::createUuid().toString(QUuid::WithoutBraces));
    profile.insert("name",        name);
    profile.insert("avatar",      avatar.isEmpty() ? "🏎️" : avatar);
    profile.insert("accentColor", accent.isEmpty() ? "#0A84FF" : accent);
    profile.insert("keySlots",    slots);
    profile.insert("pinEnabled",  false);
    profile.insert("pin",         QString());
    profile.insert("kidMode",     false);

    // Physical memory (seat, mirrors, column)
    QJsonObject seat;
    seat.insert("position", 3);
    seat.insert("lumbar",   2);
    seat.insert("recline",  1);
    profile.insert("seat", seat);

    QJsonObject mirrors;
    mirrors.insert("leftH",  12);
    mirrors.insert("leftV",  8);
    mirrors.insert("rightH", 10);
    mirrors.insert("rightV", 9);
    profile.insert("mirrors", mirrors);

    QJsonObject column;
    column.insert("tilt",      5);
    column.insert("telescope", 3);
    profile.insert("steeringColumn", column);

    // Climate
    QJsonObject climate;
    climate.insert("driverTemp",            72);
    climate.insert("passTemp",              70);
    climate.insert("fanSpeed",              3);
    climate.insert("mode",                  "face");
    climate.insert("acOn",                  true);
    climate.insert("sync",                  false);
    climate.insert("heatedWheel",           false);
    climate.insert("heatedWheelThreshold",  45);
    climate.insert("driverSeatHeat",        0);
    climate.insert("passSeatHeat",          0);
    profile.insert("climate", climate);

    // Audio
    QJsonObject audio;
    audio.insert("source",      "BT");
    audio.insert("volume",      65);
    audio.insert("bass",        1);
    audio.insert("treble",      0);
    audio.insert("balance",     0);
    audio.insert("fade",        0);
    audio.insert("audioPilot",  true);
    audio.insert("centerpoint", false);
    audio.insert("surround",    false);
    profile.insert("audio", audio);

    // Navigation
    QJsonObject nav;
    nav.insert("homeAddress",    QString());
    nav.insert("workAddress",    QString());
    nav.insert("routeType",      "fastest");
    nav.insert("avoidTolls",     false);
    nav.insert("avoidHighways",  false);
    nav.insert("defaultTab",     0);
    profile.insert("nav", nav);

    // Drive character
    QJsonObject drive;
    drive.insert("defaultMode",  0);   // 0=Standard
    drive.insert("bswOn",        true);
    drive.insert("ldwOn",        true);
    drive.insert("febOn",        true);
    drive.insert("vdcOff",       false);
    drive.insert("cruiseOffset", 0);
    drive.insert("showAttesa",   true);
    profile.insert("drive", drive);

    // Display preferences
    QJsonObject display;
    display.insert("brightness",        80);
    display.insert("nightBrightness",   30);
    display.insert("units",             "imperial");
    display.insert("clockFormat",       "12h");
    display.insert("defaultControlTab", 0);
    profile.insert("display", display);

    // Last session (empty on creation)
    QJsonObject session;
    session.insert("timestamp", QString());
    session.insert("distance",  0.0);
    session.insert("avgMpg",    0.0);
    session.insert("duration",  0);
    profile.insert("lastSession", session);

    return profile;
}

// ─── JSON ↔ QVariantMap conversion ───────────────────────────────────────────

QVariantMap ProfileService::jsonToVariant(const QJsonObject &obj) const
{
    return obj.toVariantMap();
}

QJsonObject ProfileService::variantToJson(const QVariantMap &map) const
{
    return QJsonObject::fromVariantMap(map);
}
