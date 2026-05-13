#include "FuelService.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QNetworkRequest>
#include <QStandardPaths>
#include <QDate>
#include <QUrl>
#include <QUrlQuery>

Q_LOGGING_CATEGORY(lcFuel, "q60nav.fuel")

// Update every 6 hours — EIA data is weekly so hammering is pointless
static constexpr int UPDATE_INTERVAL_MS = 6 * 60 * 60 * 1000;

// Hardcoded fallback prices (Southeast US, recent average)
static constexpr double FALLBACK_REGULAR = 3.45;
static constexpr double FALLBACK_PREMIUM = 3.95;
static constexpr double FALLBACK_DIESEL  = 3.85;

// EIA product codes
static const QString PRODUCT_REGULAR = QStringLiteral("EPM0");
static const QString PRODUCT_PREMIUM = QStringLiteral("EPM2");
static const QString PRODUCT_DIESEL  = QStringLiteral("EPD2D");

FuelService::FuelService(QObject *parent)
    : QObject(parent)
    , m_nam(new QNetworkAccessManager(this))
{
    connect(m_nam, &QNetworkAccessManager::finished,
            this, &FuelService::onReply);
}

// ---------------------------------------------------------------------------
// loadConfig
// ---------------------------------------------------------------------------
void FuelService::loadConfig()
{
    const QString primaryPath = QStringLiteral("/opt/nav/config/config.json");
    QString configPath = primaryPath;
    if (!QFile::exists(configPath)) {
        const QString fallback = QStandardPaths::locate(
            QStandardPaths::AppConfigLocation, QStringLiteral("config.json"));
        if (!fallback.isEmpty()) {
            configPath = fallback;
        } else {
            qCWarning(lcFuel) << "Config not found at" << primaryPath << "— no fallback";
            return;
        }
    }

    QFile cfg(configPath);
    if (!cfg.open(QIODevice::ReadOnly)) {
        qCWarning(lcFuel) << "Cannot open config:" << configPath;
        return;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(cfg.readAll());
    const QJsonObject eia   = doc.object().value(QStringLiteral("eia")).toObject();

    const QString key = eia.value(QStringLiteral("api_key")).toString();
    if (!key.isEmpty())
        m_apiKey = key;

    const QString region = eia.value(QStringLiteral("padd_region")).toString();
    if (!region.isEmpty())
        m_paddRegion = region;

    qCInfo(lcFuel) << "Config loaded — PADD region:" << m_paddRegion
                   << "| apiKey present:" << !m_apiKey.isEmpty();
}

// ---------------------------------------------------------------------------
// start
// ---------------------------------------------------------------------------
void FuelService::start()
{
    loadConfig();

    if (m_apiKey.isEmpty()) {
        qCWarning(lcFuel) << "No EIA API key — using hardcoded fallback prices";
        m_regular     = FALLBACK_REGULAR;
        m_premium     = FALLBACK_PREMIUM;
        m_diesel      = FALLBACK_DIESEL;
        m_lastUpdated = QStringLiteral("Recent avg");
        m_trend       = QStringLiteral("flat");
        m_available   = true;
        emit availableChanged(true);
        emit pricesUpdated();
        return;
    }

    connect(&m_updateTimer, &QTimer::timeout, this, &FuelService::fetchPrices);
    m_updateTimer.setInterval(UPDATE_INTERVAL_MS);
    m_updateTimer.start();

    fetchPrices();
}

// ---------------------------------------------------------------------------
// fetchPrices — fetch regular, premium, and diesel in three parallel requests.
// Each reply carries the product code in the URL's facets[product][] param;
// onReply() reads it back to know which price to update.
// ---------------------------------------------------------------------------
void FuelService::fetchPrices()
{
    if (m_apiKey.isEmpty())
        return;

    const QStringList products = { PRODUCT_REGULAR, PRODUCT_PREMIUM, PRODUCT_DIESEL };

    for (const QString &product : products) {
        QUrl url(QStringLiteral("https://api.eia.gov/v2/petroleum/pri/gnd/data/"));
        QUrlQuery q;
        q.addQueryItem(QStringLiteral("api_key"),              m_apiKey);
        q.addQueryItem(QStringLiteral("frequency"),            QStringLiteral("weekly"));
        q.addQueryItem(QStringLiteral("data[0]"),              QStringLiteral("value"));
        q.addQueryItem(QStringLiteral("facets[product][]"),    product);
        q.addQueryItem(QStringLiteral("facets[duoarea][]"),    m_paddRegion);
        q.addQueryItem(QStringLiteral("sort[0][column]"),      QStringLiteral("period"));
        q.addQueryItem(QStringLiteral("sort[0][direction]"),   QStringLiteral("desc"));
        q.addQueryItem(QStringLiteral("length"),               QStringLiteral("1"));
        url.setQuery(q);

        QNetworkRequest req(url);
        // Tag each request with its product code so onReply() can route it
        req.setAttribute(QNetworkRequest::User, product);
        m_nam->get(req);
    }

    qCInfo(lcFuel) << "Fetching EIA prices for region" << m_paddRegion;
}

// ---------------------------------------------------------------------------
// onReply
// ---------------------------------------------------------------------------
void FuelService::onReply(QNetworkReply *reply)
{
    reply->deleteLater();

    if (reply->error() != QNetworkReply::NoError) {
        qCWarning(lcFuel) << "EIA request failed:" << reply->errorString();
        return;
    }

    const QString product = reply->request()
                                .attribute(QNetworkRequest::User)
                                .toString();

    const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
    if (doc.isNull()) {
        qCWarning(lcFuel) << "EIA response: invalid JSON for product" << product;
        return;
    }

    // EIA v2 response shape: { "response": { "data": [ { "period": "...", "value": 3.45 } ] } }
    const QJsonObject response = doc.object().value(QStringLiteral("response")).toObject();
    const QJsonArray  data     = response.value(QStringLiteral("data")).toArray();

    if (data.isEmpty()) {
        qCWarning(lcFuel) << "EIA: empty data array for product" << product;
        return;
    }

    const QJsonObject entry = data.first().toObject();
    const double price  = entry.value(QStringLiteral("value")).toDouble();
    const QString period = entry.value(QStringLiteral("period")).toString(); // "YYYY-MM-DD"

    if (product == PRODUCT_REGULAR) {
        m_prevRegular = m_regular;
        m_regular     = price;

        // Update trend based on regular price direction
        if (m_prevRegular > 0.0) {
            const double delta = m_regular - m_prevRegular;
            if      (delta >  0.01) m_trend = QStringLiteral("up");
            else if (delta < -0.01) m_trend = QStringLiteral("down");
            else                    m_trend = QStringLiteral("flat");
        }

        // Format period "YYYY-MM-DD" → "Week of MMM D"
        const QDate d = QDate::fromString(period, QStringLiteral("yyyy-MM-dd"));
        m_lastUpdated = d.isValid()
            ? QStringLiteral("Week of ") + d.toString(QStringLiteral("MMM d"))
            : period;

    } else if (product == PRODUCT_PREMIUM) {
        m_premium = price;

    } else if (product == PRODUCT_DIESEL) {
        m_diesel = price;
    }

    if (!m_available) {
        m_available = true;
        emit availableChanged(true);
    }

    qCInfo(lcFuel) << "Price updated — product:" << product
                   << "| price: $" << price
                   << "| period:" << period;
    emit pricesUpdated();
}
