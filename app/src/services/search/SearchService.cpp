// SearchService.cpp — offline geocoding / POI search
// Calls local geocoding service on port 4000 (Nominatim-lite or Photon).
// Gracefully returns empty results if geocoder is not running.
// Valhalla (port 8002) is NOT used here — routing only.

#include "SearchService.h"
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrl>
#include <QUrlQuery>
#include <QDebug>

SearchService::SearchService(QObject *parent)
    : QObject(parent)
    , m_nam(new QNetworkAccessManager(this))
{
}

void SearchService::start()
{
    qDebug() << "[SearchService] started (geocoder port" << GEOCODER_PORT << ")";
}

void SearchService::search(const QString &query, int maxResults)
{
    // Pelias/Nominatim-compatible /search endpoint
    QUrl url(QString("http://localhost:%1/search").arg(GEOCODER_PORT));
    QUrlQuery params;
    params.addQueryItem("text", query);
    params.addQueryItem("size", QString::number(maxResults));
    url.setQuery(params);

    QNetworkRequest req(url);
    req.setTransferTimeout(2000); // 2s timeout — don't hang UI if geocoder absent
    QNetworkReply *reply = m_nam->get(req);

    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            // Geocoder not running — emit empty results (not an error the UI needs to show)
            qDebug() << "[SearchService] geocoder unavailable:" << reply->errorString();
            emit resultsReady(QJsonArray());
            return;
        }

        QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (doc.isNull()) {
            emit searchError("Invalid JSON from geocoder");
            return;
        }

        // Pelias GeoJSON response: { "features": [...] }
        QJsonArray features = doc.object()["features"].toArray();
        QJsonArray results;
        for (const auto &f : features) {
            QJsonObject feat   = f.toObject();
            QJsonObject props  = feat["properties"].toObject();
            QJsonArray  coords = feat["geometry"].toObject()["coordinates"].toArray();
            if (coords.size() < 2) continue;

            QJsonObject r;
            r["label"] = props["label"].toString(props["name"].toString());
            r["name"]  = props["name"].toString();
            r["city"]  = props.contains("locality")
                         ? props["locality"].toString()
                         : props["city"].toString();
            r["state"] = props["region_a"].toString();
            r["lat"]   = coords[1].toDouble();
            r["lon"]   = coords[0].toDouble();
            results.append(r);
        }
        emit resultsReady(results);
    });
}

void SearchService::reverseGeocode(double lat, double lon)
{
    QUrl url(QString("http://localhost:%1/reverse").arg(GEOCODER_PORT));
    QUrlQuery params;
    params.addQueryItem("point.lat", QString::number(lat, 'f', 6));
    params.addQueryItem("point.lon", QString::number(lon, 'f', 6));
    params.addQueryItem("size", "1");
    url.setQuery(params);

    QNetworkRequest req(url);
    req.setTransferTimeout(2000);
    QNetworkReply *reply = m_nam->get(req);

    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            // Geocoder absent — emit empty address string, UI shows coordinates
            emit reverseResult(QString());
            return;
        }
        QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (doc.isNull()) return;

        QJsonArray features = doc.object()["features"].toArray();
        if (features.isEmpty()) { emit reverseResult(QString()); return; }

        QString label = features[0].toObject()["properties"]
                                   .toObject()["label"].toString();
        emit reverseResult(label);
    });
}

void SearchService::onSearchReply()  {}
void SearchService::onReverseReply() {}
