#pragma once
#include <QObject>
#include <QString>
#include <QJsonArray>
#include <QNetworkAccessManager>
#include <QNetworkReply>

// SearchService — offline geocoding / POI search
//
// Backend priority:
//   1. Nominatim-lite on localhost:4000  (offline OSM geocoder — optional)
//   2. Photon on localhost:4001          (alternative offline geocoder — optional)
//   3. Graceful empty result set if neither is running
//
// Valhalla (port 8002) is ROUTING ONLY — not used for geocoding.
//
// To enable search on the device, install and run one of:
//   - nominatim-docker (heavy, ~20GB for US)
//   - photon (lighter, ~8GB)
//   - custom SQLite POI index (Phase 4 — see docs/search.md)

class SearchService : public QObject {
    Q_OBJECT

public:
    explicit SearchService(QObject *parent = nullptr);
    void start();

public slots:
    // Free-text search — emits resultsReady or searchError
    void search(const QString &query, int maxResults = 8);

    // Reverse geocode lat/lon to address string — emits reverseResult
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

    // Geocoding service port (Nominatim-lite or Photon)
    // Valhalla port 8002 is NOT used here
    static constexpr int GEOCODER_PORT = 4000;
};
