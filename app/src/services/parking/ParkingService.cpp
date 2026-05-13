// ParkingService.cpp — single-record parked-location persistence.
#include "ParkingService.h"
#include "../vehicle/VehicleService.h"
#include "../navigation/NavigationService.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QSaveFile>
#include <QStandardPaths>

Q_LOGGING_CATEGORY(lcParking, "q60nav.parking")

// On-target user-data partition; fall back to QStandardPaths off-target.
static constexpr const char *DEFAULT_PARKING_DIR = "/data/q60nav";

// ---------------------------------------------------------------------------
ParkingService::ParkingService(QObject *parent)
    : QObject(parent)
{
    // Load any previously-saved record from disk so the property reflects
    // last-known state immediately after construction.
    loadFromDisk();
}

// ---------------------------------------------------------------------------
void ParkingService::start(VehicleService *vehicleSvc, NavigationService *navSvc)
{
    m_vehicleSvc = vehicleSvc;
    m_navSvc     = navSvc;

    if (m_vehicleSvc) {
        connect(m_vehicleSvc, &VehicleService::ignitionOff,
                this, &ParkingService::onIgnitionOff);
    }

    qCInfo(lcParking) << "Started — parking file:" << parkingFilePath()
                      << "hasRecord:" << m_hasRecord;
}

// ---------------------------------------------------------------------------
QString ParkingService::parkingFilePath() const
{
    QDir target(QString::fromLatin1(DEFAULT_PARKING_DIR));
    if (target.exists() || QDir().mkpath(target.absolutePath())) {
        QFileInfo fi(target.absolutePath());
        if (fi.isDir() && fi.isWritable())
            return target.absolutePath() + QStringLiteral("/parking.json");
    }
    const QString fb = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(fb);
    return fb + QStringLiteral("/parking.json");
}

// ---------------------------------------------------------------------------
void ParkingService::onIgnitionOff()
{
    saveCurrentLocation();
}

// ---------------------------------------------------------------------------
void ParkingService::saveCurrentLocation()
{
    if (!m_navSvc) {
        qCWarning(lcParking) << "No NavigationService — cannot capture position";
        return;
    }
    const QGeoCoordinate pos = m_navSvc->position();
    if (!pos.isValid()) {
        qCInfo(lcParking) << "Position not valid at ignition-off — keeping prior record";
        return;
    }

    m_lat         = pos.latitude();
    m_lon         = pos.longitude();
    m_timestampMs = QDateTime::currentMSecsSinceEpoch();
    m_hasRecord   = true;

    saveToDisk();
    emit parkingChanged();
    qCInfo(lcParking) << "Saved parked location:" << m_lat << m_lon << "@" << m_timestampMs;
}

// ---------------------------------------------------------------------------
void ParkingService::clearParkingLocation()
{
    m_hasRecord   = false;
    m_lat         = 0.0;
    m_lon         = 0.0;
    m_timestampMs = 0;

    QFile::remove(parkingFilePath());
    emit parkingChanged();
    qCInfo(lcParking) << "Cleared parked location";
}

// ---------------------------------------------------------------------------
void ParkingService::navigateToCar()
{
    if (!m_hasRecord) {
        qCInfo(lcParking) << "navigateToCar() — no parked record";
        return;
    }
    emit navigateRequested(m_lat, m_lon, QStringLiteral("My Car"));
    qCInfo(lcParking) << "Requested navigation back to car:" << m_lat << m_lon;
}

// ---------------------------------------------------------------------------
void ParkingService::loadFromDisk()
{
    const QString path = parkingFilePath();
    QFile f(path);
    if (!f.exists()) {
        qCInfo(lcParking) << "No parking record on disk";
        return;
    }
    if (!f.open(QIODevice::ReadOnly)) {
        qCWarning(lcParking) << "Cannot open parking file:" << path;
        return;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isObject()) {
        qCWarning(lcParking) << "parking.json is not a JSON object — ignoring";
        return;
    }
    const QJsonObject obj = doc.object();
    if (!obj.contains("lat") || !obj.contains("lon")) {
        qCWarning(lcParking) << "parking.json missing required keys — ignoring";
        return;
    }
    m_lat         = obj.value("lat").toDouble();
    m_lon         = obj.value("lon").toDouble();
    m_timestampMs = static_cast<qint64>(obj.value("timestampMs").toDouble(0.0));
    m_hasRecord   = true;
    emit parkingChanged();
    qCInfo(lcParking) << "Loaded parked location from disk";
}

// ---------------------------------------------------------------------------
// saveToDisk — atomic write via QSaveFile
// ---------------------------------------------------------------------------
void ParkingService::saveToDisk()
{
    QJsonObject root;
    root["lat"]         = m_lat;
    root["lon"]         = m_lon;
    root["timestampMs"] = static_cast<double>(m_timestampMs);

    const QString path = parkingFilePath();
    QDir().mkpath(QFileInfo(path).absolutePath());

    QSaveFile sf(path);
    if (!sf.open(QIODevice::WriteOnly)) {
        qCWarning(lcParking) << "Cannot open QSaveFile:" << path;
        return;
    }
    sf.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    if (!sf.commit()) {
        qCWarning(lcParking) << "QSaveFile commit failed for parking record";
    }
}
