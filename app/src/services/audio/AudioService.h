#pragma once
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QFile>
#include <QVariantMap>
#ifdef HAVE_QT_DBUS
#include <QDBusObjectPath>
#endif

class AudioService : public QObject {
    Q_OBJECT
    Q_PROPERTY(AudioSource source    READ source    NOTIFY sourceChanged)
    Q_PROPERTY(int          volume   READ volume    NOTIFY volumeChanged)
    Q_PROPERTY(bool         muted    READ muted     NOTIFY mutedChanged)
    Q_PROPERTY(QString      trackTitle  READ trackTitle  NOTIFY metadataChanged)
    Q_PROPERTY(QString      trackArtist READ trackArtist NOTIFY metadataChanged)
    Q_PROPERTY(QString      fmStation   READ fmStation   NOTIFY fmChanged)
    Q_PROPERTY(double       fmFrequency READ fmFrequency NOTIFY fmChanged)
    Q_PROPERTY(QString      sxmChannel  READ sxmChannel  NOTIFY sxmChanged)
    Q_PROPERTY(QString      sxmName     READ sxmName     NOTIFY sxmChanged)

public:
    enum AudioSource { Bluetooth, FM, AM, SXM, AUX, None };
    Q_ENUM(AudioSource)

    explicit AudioService(QObject *parent = nullptr);
    ~AudioService() override;
    void start();

    AudioSource source()       const { return m_source; }
    int         volume()       const { return m_volume; }
    bool        muted()        const { return m_muted; }
    QString     trackTitle()   const { return m_trackTitle; }
    QString     trackArtist()  const { return m_trackArtist; }
    QString     fmStation()    const { return m_fmStation; }
    double      fmFrequency()  const { return m_fmFrequency; }
    QString     sxmChannel()   const { return m_sxmChannel; }
    QString     sxmName()      const { return m_sxmName; }

public slots:
    void setSource(AudioSource src);
    void setVolume(int vol);          // 0–100
    void setMuted(bool muted);
    void setFMFrequency(double mhz);
    void seekFM(bool forward);
    void setSXMChannel(int ch);
    void btPlay();
    void btPause();
    void btNext();
    void btPrev();
    void wakeBosse();                 // Emits bossWakeRequested → VehicleService

signals:
    void sourceChanged(AudioSource);
    void volumeChanged(int);
    void mutedChanged(bool);
    void metadataChanged();
    void fmChanged();
    void sxmChanged();
    void bossWakeRequested();         // Wired to VehicleService::wakeBosse in main.cpp
    void btConnectionChanged(bool connected);

private slots:
    void onSxmProxyData();
    void onFmProxyData();
    void onBluetoothMetadata(const QString &title, const QString &artist);
    void onBluetoothProperties(const QString &iface, const QVariantMap &props,
                                const QStringList &invalidated);

private:
    void blueZMediaCmd(const QString &method);
    void sendProxyCommand(const QString &daemon, const QString &cmd);

    // SXM/FM controlled via DENSO proxy daemons (kept from original)
    QProcess m_sxmProxy;
    QProcess m_fmProxy;

    // BlueZ D-Bus (optional — requires HAVE_QT_DBUS)
#ifdef HAVE_QT_DBUS
    class QDBusInterface *m_btMediaPlayer = nullptr;
    QString m_btPlayerPath;
#endif

    AudioSource m_source = Bluetooth;
    int    m_volume = 50;
    bool   m_muted = false;
    QString m_trackTitle;
    QString m_trackArtist;
    QString m_fmStation;
    double  m_fmFrequency = 96.1;
    QString m_sxmChannel;
    QString m_sxmName;
};
