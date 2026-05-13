// NavigationService.cpp
// Offline routing via Valhalla HTTP (localhost:8002)
// GPS via GPSD socket (/var/run/gpsd.sock or TCP localhost:2947)

#include "NavigationService.h"
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QTcpSocket>
#include <QTimer>
#include <QDebug>
#include <QDateTime>
#include <cmath>

// GPSD JSON protocol — we open a raw TCP socket to GPSD on port 2947
static const char *GPSD_HOST = "localhost";
static const int   GPSD_PORT = 2947;

NavigationService::NavigationService(QObject *parent)
    : QObject(parent)
    , m_nam(new QNetworkAccessManager(this))
    , m_gpsd(new QTcpSocket(this))
{
    m_gpsTimer.setInterval(1000);   // 1 Hz
    m_rerouteTimer.setInterval(30000); // 30s

    connect(&m_gpsTimer,    &QTimer::timeout, this, &NavigationService::onGpsUpdate);
    connect(&m_rerouteTimer,&QTimer::timeout, this, &NavigationService::onRerouteTimer);
    connect(m_gpsd, &QTcpSocket::readyRead,   this, &NavigationService::onGpsdData);
    connect(m_gpsd, &QTcpSocket::connected,   this, [this]() {
        // Subscribe to TPV (time-position-velocity) reports
        m_gpsd->write("?WATCH={\"enable\":true,\"json\":true}\n");
        qDebug() << "[NavigationService] GPSD connected";
    });
    connect(m_gpsd, &QTcpSocket::errorOccurred, this, [this](QAbstractSocket::SocketError err) {
        Q_UNUSED(err)
        qWarning() << "[NavigationService] GPSD error:" << m_gpsd->errorString()
                   << "— retrying in 5s";
        QTimer::singleShot(5000, this, &NavigationService::connectGpsd);
    });
}

void NavigationService::start()
{
    connectGpsd();
    m_gpsTimer.start();
    qDebug() << "[NavigationService] started, Valhalla at" << VALHALLA_PORT;
}

void NavigationService::connectGpsd()
{
    m_gpsd->connectToHost(GPSD_HOST, GPSD_PORT);
}

// ─── GPS ──────────────────────────────────────────────────────────────────
void NavigationService::onGpsdData()
{
    while (m_gpsd->canReadLine()) {
        QByteArray line = m_gpsd->readLine().trimmed();
        QJsonDocument doc = QJsonDocument::fromJson(line);
        if (doc.isNull()) continue;
        QJsonObject obj = doc.object();
        if (obj["class"].toString() != "TPV") continue;

        double lat = obj["lat"].toDouble(std::numeric_limits<double>::quiet_NaN());
        double lon = obj["lon"].toDouble(std::numeric_limits<double>::quiet_NaN());
        double spd = obj["speed"].toDouble(0.0); // m/s

        bool haveFix = std::isfinite(lat) && std::isfinite(lon);
        if (haveFix != m_gpsLock) {
            m_gpsLock = haveFix;
            // StatusBridge connects to this via VehicleService signals indirectly
        }
        if (haveFix) {
            QGeoCoordinate newPos(lat, lon);
            if (newPos != m_position) {
                m_position = newPos;
                emit positionChanged(m_position);
            }
            double mph = spd * 2.23694;
            if (mph != m_currentSpeed) {
                m_currentSpeed = mph;
                emit currentSpeedChanged(mph);
            }
        }
    }
}

void NavigationService::onGpsUpdate()
{
    // Main 1Hz tick — update instruction progress if route active
    if (!m_active) return;
    updateInstruction();
}

// ─── Routing ───────────────────────────────────────────────────────────────
void NavigationService::routeTo(double lat, double lon, const QString &label)
{
    if (!m_gpsLock) {
        qWarning() << "[NavigationService] No GPS fix — routing from last known position";
    }
    m_destination = QGeoCoordinate(lat, lon);
    m_destinationLabel = label;
    callValhalla(m_position.latitude(), m_position.longitude(), lat, lon);
}

void NavigationService::routeToAddress(const QString &address)
{
    // Geocoding via Valhalla's /search endpoint (Pelias-compatible)
    // If Pelias not available, fall back to offline Nominatim or reject
    QUrl url(QString("http://localhost:%1/search?text=%2&size=1")
             .arg(VALHALLA_PORT).arg(QString::fromUtf8(QUrl::toPercentEncoding(address))));
    QNetworkRequest req(url);
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[NavigationService] Geocode failed:" << reply->errorString();
            reply->deleteLater();
            return;
        }
        QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        reply->deleteLater();
        QJsonArray features = doc.object()["features"].toArray();
        if (features.isEmpty()) {
            qWarning() << "[NavigationService] No geocode results";
            return;
        }
        QJsonArray coords = features[0].toObject()["geometry"]
                                       .toObject()["coordinates"].toArray();
        if (coords.size() < 2) return;
        double lon = coords[0].toDouble();
        double lat = coords[1].toDouble();
        QString label = features[0].toObject()["properties"]
                                    .toObject()["label"].toString();
        routeTo(lat, lon, label);
    });
}

void NavigationService::cancelRoute()
{
    m_active = false;
    m_nextStreet.clear();
    m_nextManeuver.clear();
    m_nextDistance = 0.0;
    m_eta.clear();
    m_remaining = 0.0;
    m_rerouteTimer.stop();
    m_legs.clear();
    m_currentLeg = 0;
    m_currentStep = 0;
    emit activeChanged(false);
    emit instructionChanged();
    emit etaChanged(QString());
    qDebug() << "[NavigationService] Route cancelled";
}

void NavigationService::updateSpeed(float mph)
{
    m_currentSpeed = mph;
    emit currentSpeedChanged(mph);
}

// ─── Valhalla HTTP ─────────────────────────────────────────────────────────
void NavigationService::callValhalla(double fromLat, double fromLon,
                                      double toLat,   double toLon)
{
    QJsonObject from, to;
    from["lat"] = fromLat; from["lon"] = fromLon;
    to["lat"]   = toLat;   to["lon"]   = toLon;

    QJsonObject costing;  // auto mode with defaults
    QJsonObject req;
    req["locations"] = QJsonArray{ from, to };
    req["costing"]   = "auto";
    req["directions_options"] = QJsonObject{
        {"units", "miles"},
        {"narrative", true}
    };

    QNetworkRequest netReq(
        QUrl(QString("http://localhost:%1/route").arg(VALHALLA_PORT)));
    netReq.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");

    QNetworkReply *reply = m_nam->post(
        netReq, QJsonDocument(req).toJson(QJsonDocument::Compact));

    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        onValhallaResponse(reply);
    });
    qDebug() << "[NavigationService] Route request sent to Valhalla";
}

void NavigationService::onValhallaResponse(QNetworkReply *reply)
{
    if (reply->error() != QNetworkReply::NoError) {
        qWarning() << "[NavigationService] Valhalla error:" << reply->errorString();
        reply->deleteLater();
        if (m_rerouting) {
            m_rerouting = false;
            emit reroutingChanged(false);
        }
        return;
    }
    QByteArray data = reply->readAll();
    reply->deleteLater();
    parseValhallaRoute(data);
}

void NavigationService::parseValhallaRoute(const QByteArray &json)
{
    QJsonDocument doc = QJsonDocument::fromJson(json);
    if (doc.isNull()) {
        qWarning() << "[NavigationService] Invalid Valhalla JSON";
        return;
    }
    QJsonObject root = doc.object();
    QJsonObject trip = root["trip"].toObject();
    if (trip.isEmpty()) {
        qWarning() << "[NavigationService] No trip in Valhalla response";
        return;
    }

    // Parse legs and steps
    m_legs.clear();
    m_currentLeg = 0;
    m_currentStep = 0;

    QJsonArray legs = trip["legs"].toArray();
    for (auto legVal : legs) {
        QJsonObject leg = legVal.toObject();
        QJsonArray  maneuvers = leg["maneuvers"].toArray();
        QVector<RouteStep> steps;
        for (auto manVal : maneuvers) {
            QJsonObject man = manVal.toObject();
            RouteStep step;
            step.instruction = man["verbal_pre_transition_instruction"].toString();
            if (step.instruction.isEmpty())
                step.instruction = man["instruction"].toString();
            step.streetName    = man["street_names"].toArray().isEmpty()
                                 ? QString()
                                 : man["street_names"].toArray()[0].toString();
            step.distanceMiles = man["length"].toDouble();
            step.type          = man["type"].toInt();
            steps.append(step);
        }
        m_legs.append(steps);
    }

    // Summary
    QJsonObject summary = trip["summary"].toObject();
    double totalMiles   = summary["length"].toDouble();
    double totalSeconds = summary["time"].toDouble();

    m_remaining = totalMiles;
    emit remainingChanged(m_remaining);

    // ETA
    QDateTime arrival = QDateTime::currentDateTime().addSecs(
        static_cast<qint64>(totalSeconds));
    m_eta = arrival.toString("h:mm AP");
    emit etaChanged(m_eta);

    // First instruction
    if (!m_legs.isEmpty() && !m_legs[0].isEmpty()) {
        const RouteStep &step = m_legs[0][0];
        m_nextStreet   = step.streetName;
        m_nextManeuver = step.instruction;
        m_nextDistance = step.distanceMiles;
        emit instructionChanged();
    }

    if (!m_active) {
        m_active = true;
        emit activeChanged(true);
    }
    if (m_rerouting) {
        m_rerouting = false;
        emit reroutingChanged(false);
    }

    m_rerouteTimer.start();
    emit routeCalculated(root);
    qDebug() << "[NavigationService] Route parsed —" << totalMiles
             << "mi," << totalSeconds / 60 << "min";
}

// ─── Instruction progress ──────────────────────────────────────────────────
void NavigationService::updateInstruction()
{
    if (m_legs.isEmpty() || m_currentLeg >= m_legs.size()) return;
    const auto &steps = m_legs[m_currentLeg];
    if (m_currentStep >= steps.size()) return;

    // Simple distance-based step advancement
    // Real impl: use shape_index from Valhalla + GPS position match
    // For now: advance when distance to next maneuver < 0.05mi (GPS tolerance)
    const RouteStep &step = steps[m_currentStep];
    double distToNext = m_position.distanceTo(m_destination) * 0.000621371; // m → miles

    // Update remaining distance
    double newRemaining = distToNext;
    if (newRemaining != m_remaining) {
        m_remaining = newRemaining;
        emit remainingChanged(m_remaining);
    }

    // Advance step if close enough (crude — replace with shape matching)
    if (step.distanceMiles > 0 && distToNext < 0.03) {
        m_currentStep++;
        if (m_currentStep >= steps.size()) {
            // Advance to next leg
            m_currentLeg++;
            m_currentStep = 0;
        }
        if (m_currentLeg >= m_legs.size()) {
            // Arrived
            m_active = false;
            emit activeChanged(false);
            emit arrivalReached();
            cancelRoute();
            return;
        }
        const RouteStep &next = m_legs[m_currentLeg][m_currentStep];
        m_nextStreet   = next.streetName;
        m_nextManeuver = next.instruction;
        m_nextDistance = next.distanceMiles;
        emit instructionChanged();
    }
}

// ─── Reroute ───────────────────────────────────────────────────────────────
void NavigationService::onRerouteTimer()
{
    if (!m_active || !m_gpsLock) return;
    // Trigger reroute if we appear off-route (simplified check)
    // Full impl: compare GPS position against Valhalla route shape
    if (!m_rerouting) {
        m_rerouting = true;
        emit reroutingChanged(true);
        callValhalla(m_position.latitude(), m_position.longitude(),
                     m_destination.latitude(), m_destination.longitude());
    }
}

// ─── Lane guidance (stub) ──────────────────────────────────────────────────
// Phase 3: parse the maneuver["lanes"] array out of Valhalla's verbal/visual
// guidance response. Each lane has a bitfield of valid directions + an
// "is_preferred" flag. For now we synthesize a plausible lane set based on the
// upcoming maneuver text so the QML lane-arrow widget can be rendered and
// styled against realistic mock data.
QVariantList NavigationService::laneInfo() const
{
    QVariantList lanes;
    if (!m_active || m_nextManeuver.isEmpty() || m_nextDistance <= 0.0)
        return lanes;

    const QString m = m_nextManeuver.toLower();
    const bool leftish  = m.contains(QStringLiteral("left"));
    const bool rightish = m.contains(QStringLiteral("right"));

    auto makeLane = [](const QString &dir, bool active) {
        QVariantMap lane;
        lane.insert(QStringLiteral("direction"), dir);
        lane.insert(QStringLiteral("active"),    active);
        return lane;
    };

    if (leftish) {
        lanes.append(makeLane(QStringLiteral("left"),     true));
        lanes.append(makeLane(QStringLiteral("straight"), false));
        lanes.append(makeLane(QStringLiteral("straight"), false));
    } else if (rightish) {
        lanes.append(makeLane(QStringLiteral("straight"), false));
        lanes.append(makeLane(QStringLiteral("straight"), false));
        lanes.append(makeLane(QStringLiteral("right"),    true));
    } else {
        lanes.append(makeLane(QStringLiteral("straight"), true));
        lanes.append(makeLane(QStringLiteral("straight"), true));
    }
    return lanes;
}
