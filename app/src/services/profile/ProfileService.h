#pragma once
// ProfileService.h — Driver profile management singleton
// Handles CAN-based key detection, profile load/save, and welcome sequence.
//
// Key slot detection: CAN_KEY_DETECT (0x35B) — UNVERIFIED.
// Profile data is persisted to QStandardPaths::AppDataLocation / profiles.json
// All disk I/O is async via QSaveFile to prevent blocking the CAN thread.
//
// Instantiated in main.cpp, exposed to QML as "ProfileService" context property.

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QString>
#include <QTimer>
#include <QUuid>

class VehicleService;

class ProfileService : public QObject
{
    Q_OBJECT

    // Active profile state
    Q_PROPERTY(QString activeProfileName  READ activeProfileName  NOTIFY profileChanged)
    Q_PROPERTY(QString activeProfileAvatar READ activeProfileAvatar NOTIFY profileChanged)
    Q_PROPERTY(QString activeAccentColor  READ activeAccentColor  NOTIFY profileChanged)
    Q_PROPERTY(int     activeProfileIndex READ activeProfileIndex NOTIFY profileChanged)
    Q_PROPERTY(bool    profileLoaded      READ profileLoaded      NOTIFY profileChanged)
    Q_PROPERTY(bool    guestMode          READ guestMode          NOTIFY profileChanged)

    // Full profile list (for UI carousel)
    Q_PROPERTY(QVariantList profiles      READ profiles           NOTIFY profilesChanged)

    // Welcome overlay state
    Q_PROPERTY(bool    welcomeVisible     READ welcomeVisible     NOTIFY welcomeVisibilityChanged)
    Q_PROPERTY(bool    noProfileMode      READ noProfileMode      NOTIFY welcomeVisibilityChanged)

    // Last session summary (shown in welcome chip)
    Q_PROPERTY(QString lastSessionSummary READ lastSessionSummary NOTIFY profileChanged)

public:
    explicit ProfileService(QObject *parent = nullptr);
    ~ProfileService() override = default;

    void start(VehicleService *vehicleSvc);

    // Property accessors
    QString       activeProfileName()  const { return m_activeProfileName; }
    QString       activeProfileAvatar() const { return m_activeProfileAvatar; }
    QString       activeAccentColor()  const { return m_activeAccentColor; }
    int           activeProfileIndex() const { return m_activeProfileIndex; }
    bool          profileLoaded()      const { return m_profileLoaded; }
    bool          guestMode()          const { return m_guestMode; }
    QVariantList  profiles()           const { return m_profiles; }
    bool          welcomeVisible()     const { return m_welcomeVisible; }
    bool          noProfileMode()      const { return m_noProfileMode; }
    QString       lastSessionSummary() const { return m_lastSessionSummary; }

    // Active profile data accessors (for C++ consumers)
    Q_INVOKABLE QVariantMap activeProfile() const;
    Q_INVOKABLE QVariantMap profileAt(int index) const;

public slots:
    // Profile lifecycle
    Q_INVOKABLE void createProfile(const QString &name,
                                   const QString &avatar    = "🏎️",
                                   const QString &accent    = "#0A84FF",
                                   const QVariantList &keySlots = QVariantList{});
    Q_INVOKABLE void deleteProfile(int index);
    Q_INVOKABLE void saveCurrentProfile();
    Q_INVOKABLE void loadProfile(int index);
    Q_INVOKABLE void switchProfile(int index);

    // Profile editing (update a single field in the active profile)
    Q_INVOKABLE void setProfileField(const QString &section, const QString &key, const QVariant &value);

    // Import / export
    Q_INVOKABLE void exportProfile(int index, const QString &path);
    Q_INVOKABLE void importProfile(const QString &path);

    // Welcome overlay control
    Q_INVOKABLE void dismissWelcome();

    // PIN
    Q_INVOKABLE bool verifyPin(int profileIndex, const QString &pin);

    // Guest mode
    Q_INVOKABLE void activateGuestMode();

    // Session end — called on ignitionOff to persist trip stats
    void onIgnitionOff();

signals:
    void profileChanged();
    void profilesChanged();
    void welcomeVisibilityChanged();

    // Emitted when a CAN key slot is detected and a matching profile is found
    // NOTE: renamed from profileLoaded to avoid collision with bool profileLoaded Q_PROPERTY
    void keySlotProfileMatched(int keySlot);
    // Emitted when a CAN key slot is detected but no matching profile exists
    void noProfileFound(int keySlot);
    // Emitted after profile switch completes
    void profileSwitched();
    // Emitted when export/import completes
    void exportComplete(bool success, const QString &path);
    void importComplete(bool success, const QString &name);

private slots:
    void onKeySlotDetected(int slot);
    void autoSaveTimerFired();

private:
    // Persistence
    QString profilesFilePath() const;
    bool    loadFromDisk();
    bool    saveToDisk();
    QJsonObject buildDefaultProfile(const QString &name,
                                    const QString &avatar,
                                    const QString &accent,
                                    const QVariantList &keySlots) const;
    QVariantMap jsonToVariant(const QJsonObject &obj) const;
    QJsonObject variantToJson(const QVariantMap &map) const;

    // Internal load
    void applyProfile(int index);
    void updateLastSessionSummary();

    // Data
    QJsonArray   m_profileData;        // raw JSON array on disk
    QVariantList m_profiles;           // QML-visible list (same data, QVariantMap per entry)

    // Active state
    int     m_activeProfileIndex = -1;
    QString m_activeProfileName;
    QString m_activeProfileAvatar;
    QString m_activeAccentColor  = "#0A84FF";
    bool    m_profileLoaded      = false;
    bool    m_guestMode          = false;
    QString m_lastSessionSummary;

    // Welcome overlay
    bool m_welcomeVisible = false;
    bool m_noProfileMode  = false;

    // Auto-save timer (5s debounce after setProfileField)
    QTimer *m_autoSaveTimer = nullptr;

    // Trip accumulation for session summary
    float m_sessionStartOdo  = 0.0f;
    float m_sessionStartMPG  = 0.0f;
    qint64 m_sessionStartMs  = 0;

    VehicleService *m_vehicleSvc = nullptr;
};
