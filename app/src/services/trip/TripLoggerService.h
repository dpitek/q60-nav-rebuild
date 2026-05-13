#pragma once
// TripLoggerService.h — Per-ignition-cycle GPX trace + trip summary persistence.
//
// On ignition ON: starts a new trip (GPX point buffer in memory).
// On ignition OFF: writes a GPX 1.1 file to /data/q60nav/trips/YYYYMMDD-HHMMSS.gpx
//                  and appends a summary record to /data/q60nav/trips/index.json.
//
// Also exposes independent trip-A / trip-B accumulators (matching factory trip
// computer behavior). These are NOT persisted across power cycles — same as the
// OEM trip meters.
//
// Distance = Haversine sum over NavigationService.position deltas.
// Avg MPG  = mean of VehicleService.instantMPG samples over the trip duration.
// Avg MPH  = distance / elapsed-time.
//
// Instantiated in main.cpp, exposed to QML as "TripLoggerService".

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QGeoCoordinate>
#include <QDateTime>
#include <QVector>
#include <QTimer>

class VehicleService;
class NavigationService;

class TripLoggerService : public QObject
{
    Q_OBJECT

    // ── GPX-logged current trip ─────────────────────────────────────────────
    Q_PROPERTY(bool   tripActive             READ tripActive             NOTIFY tripActiveChanged)
    Q_PROPERTY(double currentTripDistanceMi  READ currentTripDistanceMi  NOTIFY currentTripChanged)
    Q_PROPERTY(double currentTripAvgMph      READ currentTripAvgMph      NOTIFY currentTripChanged)
    Q_PROPERTY(double currentTripAvgMpg      READ currentTripAvgMpg      NOTIFY currentTripChanged)
    Q_PROPERTY(int    currentTripDurationSec READ currentTripDurationSec NOTIFY currentTripChanged)

    // ── Recent trip summary list (last 10, newest first) ────────────────────
    Q_PROPERTY(QVariantList recentTrips      READ recentTrips            NOTIFY recentTripsChanged)

    // ── Trip computer A (user-resettable, in-memory only) ───────────────────
    Q_PROPERTY(double tripADistanceMi  READ tripADistanceMi  NOTIFY tripAChanged)
    Q_PROPERTY(double tripAAvgMph      READ tripAAvgMph      NOTIFY tripAChanged)
    Q_PROPERTY(double tripAAvgMpg      READ tripAAvgMpg      NOTIFY tripAChanged)
    Q_PROPERTY(int    tripADurationSec READ tripADurationSec NOTIFY tripAChanged)

    // ── Trip computer B (user-resettable, in-memory only) ───────────────────
    Q_PROPERTY(double tripBDistanceMi  READ tripBDistanceMi  NOTIFY tripBChanged)
    Q_PROPERTY(double tripBAvgMph      READ tripBAvgMph      NOTIFY tripBChanged)
    Q_PROPERTY(double tripBAvgMpg      READ tripBAvgMpg      NOTIFY tripBChanged)
    Q_PROPERTY(int    tripBDurationSec READ tripBDurationSec NOTIFY tripBChanged)

public:
    explicit TripLoggerService(QObject *parent = nullptr);
    ~TripLoggerService() override = default;

    // Call once after VehicleService + NavigationService exist
    void start(VehicleService *vehicleSvc, NavigationService *navSvc);

    // ── Accessors ────────────────────────────────────────────────────────────
    bool   tripActive()             const { return m_tripActive; }
    double currentTripDistanceMi()  const { return m_currentDistanceMi; }
    double currentTripAvgMph()      const;
    double currentTripAvgMpg()      const;
    int    currentTripDurationSec() const;

    QVariantList recentTrips()      const { return m_recentTrips; }

    double tripADistanceMi()  const { return m_tripA.distanceMi; }
    double tripAAvgMph()      const;
    double tripAAvgMpg()      const;
    int    tripADurationSec() const;

    double tripBDistanceMi()  const { return m_tripB.distanceMi; }
    double tripBAvgMph()      const;
    double tripBAvgMpg()      const;
    int    tripBDurationSec() const;

public slots:
    Q_INVOKABLE void resetTripA();
    Q_INVOKABLE void resetTripB();

signals:
    void tripActiveChanged(bool);
    void currentTripChanged();
    void recentTripsChanged();
    void tripAChanged();
    void tripBChanged();
    void tripFinalized(QVariantMap summary);  // emitted after GPX + index write

private slots:
    void onIgnitionChanged(bool on);
    void onPositionChanged(const QGeoCoordinate &pos);
    void onTickSecond();

private:
    struct TripMeter {
        double  distanceMi  = 0.0;
        double  mpgSum      = 0.0;
        int     mpgCount    = 0;
        qint64  startMs     = 0;
        qint64  accumulatedMs = 0;  // for paused-A/B style elapsed; we keep simple
    };

    // Paths (creates dirs as needed)
    QString tripsDir() const;
    QString indexPath() const;

    // Lifecycle
    void startTrip();
    void finalizeTrip();

    // I/O
    void writeGpxFile(const QString &path);
    void appendIndexRecord(const QVariantMap &summary);
    void loadIndexFromDisk();

    // Math
    static double haversineMi(const QGeoCoordinate &a, const QGeoCoordinate &b);

    // Accumulator-update helpers
    void addDistance(double miles);
    void addMpgSample(double mpg);

    VehicleService    *m_vehicleSvc = nullptr;
    NavigationService *m_navSvc     = nullptr;

    // Active GPX trip state
    bool             m_tripActive       = false;
    QDateTime        m_tripStart;
    QGeoCoordinate   m_lastPos;          // for Haversine deltas
    bool             m_haveLastPos      = false;
    double           m_currentDistanceMi = 0.0;
    double           m_currentMpgSum    = 0.0;
    int              m_currentMpgCount  = 0;
    QString          m_currentGpxPath;

    struct GpxPoint {
        double    lat;
        double    lon;
        double    eleM;        // metres
        QDateTime stamp;       // UTC
    };
    QVector<GpxPoint> m_points;

    // Trip A / B accumulators
    TripMeter m_tripA;
    TripMeter m_tripB;

    // Recent trip summaries (loaded from index.json)
    QVariantList m_recentTrips;

    // 1Hz tick to refresh duration-derived Q_PROPERTYs
    QTimer *m_tickTimer = nullptr;
};
