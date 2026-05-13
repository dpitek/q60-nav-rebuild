#pragma once
// FuelService — EIA weekly retail gasoline prices by PADD region
// API: https://api.eia.gov/v2/petroleum/pri/gnd/data/
//      ?api_key={KEY}&frequency=weekly&data[0]=value
//      &facets[product][]=EPM0&facets[product][]=EPM2&facets[product][]=EPD2D
//      &facets[duoarea][]=R1X  (PADD 1C = Southeast)
//      &sort[0][column]=period&sort[0][direction]=desc&length=3
// Free API — register at eia.gov for key.
// Falls back to a hardcoded recent value if API unavailable or offline.
// Config: /opt/nav/config/config.json → "eia" → { "api_key": "...", "padd_region": "R1X" }
//
// AIR-GAP: offline by default. NetworkService must call setNetworkOnline(true) before
// any external request fires. Falls back to hardcoded prices when offline or unconfigured.
#include <QObject>
#include <QString>
#include <QTimer>
#include <QNetworkAccessManager>
#include <QNetworkReply>

class FuelService : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool    available     READ available     NOTIFY availableChanged)
    Q_PROPERTY(double  regularPrice  READ regularPrice  NOTIFY pricesUpdated)   // $/gal
    Q_PROPERTY(double  premiumPrice  READ premiumPrice  NOTIFY pricesUpdated)
    Q_PROPERTY(double  dieselPrice   READ dieselPrice   NOTIFY pricesUpdated)
    Q_PROPERTY(QString region        READ region        NOTIFY pricesUpdated)   // "Southeast"
    Q_PROPERTY(QString lastUpdated   READ lastUpdated   NOTIFY pricesUpdated)   // "Week of May 5"
    Q_PROPERTY(QString trend         READ trend         NOTIFY pricesUpdated)   // "up"/"down"/"flat"

public:
    explicit FuelService(QObject *parent = nullptr);
    void start();

    // Called by NetworkService when LTE link changes state.
    // On first online transition, triggers an immediate price fetch if configured.
    void setNetworkOnline(bool online);

    bool    available()    const { return m_available; }
    double  regularPrice() const { return m_regular; }
    double  premiumPrice() const { return m_premium; }
    double  dieselPrice()  const { return m_diesel; }
    QString region()       const { return m_region; }
    QString lastUpdated()  const { return m_lastUpdated; }
    QString trend()        const { return m_trend; }

signals:
    void availableChanged(bool available);
    void pricesUpdated();

private slots:
    void fetchPrices();
    void onReply(QNetworkReply *reply);

private:
    void loadConfig();

    QNetworkAccessManager *m_nam;
    QTimer  m_updateTimer;
    QString m_apiKey;
    QString m_paddRegion    = QStringLiteral("R1X"); // PADD 1C = Southeast
    bool    m_networkOnline = false; // must be set true by NetworkService before any fetch fires
    bool    m_started       = false; // set after start() completes

    bool    m_available   = false;
    double  m_regular     = 0.0;
    double  m_premium     = 0.0;
    double  m_diesel      = 0.0;
    double  m_prevRegular = 0.0; // for trend
    QString m_region      = QStringLiteral("Southeast US");
    QString m_lastUpdated;
    QString m_trend       = QStringLiteral("flat");
};
