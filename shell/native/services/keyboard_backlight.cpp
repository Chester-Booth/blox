#include "keyboard_backlight.h"
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QRegularExpression>
#include <QtDBus/QDBusMessage>
#include <QtDBus/QDBusPendingReply>
#include <QtQml/qqml.h>
#include <cerrno>
#include <functional>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

namespace {
const QString service = QStringLiteral("org.freedesktop.UPower");
const QString path = QStringLiteral("/org/freedesktop/UPower/KbdBacklight");
const QString interface = QStringLiteral("org.freedesktop.UPower.KbdBacklight");

bool readNumber(const QString &path, int &value, bool *readable = nullptr)
{
    if (readable) *readable = false;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return false;
    if (readable) *readable = true;
    const auto raw = file.read(65);
    if (raw.size() > 64) return false;
    const auto bytes = raw.trimmed();
    if (bytes.isEmpty() || bytes.size() > 10)
        return false;
    for (const auto byte : bytes)
        if (byte < '0' || byte > '9')
            return false;
    bool valid = false;
    value = bytes.toInt(&valid);
    return valid;
}

// A subscription has its own lifetime, so queued signals from a retired owner
// cannot reach a newer observation, even when the service keeps the same owner.
class BrightnessSubscription : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    std::function<void(int)> changed;
public slots:
    void brightnessChanged(int value) { changed(value); }
    void brightnessChangedWithSource(int value, const QString &) { changed(value); }
};
}

KeyboardBacklightWatcher::Options KeyboardBacklightWatcher::environmentOptions()
{
    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty()) {
        QString cache = qEnvironmentVariable("XDG_CACHE_HOME");
        if (cache.isEmpty()) cache = QDir::homePath() + QStringLiteral("/.cache");
        runtime = cache + QStringLiteral("/quickshell");
    }
    return {QStringLiteral("/sys/class/leds"), runtime,
            qEnvironmentVariable("KEYBOARD_BRIGHTNESS_DEVICE"), {}};
}

KeyboardBacklightWatcher::KeyboardBacklightWatcher(QObject *parent)
    : KeyboardBacklightWatcher(environmentOptions(), parent) {}

KeyboardBacklightWatcher::KeyboardBacklightWatcher(const Options &options, QObject *parent)
    : QObject(parent), m_options(options)
{
    // Firmware may update sysfs without either UPower brightness signal.
    m_poll.setInterval(qMax(1, m_options.pollIntervalMs));
    m_poll.setTimerType(Qt::PreciseTimer);
    m_retry.setInterval(qMax(1, m_options.retryIntervalMs));
    m_retry.setSingleShot(true);
    connect(&m_poll, &QTimer::timeout, this, &KeyboardBacklightWatcher::poll);
    connect(&m_retry, &QTimer::timeout, this, &KeyboardBacklightWatcher::start);
}

KeyboardBacklightWatcher::~KeyboardBacklightWatcher() { stop(); }

void KeyboardBacklightWatcher::componentComplete()
{
    m_complete = true;
    if (m_enabled) start();
}

void KeyboardBacklightWatcher::setEnabled(bool enabled)
{
    if (m_enabled == enabled) return;
    m_enabled = enabled;
    QPointer<KeyboardBacklightWatcher> guard(this);
    emit enabledChanged();
    if (!guard || m_enabled != enabled) return;
    if (m_complete && enabled) start();
    else {
        stop();
        setState(QStringLiteral("disabled"));
    }
}

void KeyboardBacklightWatcher::setState(const QString &status, const QString &error)
{
    if (m_status == status && m_error == error) return;
    m_status = status;
    m_error = error;
    emit stateChanged();
}

void KeyboardBacklightWatcher::clearSubscription()
{
    ++m_generation;
    delete m_pending.data();
    m_pending.clear();
    if (m_subscription) {
        if (m_bus) {
            m_bus->disconnect(m_owner, path, interface, QStringLiteral("BrightnessChanged"),
                m_subscription, SLOT(brightnessChanged(int)));
            m_bus->disconnect(m_owner, path, interface, QStringLiteral("BrightnessChangedWithSource"),
                m_subscription, SLOT(brightnessChangedWithSource(int,QString)));
        }
        m_subscription->deleteLater();
        m_subscription = nullptr;
    }
    m_owner.clear();
    m_maximum = 0;
    m_previous = -1;
}

void KeyboardBacklightWatcher::stop()
{
    m_poll.stop();
    m_retry.stop();
    clearSubscription();
    if (m_serviceWatcher) {
        // Qt emits more owner notifications after serviceOwnerChanged returns.
        disconnect(m_serviceWatcher, nullptr, this, nullptr);
        m_serviceWatcher->setWatchedServices({});
        m_serviceWatcher->setConnection(QDBusConnection(QString()));
        m_serviceWatcher->deleteLater();
        m_serviceWatcher = nullptr;
    }
    if (m_bus) {
        m_bus->disconnect(QString(), QStringLiteral("/org/freedesktop/DBus/Local"),
            QStringLiteral("org.freedesktop.DBus.Local"), QStringLiteral("Disconnected"),
            this, SLOT(transportDisconnected()));
        m_bus.reset();
        QDBusConnection::disconnectFromBus(m_busName);
    }
    if (m_lock >= 0) {
        close(m_lock);
        m_lock = -1;
    }
}

void KeyboardBacklightWatcher::unavailable(const QString &error)
{
    stop();
    // Only unavailable observers retry discovery. A healthy sysfs observer only
    // reads brightness, and a healthy UPower observer only receives signals.
    if (m_enabled) m_retry.start();
    setState(QStringLiteral("unavailable"), error);
}

void KeyboardBacklightWatcher::start()
{
    stop();
    if (!m_enabled || !m_complete) return;
    QString device = m_options.device;
    static const QRegularExpression allowed(QStringLiteral("\\A[A-Za-z0-9_.:-]+\\z"));
    if (!device.isEmpty() && (!allowed.match(device).hasMatch() || device == "." || device == "..")) {
        setState(QStringLiteral("invalid-device"), QStringLiteral("Invalid keyboard backlight device"));
        return;
    }
    if (!QDir().mkpath(m_options.runtimeDirectory)) {
        unavailable(QStringLiteral("Cannot create keyboard backlight runtime directory"));
        return;
    }
    const auto lockPath = QFile::encodeName(m_options.runtimeDirectory + QStringLiteral("/keyboard-backlight.lock"));
    m_lock = open(lockPath.constData(), O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
    if (m_lock < 0) {
        unavailable(QStringLiteral("Cannot open keyboard backlight lock"));
        return;
    }
    if (flock(m_lock, LOCK_EX | LOCK_NB) != 0) {
        const bool busy = errno == EWOULDBLOCK || errno == EAGAIN;
        stop();
        m_retry.start();
        setState(busy ? QStringLiteral("waiting-lock") : QStringLiteral("unavailable"),
                 busy ? QString() : QStringLiteral("Cannot acquire keyboard backlight lock"));
        return;
    }
    if (device.isEmpty()) {
        const auto devices = QDir(m_options.sysfsRoot).entryList(
            {QStringLiteral("*kbd_backlight")}, QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
        if (!devices.isEmpty()) device = devices.first();
    }
    const auto directory = m_options.sysfsRoot + '/' + device;
    m_brightnessFile = directory + QStringLiteral("/brightness");
    if (!device.isEmpty() && readNumber(directory + QStringLiteral("/max_brightness"), m_maximum)
            && m_maximum > 0 && readNumber(m_brightnessFile, m_previous)
            && m_previous <= m_maximum) {
        m_poll.start();
        setState(QStringLiteral("sysfs"));
        return;
    }
    // Invalid initial sysfs values use the same asynchronous fallback as missing files.
    m_maximum = 0;
    m_previous = -1;
    fallback();
}

void KeyboardBacklightWatcher::poll()
{
    int value = 0;
    bool readable = false;
    if (!readNumber(m_brightnessFile, value, &readable)) {
        if (readable) return;
        unavailable(QStringLiteral("Cannot read keyboard backlight brightness"));
        return;
    }
    acceptLevel(value);
}

void KeyboardBacklightWatcher::acceptLevel(int value)
{
    if (!m_enabled || m_maximum <= 0 || value < 0 || value > m_maximum || value == m_previous) return;
    m_previous = value;
    emit levelChanged(value, m_maximum);
}

void KeyboardBacklightWatcher::fallback()
{
    static quint64 connectionId = 0;
    m_busName = QStringLiteral("blox-keyboard-%1").arg(++connectionId);
    m_bus = std::make_unique<QDBusConnection>(m_options.busAddress.isEmpty()
        ? QDBusConnection::connectToBus(QDBusConnection::SystemBus, m_busName)
        : QDBusConnection::connectToBus(m_options.busAddress, m_busName));
    if (!m_bus->isConnected()) {
        unavailable(QStringLiteral("Cannot connect to UPower bus"));
        return;
    }
    m_bus->connect(QString(), QStringLiteral("/org/freedesktop/DBus/Local"),
        QStringLiteral("org.freedesktop.DBus.Local"), QStringLiteral("Disconnected"),
        this, SLOT(transportDisconnected()));
    m_serviceWatcher = new QDBusServiceWatcher(service, *m_bus,
        QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(m_serviceWatcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this, watcher = m_serviceWatcher](const QString &, const QString &, const QString &owner) {
        if (watcher == m_serviceWatcher) useOwner(owner);
    });
    queryOwner();
    setState(QStringLiteral("connecting"));
}

void KeyboardBacklightWatcher::transportDisconnected()
{
    if (m_bus && !m_bus->isConnected())
        unavailable(QStringLiteral("UPower bus disconnected"));
}

void KeyboardBacklightWatcher::activateService()
{
    const auto generation = m_generation;
    auto message = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"),
        QStringLiteral("/org/freedesktop/DBus"), QStringLiteral("org.freedesktop.DBus"), QStringLiteral("StartServiceByName"));
    message << service << quint32(0);
    auto pending = new QDBusPendingCallWatcher(m_bus->asyncCall(message, 1500), this);
    m_pending = pending;
    connect(pending, &QDBusPendingCallWatcher::finished, this,
            [this, generation](QDBusPendingCallWatcher *pending) {
        const QDBusPendingReply<quint32> reply = *pending;
        pending->deleteLater();
        if (generation != m_generation || m_pending != pending) return;
        m_pending.clear();
        if (reply.isError()) unavailable(QStringLiteral("UPower keyboard backlight is unavailable"));
        // Activation does not identify the owner. Resolve it before querying or
        // subscribing, unless its owner notification already advanced this generation.
        else queryOwner(false);
    });
}

void KeyboardBacklightWatcher::queryOwner(bool allowActivation)
{
    const auto generation = m_generation;
    auto message = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"),
        QStringLiteral("/org/freedesktop/DBus"), QStringLiteral("org.freedesktop.DBus"), QStringLiteral("GetNameOwner"));
    message << service;
    auto pending = new QDBusPendingCallWatcher(m_bus->asyncCall(message, 1500), this);
    m_pending = pending;
    connect(pending, &QDBusPendingCallWatcher::finished, this,
            [this, generation, allowActivation](QDBusPendingCallWatcher *pending) {
        const QDBusPendingReply<QString> reply = *pending;
        pending->deleteLater();
        if (generation != m_generation || m_pending != pending) return;
        m_pending.clear();
        if (reply.isError() && allowActivation
                && reply.error().name() == QStringLiteral("org.freedesktop.DBus.Error.NameHasNoOwner"))
            activateService();
        else if (reply.isError()) unavailable(QStringLiteral("UPower keyboard backlight is unavailable"));
        else useOwner(reply.value());
    });
}

void KeyboardBacklightWatcher::useOwner(const QString &owner)
{
    clearSubscription();
    if (owner.isEmpty()) {
        unavailable(QStringLiteral("UPower keyboard backlight is unavailable"));
        return;
    }
    m_owner = owner;
    const auto generation = m_generation;
    auto message = QDBusMessage::createMethodCall(owner, path, interface, QStringLiteral("GetMaxBrightness"));
    auto pending = new QDBusPendingCallWatcher(m_bus->asyncCall(message, 1500), this);
    m_pending = pending;
    connect(pending, &QDBusPendingCallWatcher::finished, this,
            [this, generation, owner](QDBusPendingCallWatcher *pending) {
        const QDBusPendingReply<int> reply = *pending;
        pending->deleteLater();
        if (generation != m_generation || m_pending != pending) return;
        m_pending.clear();
        if (reply.isError() || reply.value() <= 0) {
            unavailable(QStringLiteral("Invalid UPower keyboard backlight maximum"));
            return;
        }
        m_maximum = reply.value();
        auto subscription = new BrightnessSubscription(this);
        m_subscription = subscription;
        subscription->changed = [this, generation](int value) {
            if (generation == m_generation) acceptLevel(value);
        };
        const bool simple = m_bus->connect(owner, path, interface, QStringLiteral("BrightnessChanged"),
            subscription, SLOT(brightnessChanged(int)));
        const bool sourced = m_bus->connect(owner, path, interface, QStringLiteral("BrightnessChangedWithSource"),
            subscription, SLOT(brightnessChangedWithSource(int,QString)));
        if (!simple || !sourced) {
            unavailable(QStringLiteral("Cannot subscribe to UPower keyboard backlight"));
            return;
        }
        setState(QStringLiteral("upower"));
    });
}

void BloxKeyboard::registerWatcher(const char *uri)
{
    qmlRegisterType<KeyboardBacklightWatcher>(uri, 1, 0, "KeyboardBacklightWatcher");
}

#include "keyboard_backlight.moc"
