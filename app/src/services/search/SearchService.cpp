// SearchService.cpp — offline geocoding
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
    qDebug() << "[SearchService] started";
}

void SearchService::search(const QString &query, int maxResults)
{
    // Try Valhalla /search endpoint first (bundled, always available)
    QUrl url(QString("http://localhost:%1/search").arg(VALHALLA_PORT));
    QUrlQuery params;
    params.addQueryItem("text", query);
    params.addQueryItem("size", QString::number(maxResults));
    url.setQuery(params);

    QNetworkRequest req(url);
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            emit searchError(reply->errorString());
            return;
        }
        QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (doc.isNull()) { emit searchError("Invalid JSON"); return; }

        QJsonArray features = doc.object()["features"].toArray();
        QJsonArray results;
        for (auto f : features) {
            QJsonObject feat = f.toObject();
            QJsonObject props = feat["properties"].toObject();
            QJsonArray  coords = feat["geometry"].toObject()["coordinates"].toArray();
            if (coords.size() < 2) continue;

            QJsonObject r;
            r["label"]   = props["label"].toString();
            r["name"]    = props["name"].toString();
            r["city"]    = props["locality"].toString();
            r["state"]   = props["region_a"].toString();
            r["lat"]     = coords[1].toDouble();
            r["lon"]     = coords[0].toDouble();
            results.append(r);
        }
        emit resultsReady(results);
    });
}

void SearchService::reverseGeocode(double lat, double lon)
{
    QUrl url(QString("http://localhost:%1/reverse").arg(VALHALLA_PORT));
    QUrlQuery params;
    params.addQueryItem("point.lat", QString::number(lat, 'f', 6));
    params.addQueryItem("point.lon", QString::number(lon, 'f', 6));
    params.addQueryItem("size", "1");
    url.setQuery(params);

    QNetworkRequest req(url);
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) return;
        QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (doc.isNull()) return;
        QJsonArray features = doc.object()["features"].toArray();
        if (features.isEmpty()) return;
        QString label = features[0].toObject()["properties"]
                                   .toObject()["label"].toString();
        emit reverseResult(label);
    });
}

void SearchService::onSearchReply()  {}
void SearchService::onReverseReply() {}
