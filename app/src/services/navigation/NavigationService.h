#pragma once
#include <QObject>
#include <QGeoCoordinate>
#include <QTimer>
#include <QString>
#include <QJsonObject>
#include <QProcess>
#include <QVector>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QTcpSocket>

struct RouteStep {
    QString instruction;
    QString streetName;
    double  distanceMiles = 0.0;
    int     type = 0;
};

class NavigationService : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool active          READ active          NOTIFY activeChanged)
    Q_PROPERTY(QString nextStreet   READ nextStreet      NOTIFY instructionChanged)
    Q_PROPERTY(QString nextManeuver READ nextManeuver    NOTIFY instructionChanged)
    Q_PROPERTY(double  nextDistance READ nextDistance    NOTIFY instructionChanged)
    Q_PROPERTY(QString eta          READ eta             NOTIFY etaChanged)
    Q_PROPERTY(double  remaining    READ remaining       NOTIFY remainingChanged)
    Q_PROPERTY(double  currentSpeed READ currentSpeed    NOTIFY currentSpeedChanged)
    Q_PROPERTY(double  speedLimit   READ speedLimit      NOTIFY speedLimitChanged)
    Q_PROPERTY(QGeoCoordinate position READ position     NOTIFY positionChanged)
    Q_PROPERTY(bool    rerouting    READ rerouting       NOTIFY reroutingChanged)

public:
    explicit NavigationService(QObject *parent = nullptr);
    void start();

    bool   active()        const { return m_active; }
    QString nextStreet()   const { return m_nextStreet; }
    QString nextManeuver() const { return m_nextManeuver; }
    double  nextDistance() const { return m_nextDistance; }
    QString eta()          const { return m_eta; }
    double  remaining()    const { return m_remaining; }
    double  currentSpeed() const { return m_currentSpeed; }
    double  speedLimit()   const { return m_speedLimit; }
    QGeoCoordinate position() const { return m_position; }
    bool    rerouting()    const { return m_rerouting; }

public slots:
    void routeTo(double lat, double lon, const QString &label);
    void routeToAddress(const QString &address);
    void cancelRoute();
    void updateSpeed(float mph); // called by VehicleService

signals:
    void activeChanged(bool);
    void instructionChanged();
    void etaChanged(QString);
    void remainingChanged(double);
    void currentSpeedChanged(double);
    void speedLimitChanged(double);
    void positionChanged(QGeoCoordinate);
    void reroutingChanged(bool);
    void arrivalReached();
    void routeCalculated(QJsonObject route);

private slots:
    void onGpsUpdate();
    void onGpsdData();
    void onValhallaResponse(QNetworkReply *reply);
    void onRerouteTimer();

private:
    void parseValhallaRoute(const QByteArray &json);
    void updateInstruction();
    void callValhalla(double fromLat, double fromLon,
                      double toLat,  double toLon);
    void connectGpsd();

    // Valhalla runs as local daemon on port 8002
    static constexpr int VALHALLA_PORT = 8002;

    bool   m_active = false;
    bool   m_rerouting = false;
    bool   m_gpsLock = false;
    QString m_nextStreet;
    QString m_nextManeuver;
    double  m_nextDistance = 0.0;
    QString m_eta;
    double  m_remaining = 0.0;
    double  m_currentSpeed = 0.0;
    double  m_speedLimit = 0.0;
    QString m_destinationLabel;
    QGeoCoordinate m_position;
    QGeoCoordinate m_destination;

    // Route state
    QVector<QVector<RouteStep>> m_legs;
    int m_currentLeg  = 0;
    int m_currentStep = 0;

    QNetworkAccessManager *m_nam;
    QTcpSocket            *m_gpsd;
    QTimer m_gpsTimer;       // 1 Hz GPS poll
    QTimer m_rerouteTimer;   // 30s reroute check
};
