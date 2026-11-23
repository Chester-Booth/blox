#include <QtCore/QCoreApplication>
#include <QtCore/QHash>
#include <QtCore/QPointer>
#include <QtCore/QTimer>
#include <QtDBus/QDBusConnection>
#include <QtDBus/QDBusError>
#include <QtDBus/QDBusMessage>
#include <QtDBus/QDBusPendingCallWatcher>
#include <QtDBus/QDBusPendingReply>
#include <QtDBus/QDBusServiceWatcher>
#include <QtQml/QQmlExtensionPlugin>
#include <QtQml/QQmlParserStatus>
#include <QtQml/qqml.h>
#include <memory>
#include "image_cache.h"
#include "emoji_index.h"
#include "keyboard_backlight.h"
#include "privacy_monitor.h"

// One connection and subscription set serve every availability guard in the shell.
class ServiceOwnerBus : public QObject {
    Q_OBJECT
public:
    struct State {
        int references = 0;
        QString owner;
        bool ready = false;
        quint64 revision = 0;
        QPointer<QDBusPendingCallWatcher> pending;
    };

    static ServiceOwnerBus *instance()
    {
        static QPointer<ServiceOwnerBus> bus;
        if (!bus)
            bus = new ServiceOwnerBus(QCoreApplication::instance());
        return bus;
    }

    State state(const QString &name) const { return m_names.value(name); }

    void retain(const QStringList &names)
    {
        QStringList added;
        for (const auto &name : names) {
            if (++m_names[name].references == 1)
                added.append(name);
        }
        if (!m_connection) {
            connectBus();
        } else {
            m_watcher->setWatchedServices(m_names.keys());
            for (const auto &name : added)
                query(name);
        }
    }

    void release(const QStringList &names)
    {
        for (const auto &name : names) {
            auto entry = m_names.find(name);
            if (entry == m_names.end() || --entry->references > 0)
                continue;
            delete entry->pending.data();
            m_names.erase(entry);
        }
        if (m_watcher)
            m_watcher->setWatchedServices(m_names.keys());
        if (m_names.isEmpty()) {
            m_retry.stop();
            closeBus();
        }
    }

    void refresh(const QStringList &names)
    {
        if (!m_connection) {
            if (!m_names.isEmpty() && !m_retry.isActive())
                connectBus();
            return;
        }
        for (const auto &name : names)
            query(name);
    }

signals:
    void changed();

private slots:
    void transportDisconnected()
    {
        // A queued signal from a retired connection cannot clear a newer one.
        if (m_connection && !m_connection->isConnected())
            busDisconnected();
    }

private:
    void busDisconnected()
    {
        closeBus();
        for (auto &state : m_names) {
            state.owner.clear();
            state.ready = true;
        }
        emit changed();
        if (!m_names.isEmpty())
            m_retry.start();
    }

    explicit ServiceOwnerBus(QObject *parent) : QObject(parent)
    {
        m_retry.setSingleShot(true);
        m_retry.setInterval(250);
        connect(&m_retry, &QTimer::timeout, this, &ServiceOwnerBus::connectBus);
    }

    void connectBus()
    {
        if (m_names.isEmpty() || m_connection)
            return;
        m_connectionName = QStringLiteral("blox-service-owners-%1").arg(++m_epoch);
        auto connection = std::make_unique<QDBusConnection>(
            QDBusConnection::connectToBus(QDBusConnection::SystemBus, m_connectionName));
        if (!connection->isConnected()) {
            QDBusConnection::disconnectFromBus(m_connectionName);
            for (auto &state : m_names)
                state.ready = true;
            emit changed();
            if (!m_names.isEmpty()) {
                m_retry.start();
                m_retry.setInterval(qMin(5000, m_retry.interval() * 2));
            }
            return;
        }
        m_connection = std::move(connection);
        m_retry.setInterval(250);
        m_connection->connect(QString(), QStringLiteral("/org/freedesktop/DBus/Local"),
                              QStringLiteral("org.freedesktop.DBus.Local"),
                              QStringLiteral("Disconnected"), this, SLOT(transportDisconnected()));
        m_watcher = std::make_unique<QDBusServiceWatcher>();
        m_watcher->setWatchMode(QDBusServiceWatcher::WatchForOwnerChange);
        m_watcher->setConnection(*m_connection);
        const auto epoch = m_epoch;
        connect(m_watcher.get(), &QDBusServiceWatcher::serviceOwnerChanged, this,
                [this, epoch](const QString &name, const QString &, const QString &owner) {
            auto entry = m_names.find(name);
            if (epoch != m_epoch || entry == m_names.end())
                return;
            ++entry->revision; // A signal supersedes any earlier initial query.
            entry->owner = owner;
            entry->ready = true;
            emit changed();
        });
        // Install name matches before querying, so a racing owner event wins.
        m_watcher->setWatchedServices(m_names.keys());
        for (const auto &name : m_names.keys())
            query(name);
    }

    void closeBus()
    {
        ++m_epoch;
        if (auto *watcher = m_watcher.release()) {
            // A QML handler can disable the final guard during this watcher's signal.
            // Qt emits registration signals afterwards, so keep the sender alive.
            disconnect(watcher, nullptr, this, nullptr);
            watcher->setWatchedServices({});
            watcher->setConnection(QDBusConnection(QString()));
            watcher->setParent(this);
            watcher->deleteLater();
        }
        for (auto &state : m_names) {
            ++state.revision;
            delete state.pending.data();
            state.pending.clear();
        }
        if (m_connection) {
            m_connection->disconnect(QString(), QStringLiteral("/org/freedesktop/DBus/Local"),
                                     QStringLiteral("org.freedesktop.DBus.Local"),
                                     QStringLiteral("Disconnected"), this, SLOT(transportDisconnected()));
            m_connection.reset();
            QDBusConnection::disconnectFromBus(m_connectionName);
        }
    }

    void query(const QString &name)
    {
        auto entry = m_names.find(name);
        if (!m_connection || entry == m_names.end() || entry->pending)
            return;
        const auto revision = ++entry->revision;
        const auto epoch = m_epoch;
        auto message = QDBusMessage::createMethodCall(
            QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"),
            QStringLiteral("org.freedesktop.DBus"), QStringLiteral("GetNameOwner"));
        message << name;
        auto pending = new QDBusPendingCallWatcher(m_connection->asyncCall(message, 1500), this);
        entry->pending = pending;
        connect(pending, &QDBusPendingCallWatcher::finished, this,
                [this, name, epoch, revision](QDBusPendingCallWatcher *pending) {
            const QDBusPendingReply<QString> reply = *pending;
            pending->deleteLater();
            auto entry = m_names.find(name);
            if (epoch != m_epoch || entry == m_names.end() || entry->pending != pending)
                return;
            entry->pending.clear();
            if (entry->revision != revision)
                return;
            if (reply.isError() && (reply.error().type() == QDBusError::Disconnected
                                    || reply.error().type() == QDBusError::NoReply
                                    || reply.error().type() == QDBusError::Timeout)) {
                busDisconnected();
                return;
            }
            entry->owner = reply.isError() ? QString() : reply.value();
            entry->ready = true;
            emit changed();
        });
    }

    QHash<QString, State> m_names;
    std::unique_ptr<QDBusServiceWatcher> m_watcher;
    std::unique_ptr<QDBusConnection> m_connection;
    QString m_connectionName;
    QTimer m_retry;
    quint64 m_epoch = 0;
};

class NativeServiceOwner : public QObject, public QQmlParserStatus {
    Q_OBJECT
    Q_INTERFACES(QQmlParserStatus)
    Q_PROPERTY(QString service READ service WRITE setService NOTIFY serviceChanged)
    Q_PROPERTY(QString alternateService READ alternateService WRITE setAlternateService NOTIFY alternateServiceChanged)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QString owner READ owner NOTIFY ownerChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)
public:
    explicit NativeServiceOwner(QObject *parent = nullptr) : QObject(parent) {}
    ~NativeServiceOwner() override { if (m_bus) m_bus->release(m_names); }
    void classBegin() override {}
    void componentComplete() override
    {
        m_complete = true;
        m_bus = ServiceOwnerBus::instance();
        connect(m_bus, &ServiceOwnerBus::changed, this, &NativeServiceOwner::sync);
        update();
    }
    QString service() const { return m_service; }
    QString alternateService() const { return m_alternate; }
    bool enabled() const { return m_enabled; }
    QString owner() const { return m_owner; }
    bool ready() const { return m_ready; }
    bool available() const { return !m_enabled || (m_ready && !m_owner.isEmpty()); }
    void setService(const QString &value)
    {
        if (m_service == value) return;
        m_service = value;
        emit serviceChanged();
        update();
    }
    void setAlternateService(const QString &value)
    {
        if (m_alternate == value) return;
        m_alternate = value;
        emit alternateServiceChanged();
        update();
    }
    void setEnabled(bool value)
    {
        if (m_enabled == value) return;
        const bool previous = available();
        m_enabled = value;
        emit enabledChanged();
        update();
        if (previous != available()) emit availableChanged();
    }
    Q_INVOKABLE void refresh() { if (m_bus && m_enabled) m_bus->refresh(m_names); }

signals:
    void serviceChanged();
    void alternateServiceChanged();
    void enabledChanged();
    void ownerChanged();
    void readyChanged();
    void availableChanged();
    void serviceFound();

private:
    void update()
    {
        if (!m_complete) return;
        QStringList names;
        if (m_enabled && !m_service.isEmpty()) {
            names.append(m_service);
            if (!m_alternate.isEmpty() && m_alternate != m_service)
                names.append(m_alternate);
        }
        if (names != m_names) {
            m_bus->release(m_names);
            m_names = names;
            m_bus->retain(m_names);
        }
        sync();
    }
    void sync()
    {
        QString owner;
        bool ready = m_enabled && m_names.isEmpty();
        if (!m_names.isEmpty()) {
            const auto primary = m_bus->state(m_names.first());
            ready = primary.ready;
            owner = primary.owner;
            if (ready && owner.isEmpty() && m_names.size() > 1) {
                const auto alternate = m_bus->state(m_names.last());
                ready = alternate.ready;
                owner = alternate.owner;
            }
        }
        const bool previousAvailable = available();
        const bool ownerDiffers = owner != m_owner;
        const bool readyDiffers = ready != m_ready;
        m_owner = owner;
        m_ready = ready;
        if (ownerDiffers) emit ownerChanged();
        if (readyDiffers) emit readyChanged();
        if (previousAvailable != available()) emit availableChanged();
        if (ownerDiffers && m_enabled && !owner.isEmpty() && m_owner == owner)
            emit serviceFound();
    }
    QPointer<ServiceOwnerBus> m_bus;
    QString m_service, m_alternate, m_owner;
    QStringList m_names;
    bool m_enabled = true, m_ready = false, m_complete = false;
};

class BloxServicesPlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    void registerTypes(const char *uri) override
    {
        qmlRegisterType<NativeServiceOwner>(uri, 1, 0, "NativeServiceOwner");
        BloxImages::registerResolver(uri);
        BloxEmoji::registerIndex(uri);
        BloxKeyboard::registerWatcher(uri);
        BloxPrivacy::registerMonitor(uri);
    }
};

#include "service_owner.moc"
