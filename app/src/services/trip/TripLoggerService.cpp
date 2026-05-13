// TripLoggerService.cpp — GPX trace logger + trip computer A/B accumulators.
#include "TripLoggerService.h"
#include "../vehicle/VehicleService.h"
#include "../navigation/NavigationService.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTextStream>
#include <QtMath>

Q_LOGGING_CATEGORY(lcTrip, "q60nav.trip")

// On-target user-data partition; fall back to QStandardPaths off-target.
static constexpr const char *DEFAULT_TRIPS_DIR = "/data/q60nav/trips";

// ---------------------------------------------------------------------------
TripLoggerService::TripLoggerService(QObject *parent)
    : QObject(parent)
    , m_tickTimer(new QTimer(this))
{
    m_tickTimer->setInterval(1000);
    connect(m_tickTimer, &QTimer::timeout, this, &TripLoggerService::onTickSecond);
}

// ---------------------------------------------------------------------------
void TripLoggerService::start(VehicleService *vehicleSvc, NavigationService *navSvc)
{
    m_vehicleSvc = vehicleSvc;
    m_navSvc     = navSvc;

    // Load history index (last 10 records exposed to QML)
    loadIndexFromDisk();

    if (m_vehicleSvc) {
        connect(m_vehicleSvc, &VehicleService::ignitionOnChanged,
                this, &TripLoggerService::onIgnitionChanged);
    }
    if (m_navSvc) {
        connect(m_navSvc, &NavigationService::positionChanged,
                this, &TripLoggerService::onPositionChanged);
    }

    qCInfo(lcTrip) << "Started — trips dir:" << tripsDir();
}

// ---------------------------------------------------------------------------
// Filesystem paths
// ---------------------------------------------------------------------------
QString TripLoggerService::tripsDir() const
{
    // Prefer the on-target user-data partition; fall back to QStandardPaths
    // on dev machines where /data/q60nav doesn't exist.
    QDir target(QString::fromLatin1(DEFAULT_TRIPS_DIR));
    if (target.exists() || QDir().mkpath(target.absolutePath())) {
        // Confirm writability — readback an mkpath result on writable filesystems
        QFileInfo fi(target.absolutePath());
        if (fi.isDir() && fi.isWritable())
            return target.absolutePath();
    }
    const QString fb = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                       + QStringLiteral("/trips");
    QDir().mkpath(fb);
    return fb;
}

QString TripLoggerService::indexPath() const
{
    return tripsDir() + QStringLiteral("/index.json");
}

// ---------------------------------------------------------------------------
// Ignition / position handlers
// ---------------------------------------------------------------------------
void TripLoggerService::onIgnitionChanged(bool on)
{
    if (on) {
        if (!m_tripActive) startTrip();
    } else {
        if (m_tripActive) finalizeTrip();
    }
}

void TripLoggerService::onPositionChanged(const QGeoCoordinate &pos)
{
    if (!pos.isValid()) return;

    // Always update trip A/B distance from position deltas (they run continuously)
    if (m_haveLastPos) {
        const double dMi = haversineMi(m_lastPos, pos);
        if (dMi > 0.0 && dMi < 10.0)   // guard: ignore implausible jumps
            addDistance(dMi);
    }
    m_lastPos     = pos;
    m_haveLastPos = true;

    // If a logged trip is active, capture the GPX point
    if (m_tripActive) {
        GpxPoint p;
        p.lat   = pos.latitude();
        p.lon   = pos.longitude();
        p.eleM  = !qIsNaN(pos.altitude()) ? pos.altitude() : 0.0;
        p.stamp = QDateTime::currentDateTimeUtc();
        m_points.append(p);
    }

    // Sample MPG into all live accumulators (A, B, and current-trip if any)
    if (m_vehicleSvc) {
        const double mpg = m_vehicleSvc->instantMPG();
        if (mpg > 0.0) addMpgSample(mpg);
    }
    if (m_tripActive) emit currentTripChanged();
}

void TripLoggerService::onTickSecond()
{
    if (m_tripActive) emit currentTripChanged();
    // A/B don't tick — distance/time drift only when GPS samples come in
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
void TripLoggerService::startTrip()
{
    m_tripActive        = true;
    m_tripStart         = QDateTime::currentDateTimeUtc();
    m_currentDistanceMi = 0.0;
    m_currentMpgSum     = 0.0;
    m_currentMpgCount   = 0;
    m_points.clear();
    m_haveLastPos       = false;  // first position seeds the deltas

    const QString fname = m_tripStart.toLocalTime().toString(QStringLiteral("yyyyMMdd-HHmmss"))
                          + QStringLiteral(".gpx");
    m_currentGpxPath = tripsDir() + QChar('/') + fname;

    // Open trip-A/B if not currently running
    if (m_tripA.startMs == 0) m_tripA.startMs = m_tripStart.toMSecsSinceEpoch();
    if (m_tripB.startMs == 0) m_tripB.startMs = m_tripStart.toMSecsSinceEpoch();

    m_tickTimer->start();
    emit tripActiveChanged(true);
    emit currentTripChanged();
    qCInfo(lcTrip) << "Trip started ->" << m_currentGpxPath;
}

void TripLoggerService::finalizeTrip()
{
    m_tickTimer->stop();
    const QDateTime endTime = QDateTime::currentDateTimeUtc();

    // Write GPX (only if we have at least one point)
    if (!m_points.isEmpty()) {
        writeGpxFile(m_currentGpxPath);
    } else {
        qCInfo(lcTrip) << "Trip ended with zero GPX points — skipping file write";
    }

    // Build + append summary record
    QVariantMap summary;
    summary["file"]       = QFileInfo(m_currentGpxPath).fileName();
    summary["startTime"]  = m_tripStart.toString(Qt::ISODate);
    summary["endTime"]    = endTime.toString(Qt::ISODate);
    summary["distanceMi"] = m_currentDistanceMi;
    const qint64 durSec   = m_tripStart.secsTo(endTime);
    const double avgMph   = (durSec > 0) ? (m_currentDistanceMi / (durSec / 3600.0)) : 0.0;
    const double avgMpg   = (m_currentMpgCount > 0) ? (m_currentMpgSum / m_currentMpgCount) : 0.0;
    summary["avgMph"]     = avgMph;
    summary["avgMpg"]     = avgMpg;
    summary["durationSec"] = static_cast<int>(durSec);

    appendIndexRecord(summary);

    qCInfo(lcTrip) << "Trip finalized:" << m_currentDistanceMi << "mi /"
                   << durSec << "s / avgMpg" << avgMpg;

    // Reset live state
    m_tripActive        = false;
    m_currentDistanceMi = 0.0;
    m_currentMpgSum     = 0.0;
    m_currentMpgCount   = 0;
    m_points.clear();
    m_currentGpxPath.clear();

    emit tripActiveChanged(false);
    emit currentTripChanged();
    emit tripFinalized(summary);
}

// ---------------------------------------------------------------------------
// GPX writer — atomic via .tmp + rename
// ---------------------------------------------------------------------------
void TripLoggerService::writeGpxFile(const QString &path)
{
    QDir().mkpath(QFileInfo(path).absolutePath());

    const QString tmp = path + QStringLiteral(".tmp");
    QFile f(tmp);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qCWarning(lcTrip) << "Cannot open GPX tmp file:" << tmp;
        return;
    }

    QTextStream s(&f);
    s.setRealNumberPrecision(7);
    s.setRealNumberNotation(QTextStream::FixedNotation);

    s << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    s << "<gpx version=\"1.1\" creator=\"q60nav\" "
         "xmlns=\"http://www.topografix.com/GPX/1/1\">\n";
    s << "  <trk>\n";
    s << "    <name>q60nav trip " << m_tripStart.toString(Qt::ISODate) << "</name>\n";
    s << "    <trkseg>\n";

    for (const GpxPoint &p : m_points) {
        s << "      <trkpt lat=\"" << p.lat << "\" lon=\"" << p.lon << "\">"
          << "<ele>" << p.eleM << "</ele>"
          << "<time>" << p.stamp.toString(Qt::ISODate) << "</time>"
          << "</trkpt>\n";
    }
    s << "    </trkseg>\n";
    s << "  </trk>\n";
    s << "</gpx>\n";
    s.flush();

    if (!f.flush()) {
        qCWarning(lcTrip) << "GPX flush failed:" << tmp;
        f.close();
        QFile::remove(tmp);
        return;
    }
    f.close();

    // Atomic-ish rename (overwrite if exists)
    QFile::remove(path);
    if (!QFile::rename(tmp, path)) {
        qCWarning(lcTrip) << "GPX rename failed:" << tmp << "->" << path;
        QFile::remove(tmp);
        return;
    }
}

// ---------------------------------------------------------------------------
// Index append — load existing array, prepend new record, atomic write
// ---------------------------------------------------------------------------
void TripLoggerService::appendIndexRecord(const QVariantMap &summary)
{
    QJsonArray arr;

    QFile in(indexPath());
    if (in.exists() && in.open(QIODevice::ReadOnly)) {
        const QJsonDocument doc = QJsonDocument::fromJson(in.readAll());
        if (doc.isArray()) arr = doc.array();
        in.close();
    }

    arr.prepend(QJsonObject::fromVariantMap(summary));

    QSaveFile sf(indexPath());
    QDir().mkpath(QFileInfo(indexPath()).absolutePath());
    if (!sf.open(QIODevice::WriteOnly)) {
        qCWarning(lcTrip) << "Cannot open index file for write:" << indexPath();
        return;
    }
    sf.write(QJsonDocument(arr).toJson(QJsonDocument::Indented));
    if (!sf.commit()) {
        qCWarning(lcTrip) << "Index commit failed";
        return;
    }

    // Refresh the QML-visible last-10 slice
    m_recentTrips.clear();
    const int n = qMin(arr.size(), 10);
    for (int i = 0; i < n; ++i)
        m_recentTrips.append(arr.at(i).toObject().toVariantMap());
    emit recentTripsChanged();
}

// ---------------------------------------------------------------------------
// Load index at startup — just the last 10 records.
// ---------------------------------------------------------------------------
void TripLoggerService::loadIndexFromDisk()
{
    QFile in(indexPath());
    if (!in.exists()) {
        qCInfo(lcTrip) << "No trip index yet";
        return;
    }
    if (!in.open(QIODevice::ReadOnly)) {
        qCWarning(lcTrip) << "Cannot read trip index:" << indexPath();
        return;
    }
    const QJsonDocument doc = QJsonDocument::fromJson(in.readAll());
    if (!doc.isArray()) {
        qCWarning(lcTrip) << "Trip index is not a JSON array — ignoring";
        return;
    }
    const QJsonArray arr = doc.array();
    const int n = qMin(arr.size(), 10);
    m_recentTrips.clear();
    for (int i = 0; i < n; ++i)
        m_recentTrips.append(arr.at(i).toObject().toVariantMap());
    emit recentTripsChanged();
    qCInfo(lcTrip) << "Loaded" << n << "recent trip records";
}

// ---------------------------------------------------------------------------
// Distance + MPG accumulator helpers
// ---------------------------------------------------------------------------
void TripLoggerService::addDistance(double miles)
{
    m_tripA.distanceMi += miles;
    m_tripB.distanceMi += miles;
    if (m_tripActive) m_currentDistanceMi += miles;

    emit tripAChanged();
    emit tripBChanged();
    if (m_tripActive) emit currentTripChanged();
}

void TripLoggerService::addMpgSample(double mpg)
{
    m_tripA.mpgSum += mpg; ++m_tripA.mpgCount;
    m_tripB.mpgSum += mpg; ++m_tripB.mpgCount;
    if (m_tripActive) {
        m_currentMpgSum += mpg;
        ++m_currentMpgCount;
    }
    emit tripAChanged();
    emit tripBChanged();
}

// ---------------------------------------------------------------------------
// Haversine — great-circle distance in miles
// ---------------------------------------------------------------------------
double TripLoggerService::haversineMi(const QGeoCoordinate &a, const QGeoCoordinate &b)
{
    if (!a.isValid() || !b.isValid()) return 0.0;
    constexpr double R_MI = 3958.7613;  // Earth radius, miles
    const double lat1 = qDegreesToRadians(a.latitude());
    const double lat2 = qDegreesToRadians(b.latitude());
    const double dLat = qDegreesToRadians(b.latitude() - a.latitude());
    const double dLon = qDegreesToRadians(b.longitude() - a.longitude());
    const double sa = qSin(dLat / 2.0);
    const double sb = qSin(dLon / 2.0);
    const double h  = sa * sa + qCos(lat1) * qCos(lat2) * sb * sb;
    return 2.0 * R_MI * qAsin(qMin(1.0, qSqrt(h)));
}

// ---------------------------------------------------------------------------
// Derived accessors
// ---------------------------------------------------------------------------
double TripLoggerService::currentTripAvgMph() const
{
    const int dur = currentTripDurationSec();
    return (dur > 0) ? (m_currentDistanceMi / (dur / 3600.0)) : 0.0;
}

double TripLoggerService::currentTripAvgMpg() const
{
    return (m_currentMpgCount > 0) ? (m_currentMpgSum / m_currentMpgCount) : 0.0;
}

int TripLoggerService::currentTripDurationSec() const
{
    if (!m_tripActive || !m_tripStart.isValid()) return 0;
    return static_cast<int>(m_tripStart.secsTo(QDateTime::currentDateTimeUtc()));
}

double TripLoggerService::tripAAvgMph() const
{
    const int dur = tripADurationSec();
    return (dur > 0) ? (m_tripA.distanceMi / (dur / 3600.0)) : 0.0;
}

double TripLoggerService::tripAAvgMpg() const
{
    return (m_tripA.mpgCount > 0) ? (m_tripA.mpgSum / m_tripA.mpgCount) : 0.0;
}

int TripLoggerService::tripADurationSec() const
{
    if (m_tripA.startMs == 0) return 0;
    return static_cast<int>((QDateTime::currentMSecsSinceEpoch() - m_tripA.startMs) / 1000);
}

double TripLoggerService::tripBAvgMph() const
{
    const int dur = tripBDurationSec();
    return (dur > 0) ? (m_tripB.distanceMi / (dur / 3600.0)) : 0.0;
}

double TripLoggerService::tripBAvgMpg() const
{
    return (m_tripB.mpgCount > 0) ? (m_tripB.mpgSum / m_tripB.mpgCount) : 0.0;
}

int TripLoggerService::tripBDurationSec() const
{
    if (m_tripB.startMs == 0) return 0;
    return static_cast<int>((QDateTime::currentMSecsSinceEpoch() - m_tripB.startMs) / 1000);
}

// ---------------------------------------------------------------------------
// Resets — match factory behavior: zero the meter, restart its timer
// ---------------------------------------------------------------------------
void TripLoggerService::resetTripA()
{
    m_tripA = TripMeter{};
    m_tripA.startMs = QDateTime::currentMSecsSinceEpoch();
    emit tripAChanged();
    qCInfo(lcTrip) << "Trip A reset";
}

void TripLoggerService::resetTripB()
{
    m_tripB = TripMeter{};
    m_tripB.startMs = QDateTime::currentMSecsSinceEpoch();
    emit tripBChanged();
    qCInfo(lcTrip) << "Trip B reset";
}
