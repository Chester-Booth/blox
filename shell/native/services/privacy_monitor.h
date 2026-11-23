#pragma once

#include <QtCore/QObject>
#include <QtCore/QVariantMap>
#include <QtQml/QQmlParserStatus>
#include <memory>

// Native PipeWire privacy monitor tracking active microphone, camera, and screen
// capture links in-process with zero subprocess polling.
class NativePrivacyMonitor : public QObject, public QQmlParserStatus {
    Q_OBJECT
    Q_INTERFACES(QQmlParserStatus)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(bool ok READ ok NOTIFY stateChanged)
    Q_PROPERTY(bool active READ active NOTIFY stateChanged)
    Q_PROPERTY(int microphoneCount READ microphoneCount NOTIFY stateChanged)
    Q_PROPERTY(int videoCount READ videoCount NOTIFY stateChanged)
    Q_PROPERTY(qreal lastUpdatedMs READ lastUpdatedMs NOTIFY stateChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY stateChanged)
    Q_PROPERTY(bool timedOut READ timedOut CONSTANT)
    Q_PROPERTY(QVariantMap json READ json NOTIFY stateChanged)
public:
    explicit NativePrivacyMonitor(QObject *parent = nullptr);
    ~NativePrivacyMonitor() override;

    void classBegin() override {}
    void componentComplete() override;

    bool enabled() const { return m_enabled; }
    void setEnabled(bool value);
    bool ok() const { return m_ok; }
    bool active() const { return m_microphoneCount > 0 || m_videoCount > 0; }
    int microphoneCount() const { return m_microphoneCount; }
    int videoCount() const { return m_videoCount; }
    qreal lastUpdatedMs() const { return m_lastUpdatedMs; }
    QString lastError() const { return m_lastError; }
    bool timedOut() const { return false; }
    QVariantMap json() const { return m_json; }

    Q_INVOKABLE void refresh();

signals:
    void enabledChanged();
    void stateChanged();
    void jsonChanged();

private:
    struct Impl;
    void start();
    void stop();
    void publishCounts(int microphones, int videos, bool ready, const QString &error);

    std::unique_ptr<Impl> m_impl;
    bool m_enabled = true;
    bool m_complete = false;
    bool m_ok = true;
    int m_microphoneCount = 0;
    int m_videoCount = 0;
    qreal m_lastUpdatedMs = 0;
    QString m_lastError;
    QVariantMap m_json;
};

namespace BloxPrivacy {
void registerMonitor(const char *uri);
}
