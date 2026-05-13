#pragma once
// ParkingService.h — Snapshots GPS position on ignition-off so the user can
// later "navigate back to my car". Single-record JSON at
// /data/q60nav/parking.json (overwritten on each ignition cycle).
//
// Persisted via atomic .tmp + rename. Loaded once at boot (constructor).
//
// navigateToCar() emits navigateRequested(lat, lon) — StatusBridge forwards
// the request to NavigationService::routeTo(lat, lon, label).

#include <QObject>
#include <QGeoCoordinate>
#include <QString>

class VehicleService;
class NavigationService;

class ParkingService : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool   hasParkingRecord    READ hasParkingRecord    NOTIFY parkingChanged)
    Q_PROPERTY(double lastParkingLat      READ lastParkingLat      NOTIFY parkingChanged)
    Q_PROPERTY(double lastParkingLon      READ lastParkingLon      NOTIFY parkingChanged)
    Q_PROPERTY(qint64 lastParkingTimestamp READ lastParkingTimestamp NOTIFY parkingChanged)

public:
    explicit ParkingService(QObject *parent = nullptr);
    ~ParkingService() override = default;

    // Wire signal sources; safe to pass nullptr (no-op).
    void start(VehicleService *vehicleSvc, NavigationService *navSvc);

    bool   hasParkingRecord()    const { return m_hasRecord; }
    double lastParkingLat()      const { return m_lat; }
    double lastParkingLon()      const { return m_lon; }
    qint64 lastParkingTimestamp() const { return m_timestampMs; }

public slots:
    // Persist current GPS as the parked location. Called automatically on
    // VehicleService::ignitionOff, and exposed for manual save from QML.
    Q_INVOKABLE void saveCurrentLocation();

    // Clear the saved record (in-memory + disk).
    Q_INVOKABLE void clearParkingLocation();

    // Request route back to the saved location. If a record exists, emits
    // navigateRequested(lat, lon) for StatusBridge to forward to NavigationService.
    Q_INVOKABLE void navigateToCar();

signals:
    void parkingChanged();
    // StatusBridge connects this to NavigationService::routeTo(...)
    void navigateRequested(double lat, double lon, const QString &label);

private slots:
    void onIgnitionOff();

private:
    QString parkingFilePath() const;
    void loadFromDisk();
    void saveToDisk();

    VehicleService    *m_vehicleSvc = nullptr;
    NavigationService *m_navSvc     = nullptr;

    bool   m_hasRecord   = false;
    double m_lat         = 0.0;
    double m_lon         = 0.0;
    qint64 m_timestampMs = 0;
};
