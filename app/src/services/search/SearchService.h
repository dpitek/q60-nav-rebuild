#pragma once
#include <QObject>
#include <QString>
#include <QJsonArray>
#include <QNetworkAccessManager>
#include <QNetworkReply>

// SearchService — offline geocoding via local Nominatim or Pelias instance
// Falls back to Valhalla's built-in /search if neither is available

class SearchService : public QObject {
    Q_OBJECT

public:
    explicit SearchService(QObject *parent = nullptr);
    void start();

public slots:
    void search(const QString &query, int maxResults = 8);
    void reverseGeocode(double lat, double lon);

signals:
    void resultsReady(const QJsonArray &results);
    void reverseResult(const QString &address);
    void searchError(const QString &error);

private slots:
    void onSearchReply();
    void onReverseReply();

private:
    QNetworkAccessManager *m_nam;

    // Nominatim on localhost:7070 (if running)
    // Falls back to Valhalla /search on 8002
    static constexpr int NOMINATIM_PORT = 7070;
    static constexpr int VALHALLA_PORT  = 8002;
};
