#include "WeatherService.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QNetworkRequest>
#include <QStandardPaths>
#include <QTime>
#include <QUrl>
#include <QUrlQuery>
#include <cmath>

Q_LOGGING_CATEGORY(lcWeather, "q60nav.weather")

WeatherService::WeatherService(QObject *parent)
    : QObject(parent)
    , m_nam(new QNetworkAccessManager(this))
{
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
void WeatherService::loadConfig()
{
    const QString primaryPath = QStringLiteral("/opt/nav/config/config.json");
    QString configPath = primaryPath;
    if (!QFile::exists(configPath)) {
        const QString fallback = QStandardPaths::locate(
            QStandardPaths::AppConfigLocation, QStringLiteral("config.json"));
        if (!fallback.isEmpty()) {
            configPath = fallback;
        } else {
            qCWarning(lcWeather) << "Config not found at" << primaryPath << "— no fallback";
            return;
        }
    }

    QFile cfg(configPath);
    if (!cfg.open(QIODevice::ReadOnly)) {
        qCWarning(lcWeather) << "Cannot open config:" << configPath;
        return;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(cfg.readAll());
    const QJsonObject owm  = doc.object().value(QStringLiteral("openweathermap")).toObject();

    const QString key = owm.value(QStringLiteral("api_key")).toString();
    if (!key.isEmpty())
        m_apiKey = key;

    const int interval = owm.value(QStringLiteral("update_interval_minutes")).toInt(0);
    if (interval > 0)
        m_intervalMin = interval;

    // Optional: fallback lat/lon from config
    const double lat = owm.value(QStringLiteral("default_lat")).toDouble(0.0);
    const double lon = owm.value(QStringLiteral("default_lon")).toDouble(0.0);
    if (lat != 0.0 && lon != 0.0) {
        m_lat = lat;
        m_lon = lon;
    }

    qCInfo(lcWeather) << "Config loaded — interval:" << m_intervalMin
                      << "min, apiKey present:" << !m_apiKey.isEmpty();
}

// ---------------------------------------------------------------------------
// start — load config and arm the timer. Does NOT fetch immediately.
// Fetches only begin once NetworkService calls setNetworkOnline(true).
// ---------------------------------------------------------------------------
void WeatherService::start()
{
    loadConfig();
    m_started = true;

    if (m_apiKey.isEmpty()) {
        qCWarning(lcWeather) << "No OWM API key configured — weather unavailable";
        m_available = false;
        emit availableChanged(false);
        return;
    }

    connect(&m_updateTimer, &QTimer::timeout, this, &WeatherService::fetchWeather);
    m_updateTimer.setInterval(m_intervalMin * 60 * 1000);
    m_updateTimer.start();

    // Don't call fetchWeather() here — wait for setNetworkOnline(true)
    qCInfo(lcWeather) << "Started — waiting for network before first fetch";
}

// ---------------------------------------------------------------------------
// setNetworkOnline — called by NetworkService when LTE link changes state.
// Triggers an immediate fetch on the first online transition; subsequent
// fetches are driven by m_updateTimer.
// ---------------------------------------------------------------------------
void WeatherService::setNetworkOnline(bool online)
{
    if (m_networkOnline == online)
        return;

    m_networkOnline = online;
    qCInfo(lcWeather) << "Network online:" << online;

    if (online && m_started && !m_apiKey.isEmpty())
        fetchWeather(); // first fetch now that we have connectivity
}

// ---------------------------------------------------------------------------
// fetchWeather
// ---------------------------------------------------------------------------
void WeatherService::fetchWeather()
{
    // Air-gap gate — drop silently if offline or unconfigured
    if (!m_networkOnline) {
        qCInfo(lcWeather) << "fetchWeather: offline — skipping";
        return;
    }
    if (m_apiKey.isEmpty())
        return;

    // --- Current weather ---
    QUrl currentUrl(QStringLiteral("https://api.openweathermap.org/data/2.5/weather"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("lat"),   QString::number(m_lat, 'f', 6));
    q.addQueryItem(QStringLiteral("lon"),   QString::number(m_lon, 'f', 6));
    q.addQueryItem(QStringLiteral("appid"), m_apiKey);
    q.addQueryItem(QStringLiteral("units"), QStringLiteral("imperial"));
    currentUrl.setQuery(q);

    QNetworkRequest currentReq(currentUrl);
    currentReq.setTransferTimeout(5000);   // 5s; fail-fast prevents hot socket pile-up
    QNetworkReply *currentReply = m_nam->get(currentReq);
    connect(currentReply, &QNetworkReply::finished, this, [this, currentReply]() {
        onCurrentWeatherReply(currentReply);
    });

    // --- 5-day / 3-hr forecast ---
    QUrl forecastUrl(QStringLiteral("https://api.openweathermap.org/data/2.5/forecast"));
    QUrlQuery fq;
    fq.addQueryItem(QStringLiteral("lat"),   QString::number(m_lat, 'f', 6));
    fq.addQueryItem(QStringLiteral("lon"),   QString::number(m_lon, 'f', 6));
    fq.addQueryItem(QStringLiteral("appid"), m_apiKey);
    fq.addQueryItem(QStringLiteral("units"), QStringLiteral("imperial"));
    fq.addQueryItem(QStringLiteral("cnt"),   QStringLiteral("32"));
    forecastUrl.setQuery(fq);

    QNetworkRequest forecastReq(forecastUrl);
    forecastReq.setTransferTimeout(5000);
    QNetworkReply *forecastReply = m_nam->get(forecastReq);
    connect(forecastReply, &QNetworkReply::finished, this, [this, forecastReply]() {
        onForecastReply(forecastReply);
    });

    qCInfo(lcWeather) << "Fetching weather for" << m_lat << m_lon;
}

// ---------------------------------------------------------------------------
// onCurrentWeatherReply
// ---------------------------------------------------------------------------
void WeatherService::onCurrentWeatherReply(QNetworkReply *reply)
{
    reply->deleteLater();

    if (reply->error() != QNetworkReply::NoError) {
        qCWarning(lcWeather) << "Current weather request failed:" << reply->errorString();
        return;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
    if (doc.isNull()) {
        qCWarning(lcWeather) << "Current weather: invalid JSON";
        return;
    }

    const QJsonObject root = doc.object();
    const QJsonObject main    = root.value(QStringLiteral("main")).toObject();
    const QJsonObject wind    = root.value(QStringLiteral("wind")).toObject();
    const QJsonArray  weather = root.value(QStringLiteral("weather")).toArray();

    m_temperature = main.value(QStringLiteral("temp")).toDouble();
    m_feelsLike   = main.value(QStringLiteral("feels_like")).toDouble();
    m_humidity    = main.value(QStringLiteral("humidity")).toInt();
    m_windSpeed   = wind.value(QStringLiteral("speed")).toDouble();
    m_city        = root.value(QStringLiteral("name")).toString();

    if (!weather.isEmpty()) {
        const QJsonObject w = weather.first().toObject();
        m_condition = w.value(QStringLiteral("description")).toString();
        m_iconCode  = w.value(QStringLiteral("icon")).toString();
    }

    m_lastUpdated = QTime::currentTime().toString(QStringLiteral("h:mm AP"));

    if (!m_available) {
        m_available = true;
        emit availableChanged(true);
    }

    qCInfo(lcWeather) << "Current weather:" << m_temperature << "°F,"
                      << m_condition << "| City:" << m_city;
    emit weatherUpdated();
}

// ---------------------------------------------------------------------------
// onForecastReply
// ---------------------------------------------------------------------------
void WeatherService::onForecastReply(QNetworkReply *reply)
{
    reply->deleteLater();

    if (reply->error() != QNetworkReply::NoError) {
        qCWarning(lcWeather) << "Forecast request failed:" << reply->errorString();
        return;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
    if (doc.isNull()) {
        qCWarning(lcWeather) << "Forecast: invalid JSON";
        return;
    }

    // OWM forecast list: entries every 3 hours, keyed by dt_txt "YYYY-MM-DD HH:MM:SS"
    const QJsonArray list = doc.object().value(QStringLiteral("list")).toArray();

    // Accumulate per-day hi/lo and first-of-day icon/condition
    struct DayData {
        QString shortDay;
        double  hi   = -999.0;
        double  lo   =  999.0;
        QString icon;
        QString condition;
        bool    filled = false;
    };

    QMap<QString, DayData> dayMap;   // key = "YYYY-MM-DD"
    QStringList            dayOrder; // to preserve insertion order

    for (const QJsonValue &val : list) {
        const QJsonObject entry  = val.toObject();
        const QString dtTxt = entry.value(QStringLiteral("dt_txt")).toString();
        if (dtTxt.isEmpty())
            continue;

        const QString dateKey = dtTxt.left(10); // "YYYY-MM-DD"
        const QJsonObject main    = entry.value(QStringLiteral("main")).toObject();
        const QJsonArray  weather = entry.value(QStringLiteral("weather")).toArray();

        const double tempMax = main.value(QStringLiteral("temp_max")).toDouble();
        const double tempMin = main.value(QStringLiteral("temp_min")).toDouble();

        if (!dayMap.contains(dateKey)) {
            dayOrder.append(dateKey);
            DayData d;
            // Short day name from date string
            const QDate date = QDate::fromString(dateKey, QStringLiteral("yyyy-MM-dd"));
            d.shortDay = date.isValid()
                ? date.toString(QStringLiteral("ddd"))
                : dateKey.right(5);
            dayMap[dateKey] = d;
        }

        DayData &d = dayMap[dateKey];
        if (tempMax > d.hi) d.hi = tempMax;
        if (tempMin < d.lo) d.lo = tempMin;

        // Use first entry of the day for icon/condition
        if (!d.filled && !weather.isEmpty()) {
            const QJsonObject w = weather.first().toObject();
            d.icon      = w.value(QStringLiteral("icon")).toString();
            d.condition = w.value(QStringLiteral("description")).toString();
            d.filled    = true;
        }
    }

    m_forecast.clear();
    int count = 0;
    for (const QString &key : dayOrder) {
        if (count >= 5) break;
        const DayData &d = dayMap[key];
        QVariantMap entry;
        entry[QStringLiteral("day")]       = d.shortDay;
        entry[QStringLiteral("hi")]        = d.hi > -999.0 ? d.hi : 0.0;
        entry[QStringLiteral("lo")]        = d.lo <  999.0 ? d.lo : 0.0;
        entry[QStringLiteral("icon")]      = d.icon;
        entry[QStringLiteral("condition")] = d.condition;
        m_forecast.append(entry);
        ++count;
    }

    qCInfo(lcWeather) << "Forecast updated:" << m_forecast.size() << "days";
    emit forecastUpdated();
}

// ---------------------------------------------------------------------------
// updatePosition
// ---------------------------------------------------------------------------
void WeatherService::updatePosition(double lat, double lon)
{
    constexpr double THRESHOLD = 0.1; // ~7 miles — trigger refresh
    if (std::abs(lat - m_lat) > THRESHOLD || std::abs(lon - m_lon) > THRESHOLD) {
        qCInfo(lcWeather) << "Position moved significantly — refreshing weather";
        m_lat = lat;
        m_lon = lon;
        fetchWeather(); // gated by m_networkOnline inside fetchWeather()
    }
}
