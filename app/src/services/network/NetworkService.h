#pragma once
// NetworkService — LTE/WWAN connectivity monitor
//
// Two modes — selected by config.json "modem.tcu_mode":
//
//   tcu_mode: false  (default / 2017-2020 Q60 + external modem)
//     Polls /sys/class/net/{interface}/operstate.
//     Runs mmcli to read signal quality, access technology, carrier name.
//     Interface priority: config interface (wwan0) → ppp0.
//
//   tcu_mode: true  (2021-2022 Q60 built-in Continental BL28NA003)
//     TCU self-manages the LTE connection; exposes USB RNDIS to the DCU.
//     Linux sees it as "usb0" (or configured tcu_interface, default "usb0").
//     No ModemManager, no APN config needed — TCU handles all of that.
//     Signal strength: fixed 4 bars / "4G" (RNDIS gives no signal data).
//     CAN-based RSSI is a future enhancement via VehicleService.
//
// Config: /opt/nav/config/config.json → "modem" section
#include <QObject>
#include <QString>
#include <QTimer>
#include <QProcess>

class NetworkService : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool    online         READ online         NOTIFY onlineChanged)
    Q_PROPERTY(int     signalStrength READ signalStrength NOTIFY signalChanged) // 0–5 bars
    Q_PROPERTY(QString networkType   READ networkType    NOTIFY signalChanged) // "LTE","3G","none"
    Q_PROPERTY(QString ipAddress     READ ipAddress      NOTIFY onlineChanged)
    Q_PROPERTY(QString carrier       READ carrier        NOTIFY signalChanged)

public:
    explicit NetworkService(QObject *parent = nullptr);
    void start();

    bool    online()         const { return m_online; }
    int     signalStrength() const { return m_signalStrength; }
    QString networkType()    const { return m_networkType; }
    QString ipAddress()      const { return m_ipAddress; }
    QString carrier()        const { return m_carrier; }

signals:
    void onlineChanged(bool online);
    void signalChanged();

private slots:
    void pollInterface();
    void onMmcliFinished(int exitCode, QProcess::ExitStatus);

private:
    QString readSysFile(const QString &path) const;
    QString readIpAddress() const;

    QTimer   m_pollTimer;
    QProcess m_mmcli;
    QString  m_interface    = QStringLiteral("wwan0"); // primary interface (overridden by config)
    bool     m_tcuMode      = false;                   // true = Q60 built-in TCU (no mmcli)

    bool    m_online          = false;
    int     m_signalStrength  = 0;
    QString m_networkType     = QStringLiteral("none");
    QString m_ipAddress;
    QString m_carrier;
};
