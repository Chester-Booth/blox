#pragma once

#include <QtCore/QObject>
#include <QtCore/QPointer>
#include <QtCore/QTimer>
#include <QtDBus/QDBusConnection>
#include <QtDBus/QDBusPendingCallWatcher>
#include <QtDBus/QDBusServiceWatcher>
#include <QtQml/QQmlParserStatus>
#include <memory>

class KeyboardBacklightWatcher : public QObject, public QQmlParserStatus {
    Q_OBJECT
    Q_INTERFACES(QQmlParserStatus)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(QString error READ error NOTIFY stateChanged)
public:
    // Native tests supply private files and a private bus. QML uses the real paths.
    struct Options {
        QString sysfsRoot, runtimeDirectory, device, busAddress;
    };
    explicit KeyboardBacklightWatcher(QObject *parent = nullptr);
    KeyboardBacklightWatcher(const Options &options, QObject *parent = nullptr);
    ~KeyboardBacklightWatcher() override;
    void classBegin() override {}
    void componentComplete() override;
    bool enabled() const { return m_enabled; }
    void setEnabled(bool enabled);
    QString status() const { return m_status; }
    QString error() const { return m_error; }

signals:
    void enabledChanged();
    void stateChanged();
    void levelChanged(int value, int maximum);

private slots:
    void transportDisconnected();

private:
    void start();
    void stop();
    void poll();
    void fallback();
    void activateService();
    void queryOwner(bool allowActivation = true);
    void useOwner(const QString &owner);
    void clearSubscription();
    void unavailable(const QString &error);
    void setState(const QString &status, const QString &error = {});
    void acceptLevel(int value);
    static Options environmentOptions();
    Options m_options;
    QTimer m_poll, m_retry;
    QString m_brightnessFile, m_status = QStringLiteral("disabled"), m_error, m_busName, m_owner;
    std::unique_ptr<QDBusConnection> m_bus;
    QDBusServiceWatcher *m_serviceWatcher = nullptr;
    QPointer<QDBusPendingCallWatcher> m_pending;
    QObject *m_subscription = nullptr;
    quint64 m_generation = 0;
    int m_lock = -1, m_maximum = 0, m_previous = -1;
    bool m_enabled = true, m_complete = false;
};

namespace BloxKeyboard {
void registerWatcher(const char *uri);
}
