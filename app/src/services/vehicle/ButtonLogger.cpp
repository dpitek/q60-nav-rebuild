// ButtonLogger.cpp — Hardware button / CAN diagnostic logger
#include "ButtonLogger.h"
#include <QDir>
#include <QFileInfo>
#include <QDebug>
#include <QCoreApplication>

ButtonLogger::ButtonLogger()
{
}

ButtonLogger::~ButtonLogger()
{
    if (m_file.isOpen() && !m_sessionEnded)
        signalSessionEnd(QStringLiteral("destructor"));
    m_file.close();
}

// ── open ──────────────────────────────────────────────────────────────────────
// Rotate existing logs, then open a fresh log for this session.
void ButtonLogger::open(const QString &logPath)
{
    m_logPath = logPath;

    // Ensure the log directory exists
    QDir dir = QFileInfo(logPath).dir();
    if (!dir.exists())
        dir.mkpath(QStringLiteral("."));

    // Rotate: .log → .1.log → .2.log → .3.log (discard .3.log if present)
    rotateLog(logPath, 3);

    m_file.setFileName(logPath);
    if (!m_file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
        qWarning() << "[ButtonLogger] Cannot open log file:" << logPath
                   << m_file.errorString();
        return;
    }
    m_stream.setDevice(&m_file);
    m_stream.setEncoding(QStringConverter::Utf8);

    writeEntry(QStringLiteral("SESSION_START version=1 pid=") +
               QString::number(QCoreApplication::applicationPid()));
    qDebug() << "[ButtonLogger] Logging to" << logPath;
}

// ── logAction ─────────────────────────────────────────────────────────────────
void ButtonLogger::logAction(const QString &bus, canid_t canId,
                              const struct can_frame &f, const QString &action)
{
    if (!m_file.isOpen()) return;
    writeEntry(QStringLiteral("BUS=%1 CAN=0x%2 RAW=[%3] ACTION=%4")
               .arg(bus)
               .arg(canId, 3, 16, QLatin1Char('0'))
               .arg(formatBytes(f))
               .arg(action));
}

// ── logUnknown ────────────────────────────────────────────────────────────────
void ButtonLogger::logUnknown(const QString &bus, canid_t canId,
                               const struct can_frame &f)
{
    if (!m_file.isOpen()) return;
    writeEntry(QStringLiteral("BUS=%1 CAN=0x%2 RAW=[%3] ACTION=UNKNOWN")
               .arg(bus)
               .arg(canId, 3, 16, QLatin1Char('0'))
               .arg(formatBytes(f)));
}

// ── logDiscovery ──────────────────────────────────────────────────────────────
// Logs all frames on discovery buses (can2). Used to build the CAN dictionary.
void ButtonLogger::logDiscovery(const QString &bus, canid_t canId,
                                 const struct can_frame &f)
{
    if (!m_file.isOpen()) return;
    writeEntry(QStringLiteral("BUS=%1 CAN=0x%2 RAW=[%3] ACTION=DISCOVERY")
               .arg(bus)
               .arg(canId, 3, 16, QLatin1Char('0'))
               .arg(formatBytes(f)));
}

// ── signalSessionEnd ──────────────────────────────────────────────────────────
void ButtonLogger::signalSessionEnd(const QString &reason)
{
    if (!m_file.isOpen() || m_sessionEnded) return;
    writeEntry(QStringLiteral("SESSION_END reason=") + reason);
    m_stream.flush();
    m_file.flush();
    m_sessionEnded = true;
    qDebug() << "[ButtonLogger] Session ended:" << reason;
}

// ── private helpers ───────────────────────────────────────────────────────────

void ButtonLogger::writeEntry(const QString &line)
{
    QString ts = QDateTime::currentDateTimeUtc()
                     .toString(QStringLiteral("yyyy-MM-ddTHH:mm:ss.zzzZ"));
    m_stream << '[' << ts << "] " << line << '\n';
    m_stream.flush();  // flush each line — we want data even if app crashes
}

QString ButtonLogger::formatBytes(const struct can_frame &f)
{
    QString result;
    for (int i = 0; i < f.can_dlc; ++i) {
        if (i > 0) result += ' ';
        result += QStringLiteral("%1").arg(f.data[i], 2, 16,
                                           QLatin1Char('0')).toUpper();
    }
    return result;
}

// Rotation: move logPath → logPath.1, logPath.1 → logPath.2, ...
// Files beyond maxRotations are deleted.
void ButtonLogger::rotateLog(const QString &logPath, int maxRotations)
{
    // Delete the oldest rotation first
    QString oldest = logPath + QStringLiteral(".") + QString::number(maxRotations);
    if (QFile::exists(oldest))
        QFile::remove(oldest);

    // Shift: .2 → .3, .1 → .2
    for (int i = maxRotations - 1; i >= 1; --i) {
        QString from = logPath + QStringLiteral(".") + QString::number(i);
        QString to   = logPath + QStringLiteral(".") + QString::number(i + 1);
        if (QFile::exists(from))
            QFile::rename(from, to);
    }

    // Current log → .1
    if (QFile::exists(logPath))
        QFile::rename(logPath, logPath + QStringLiteral(".1"));
}
