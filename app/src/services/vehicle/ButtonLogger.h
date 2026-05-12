#pragma once
// ButtonLogger — diagnostic log of every hardware button press observed on CAN.
//
// Design:
//   - Logs all parsed button actions AND raw unknown frames from all three buses.
//   - One rotating log file per session: /var/log/q60nav-buttons.log
//   - On startup: rotate existing file → .1 → .2 → .3 (oldest .3 is discarded).
//   - Log is closed/flushed when signalSessionEnd() is called (ignition off).
//   - Only the last 3 sessions are kept on disk to avoid filling /var/log.
//   - Log format (one event per line):
//       [ISO_UTC] BUS=<name> CAN=0x<id> RAW=[xx xx xx...] ACTION=<string>
//
// Purpose: troubleshoot unresponsive hardware buttons post-deployment.
//   With 3-rotation history, you can review what was pressed in the last 3 ignition
//   cycles even if the issue is intermittent.

#include <QFile>
#include <QTextStream>
#include <QDateTime>
#include <QString>
#include <linux/can.h>

class ButtonLogger
{
public:
    ButtonLogger();
    ~ButtonLogger();

    // Call once at startup — rotates old logs then opens current log file.
    void open(const QString &logPath = QStringLiteral("/var/log/q60nav-buttons.log"));

    // Log a parsed button action (button press with known meaning).
    void logAction(const QString &bus, canid_t canId,
                   const struct can_frame &f, const QString &action);

    // Log a raw frame from a known-monitored bus where the action is not yet decoded.
    // Used for all unknown frames on AV-CAN and can2 to capture data for analysis.
    void logUnknown(const QString &bus, canid_t canId, const struct can_frame &f);

    // Log a raw frame on any bus — used by can2 discovery mode.
    void logDiscovery(const QString &bus, canid_t canId, const struct can_frame &f);

    // Mark session end with a reason string (e.g., "ignition_off", "app_exit").
    void signalSessionEnd(const QString &reason = QStringLiteral("app_exit"));

    bool isOpen() const { return m_file.isOpen(); }

private:
    void writeEntry(const QString &line);
    static QString formatBytes(const struct can_frame &f);
    static void rotateLog(const QString &logPath, int maxRotations = 3);

    QFile       m_file;
    QTextStream m_stream;
    QString     m_logPath;
    bool        m_sessionEnded = false;
};
