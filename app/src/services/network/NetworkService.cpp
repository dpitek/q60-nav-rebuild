#include "NetworkService.h"

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QStandardPaths>
#include <QProcess>
#include <QRegularExpression>

Q_LOGGING_CATEGORY(lcNetwork, "q60nav.network")

static constexpr int POLL_INTERVAL_MS = 5000;

NetworkService::NetworkService(QObject *parent)
    : QObject(parent)
{
    connect(&m_mmcli, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &NetworkService::onMmcliFinished);
}

void NetworkService::start()
{
    // Load config — prefer hardcoded device path, fall back to AppConfigLocation
    const QString primaryPath = QStringLiteral("/opt/nav/config/config.json");
    QString configPath = primaryPath;
    if (!QFile::exists(configPath)) {
        const QString fallback = QStandardPaths::locate(
            QStandardPaths::AppConfigLocation, QStringLiteral("config.json"));
        if (!fallback.isEmpty()) {
            configPath = fallback;
            qCInfo(lcNetwork) << "Config not found at" << primaryPath
                              << "— using fallback:" << configPath;
        } else {
            qCWarning(lcNetwork) << "Config not found at" << primaryPath
                                 << "and no AppConfigLocation fallback — using defaults";
        }
    }

    QFile cfg(configPath);
    if (cfg.open(QIODevice::ReadOnly)) {
        const QJsonDocument doc = QJsonDocument::fromJson(cfg.readAll());
        const QJsonObject modem = doc.object().value(QStringLiteral("modem")).toObject();

        // TCU mode: Continental BL28NA003 (2021-2022 Q60) — self-managing LTE router
        m_tcuMode = modem.value(QStringLiteral("tcu_mode")).toBool(false);

        const QString iface = m_tcuMode
            ? modem.value(QStringLiteral("tcu_interface")).toString(QStringLiteral("usb0"))
            : modem.value(QStringLiteral("interface")).toString();

        if (!iface.isEmpty())
            m_interface = iface;

        qCInfo(lcNetwork) << (m_tcuMode ? "TCU mode" : "Modem mode")
                          << "— interface:" << m_interface;
    } else {
        qCWarning(lcNetwork) << "Could not open config:" << configPath << "— using interface:" << m_interface;
    }

    connect(&m_pollTimer, &QTimer::timeout, this, &NetworkService::pollInterface);
    m_pollTimer.setInterval(POLL_INTERVAL_MS);

    // Boot grace — defer the first poll for 15 seconds on cold boot so we
    // don't fire downstream `online` signals (Weather, Fuel) while the rest
    // of the system is still initializing. Air-gap first boots stay offline
    // for the whole session anyway; this just smooths the warm-boot case
    // where the phone hotspot might be reachable instantly.
    QTimer::singleShot(15000, this, [this]() {
        m_pollTimer.start();
        pollInterface();
    });
    qCInfo(lcNetwork) << "Network monitor scheduled (15s grace period)";
}

void NetworkService::pollInterface()
{
    // ── Interface state ───────────────────────────────────────────────────
    QString state = readSysFile(
        QStringLiteral("/sys/class/net/%1/operstate").arg(m_interface)).trimmed();

    // Non-TCU fallback: ppp0 (PPP over LTE on some ModemManager setups)
    if (!m_tcuMode && state != QLatin1String("up")) {
        const QString pppState = readSysFile(
            QStringLiteral("/sys/class/net/ppp0/operstate")).trimmed();
        if (pppState == QLatin1String("up")) {
            state = pppState;
            qCInfo(lcNetwork) << "Primary interface down, ppp0 is up";
        }
    }

    const bool nowOnline = (state == QLatin1String("up"));

    if (nowOnline != m_online) {
        m_online = nowOnline;
        if (m_online) {
            m_ipAddress = readIpAddress();
            if (m_tcuMode) {
                // TCU manages LTE internally — we can't read signal over RNDIS.
                // BL28NA003 is 4G-only; assume good signal.
                // TODO: read RSSI from CAN bus once CAN IDs are reverse-engineered.
                m_signalStrength = 4;
                m_networkType    = QStringLiteral("4G");
                m_carrier        = QStringLiteral("InfinitiConnect");
                emit signalChanged();
            }
        } else {
            m_ipAddress.clear();
            m_signalStrength = 0;
            m_networkType    = QStringLiteral("none");
            m_carrier.clear();
            emit signalChanged();
        }
        qCInfo(lcNetwork) << "Online state changed:" << m_online
                          << "IP:" << m_ipAddress
                          << (m_tcuMode ? "[TCU]" : "[modem]");
        emit onlineChanged(m_online);
    }

    // ── mmcli signal polling — only in modem mode ─────────────────────────
    if (!m_tcuMode && m_online && m_mmcli.state() == QProcess::NotRunning) {
        m_mmcli.start(QStringLiteral("mmcli"),
                      QStringList() << QStringLiteral("-m") << QStringLiteral("0")
                                    << QStringLiteral("--output-keyvalue"));
    }
}

void NetworkService::onMmcliFinished(int exitCode, QProcess::ExitStatus status)
{
    if (exitCode != 0 || status != QProcess::NormalExit) {
        qCWarning(lcNetwork) << "mmcli exited with code" << exitCode;
        return;
    }

    const QString output = QString::fromUtf8(m_mmcli.readAllStandardOutput());

    int    signalQuality = -1;
    QString accessTech;
    QString carrier;

    // Parse key-value lines: "modem.generic.signal-quality.value : 75"
    static const QRegularExpression reSignal(
        QStringLiteral(R"(signal-quality\.value\s*:\s*(\d+))"));
    static const QRegularExpression reTech(
        QStringLiteral(R"(access-technologies\s*:\s*(\S+))"));
    static const QRegularExpression reCarrier(
        QStringLiteral(R"(operator-name\s*:\s*(.+))"));

    auto m = reSignal.match(output);
    if (m.hasMatch())
        signalQuality = m.captured(1).toInt();

    m = reTech.match(output);
    if (m.hasMatch())
        accessTech = m.captured(1).toLower();

    m = reCarrier.match(output);
    if (m.hasMatch())
        carrier = m.captured(1).trimmed();

    // Map 0-100 signal quality to 0-5 bars
    int bars = 0;
    if (signalQuality >= 0) {
        if      (signalQuality >= 80) bars = 5;
        else if (signalQuality >= 60) bars = 4;
        else if (signalQuality >= 40) bars = 3;
        else if (signalQuality >= 20) bars = 2;
        else if (signalQuality >  0)  bars = 1;
    }

    // Map access technology string to display label
    QString netType = QStringLiteral("none");
    if (accessTech.contains(QLatin1String("lte")))
        netType = QStringLiteral("LTE");
    else if (accessTech.contains(QLatin1String("umts")) ||
             accessTech.contains(QLatin1String("hspa")) ||
             accessTech.contains(QLatin1String("3g")))
        netType = QStringLiteral("3G");
    else if (accessTech.contains(QLatin1String("edge")) ||
             accessTech.contains(QLatin1String("gsm")) ||
             accessTech.contains(QLatin1String("2g")))
        netType = QStringLiteral("2G");

    bool changed = (bars != m_signalStrength) ||
                   (netType != m_networkType)  ||
                   (carrier  != m_carrier);

    m_signalStrength = bars;
    m_networkType    = netType;
    m_carrier        = carrier;

    if (changed) {
        qCInfo(lcNetwork) << "Signal:" << bars << "bars,"
                          << netType << "| Carrier:" << carrier;
        emit signalChanged();
    }
}

QString NetworkService::readSysFile(const QString &path) const
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qCWarning(lcNetwork) << "Cannot read sysfs file:" << path;
        return {};
    }
    return QString::fromUtf8(f.readAll()).trimmed();
}

QString NetworkService::readIpAddress() const
{
    // Run: ip -4 addr show <interface>
    // Parse a line like: "    inet 100.64.0.1/30 brd ..."
    QProcess proc;
    proc.start(QStringLiteral("ip"),
               QStringList() << QStringLiteral("-4") << QStringLiteral("addr")
                             << QStringLiteral("show") << m_interface);
    if (!proc.waitForFinished(2000)) {
        qCWarning(lcNetwork) << "ip addr show timed out";
        return {};
    }

    const QString output = QString::fromUtf8(proc.readAllStandardOutput());
    static const QRegularExpression reInet(QStringLiteral(R"(\binet\s+(\d+\.\d+\.\d+\.\d+))"));
    const auto m = reInet.match(output);
    return m.hasMatch() ? m.captured(1) : QString{};
}
