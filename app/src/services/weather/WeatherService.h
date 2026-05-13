#pragma once
// WeatherService — OpenWeatherMap current + 5-day forecast
// API: https://api.openweathermap.org/data/2.5/weather  (current)
//      https://api.openweathermap.org/data/2.5/forecast (5-day/3hr)
// Config: /opt/nav/config/config.json → "openweathermap" → { "api_key": "...", "update_interval_minutes": 15 }
// Coordinates: read from NavigationService position or fallback lat/lon from config.
// Units: imperial (°F, mph)
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QTimer>
#include <QNetworkAccessManager>
#include <QNetworkReply>

class WeatherService : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool         available    READ available    NOTIFY availableChanged)
    Q_PROPERTY(double       temperature  READ temperature  NOTIFY weatherUpdated)
    Q_PROPERTY(double       feelsLike    READ feelsLike    NOTIFY weatherUpdated)
    Q_PROPERTY(QString      condition    READ condition    NOTIFY weatherUpdated)
    Q_PROPERTY(QString      iconCode     READ iconCode     NOTIFY weatherUpdated)  // OWM icon e.g. "01d"
    Q_PROPERTY(int          humidity     READ humidity     NOTIFY weatherUpdated)
    Q_PROPERTY(double       windSpeed    READ windSpeed    NOTIFY weatherUpdated)
    Q_PROPERTY(QString      city         READ city         NOTIFY weatherUpdated)
    Q_PROPERTY(QString      lastUpdated  READ lastUpdated  NOTIFY weatherUpdated)
    Q_PROPERTY(QVariantList forecast     READ forecast     NOTIFY forecastUpdated) // list of day maps

public:
    explicit WeatherService(QObject *parent = nullptr);
    void start();

    bool         available()   const { return m_available; }
    double       temperature() const { return m_temperature; }
    double       feelsLike()   const { return m_feelsLike; }
    QString      condition()   const { return m_condition; }
    QString      iconCode()    const { return m_iconCode; }
    int          humidity()    const { return m_humidity; }
    double       windSpeed()   const { return m_windSpeed; }
    QString      city()        const { return m_city; }
    QString      lastUpdated() const { return m_lastUpdated; }
    QVariantList forecast()    const { return m_forecast; }

    // Called by main when GPS position updates — triggers a refresh if location changed significantly
    Q_INVOKABLE void updatePosition(double lat, double lon);

signals:
    void availableChanged(bool available);
    void weatherUpdated();
    void forecastUpdated();

private slots:
    void fetchWeather();
    void onCurrentWeatherReply(QNetworkReply *reply);
    void onForecastReply(QNetworkReply *reply);

private:
    void loadConfig();
    QString iconUrl(const QString &code) const;

    QNetworkAccessManager *m_nam;
    QTimer  m_updateTimer;
    QString m_apiKey;
    double  m_lat = 35.789, m_lon = -78.781;   // Cary NC default
    int     m_intervalMin = 15;

    bool    m_available   = false;
    double  m_temperature = 0.0;
    double  m_feelsLike   = 0.0;
    QString m_condition;
    QString m_iconCode;
    int     m_humidity    = 0;
    double  m_windSpeed   = 0.0;
    QString m_city;
    QString m_lastUpdated;
    QVariantList m_forecast; // Each entry: { day, hi, lo, icon, condition }
};
