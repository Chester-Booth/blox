#include "keyboard_backlight.h"
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QProcess>
#include <QtCore/QTemporaryDir>
#include <QtDBus/QDBusMessage>
#include <QtDBus/QDBusVirtualObject>
#include <QtTest/QSignalSpy>
#include <QtTest/QTest>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
const QString service = QStringLiteral("org.freedesktop.UPower");
const QString path = QStringLiteral("/org/freedesktop/UPower/KbdBacklight");
const QString interface = QStringLiteral("org.freedesktop.UPower.KbdBacklight");
void writeFile(const QString &path, const QByteArray &value)
{
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    QCOMPARE(file.write(value), value.size());
}

class UPower : public QDBusVirtualObject {
public:
    using QDBusVirtualObject::QDBusVirtualObject;
    int maximum = 3, calls = 0;
    bool delay = false;
    QList<QDBusMessage> requests;
    QString introspect(const QString &) const override { return {}; }
    bool handleMessage(const QDBusMessage &message, const QDBusConnection &connection) override
    {
        if (message.interface() != interface || message.member() != "GetMaxBrightness") return false;
        ++calls;
        if (delay) requests.append(message);
        else connection.send(message.createReply(maximum));
        return true;
    }
    void level(const QDBusConnection &connection, int value, bool source = false)
    {
        auto message = QDBusMessage::createSignal(path, interface,
            source ? QStringLiteral("BrightnessChangedWithSource") : QStringLiteral("BrightnessChanged"));
        message << value;
        if (source) message << QStringLiteral("internal");
        QVERIFY(connection.send(message));
    }
};

// The service is launched only by this bus, with registration gated by a file.
struct ActivationBus {
    QTemporaryDir directory;
    QProcess daemon;
    ~ActivationBus()
    {
        if (daemon.state() != QProcess::NotRunning) {
            daemon.terminate();
            if (!daemon.waitForFinished(3000)) {
                daemon.kill();
                daemon.waitForFinished(3000);
            }
        }
    }
};

int activatedUPower(const QString &root)
{
    auto bus = QDBusConnection::connectToBus(qEnvironmentVariable("DBUS_STARTER_ADDRESS"), "activated-upower");
    if (!bus.isConnected()) return 1;
    UPower upower;
    writeFile(root + "/started", "1");
    bool registered = false, signalled = false;
    QTimer timer;
    QObject::connect(&timer, &QTimer::timeout, &upower, [&]() {
        if (!bus.isConnected()) {
            QCoreApplication::quit();
            return;
        }
        if (!registered && QFile::exists(root + "/release")) {
            if (!bus.registerVirtualObject(path, &upower) || !bus.registerService(service)) {
                QCoreApplication::exit(1);
                return;
            }
            registered = true;
            writeFile(root + "/registered", "1");
        }
        if (upower.calls > 0) writeFile(root + "/calls", QByteArray::number(upower.calls));
        if (registered && !signalled && QFile::exists(root + "/level")) {
            upower.level(bus, 2);
            upower.level(bus, 2, true);
            signalled = true;
        }
    });
    timer.start(10);
    QTimer::singleShot(10000, QCoreApplication::instance(), &QCoreApplication::quit);
    return QCoreApplication::exec();
}
}

class KeyboardTests : public QObject {
    Q_OBJECT
    QTemporaryDir busDirectory;
    QProcess daemon;
    QString address;
    std::unique_ptr<QTemporaryDir> directory;
    std::unique_ptr<QDBusConnection> server;
    std::unique_ptr<UPower> upower;
    KeyboardBacklightWatcher::Options options;
    int nextConnection = 0;

    QString device(const QString &name = QStringLiteral("test::kbd_backlight"),
                   const QByteArray &current = "1\n", const QByteArray &maximum = "3\n")
    {
        const auto root = options.sysfsRoot + '/' + name;
        QDir().mkpath(root);
        writeFile(root + "/brightness", current);
        writeFile(root + "/max_brightness", maximum);
        return root;
    }
    void ownService()
    {
        server = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(
            address, QStringLiteral("test-upower-%1").arg(++nextConnection)));
        QVERIFY(server->isConnected());
        upower = std::make_unique<UPower>();
        QVERIFY(server->registerVirtualObject(path, upower.get()));
        QVERIFY(server->registerService(service));
    }
    void releaseService()
    {
        if (!server) return;
        server->unregisterService(service);
        server->unregisterObject(path);
        auto name = server->name();
        server.reset();
        QDBusConnection::disconnectFromBus(name);
        upower.reset();
    }
private slots:
    void initTestCase()
    {
        QVERIFY(busDirectory.isValid());
        address = "unix:path=" + busDirectory.path() + "/bus";
        daemon.start("dbus-daemon", {"--session", "--nofork", "--address=" + address, "--print-address=1"});
        QVERIFY(daemon.waitForReadyRead(3000));
        QVERIFY(daemon.readLine().startsWith(address.toUtf8()));
    }
    void cleanupTestCase() { daemon.terminate(); QVERIFY(daemon.waitForFinished(3000)); }
    void init()
    {
        directory = std::make_unique<QTemporaryDir>();
        QVERIFY(directory->isValid());
        options = {directory->path() + "/leds", directory->path() + "/runtime", {}, address};
    }
    void cleanup() { releaseService(); directory.reset(); }

    void firmwarePollingBaselineDedupInvalidAndRemoval()
    {
        const auto root = device();
        KeyboardBacklightWatcher watcher(options);
        QSignalSpy levels(&watcher, &KeyboardBacklightWatcher::levelChanged);
        watcher.componentComplete();
        QCOMPARE(watcher.status(), "sysfs");
        QTest::qWait(230);
        QCOMPARE(levels.size(), 0);
        writeFile(root + "/brightness", "2\n");
        QTRY_COMPARE_WITH_TIMEOUT(levels.size(), 1, 500);
        QCOMPARE(levels.first(), QVariantList({2, 3}));
        QTest::qWait(240);
        QCOMPARE(levels.size(), 1);
        for (const auto invalid : {"garbage\n", "-1\n", "4\n", "2147483648\n"}) {
            writeFile(root + "/brightness", invalid);
            QTest::qWait(220);
            QCOMPARE(levels.size(), 1);
            QCOMPARE(watcher.status(), "sysfs");
        }
        writeFile(root + "/brightness", "0\n");
        QTRY_COMPARE_WITH_TIMEOUT(levels.size(), 2, 500);
        QVERIFY(QFile::remove(root + "/brightness"));
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "unavailable", 500);
        QVERIFY(!watcher.error().isEmpty());
        writeFile(root + "/brightness", "3\n");
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "sysfs", 2500);
        QCOMPARE(levels.size(), 2); // Recovery establishes a fresh quiet baseline.
    }

    void explicitSelectionAndDiscoveryOrder()
    {
        const auto first = device("a::kbd_backlight", "0\n", "2\n");
        const auto selected = device("z::kbd_backlight", "1\n", "8\n");
        options.device = "z::kbd_backlight";
        KeyboardBacklightWatcher watcher(options);
        QSignalSpy levels(&watcher, &KeyboardBacklightWatcher::levelChanged);
        watcher.componentComplete();
        writeFile(first + "/brightness", "2\n");
        QTest::qWait(220);
        QCOMPARE(levels.size(), 0);
        writeFile(selected + "/brightness", "4\n");
        QTRY_COMPARE_WITH_TIMEOUT(levels.size(), 1, 500);
        QCOMPARE(levels.first(), QVariantList({4, 8}));
        watcher.setEnabled(false);
        options.device.clear();
        KeyboardBacklightWatcher discovered(options);
        QSignalSpy found(&discovered, &KeyboardBacklightWatcher::levelChanged);
        discovered.componentComplete();
        writeFile(first + "/brightness", "1\n");
        QTRY_COMPARE_WITH_TIMEOUT(found.size(), 1, 500);
        QCOMPARE(found.first(), QVariantList({1, 2}));
    }

    void invalidExplicitDeviceDoesNotFallBack()
    {
        device();
        ownService();
        for (const auto value : {"../test", "bad device", "a/b", ".", "..", "bad\n"}) {
            options.device = value;
            KeyboardBacklightWatcher watcher(options);
            watcher.componentComplete();
            QCOMPARE(watcher.status(), "invalid-device");
            QVERIFY(!watcher.error().isEmpty());
        }
        QTest::qWait(100);
        QCOMPARE(upower->calls, 0);
    }

    void invalidInitialSysfsFallsBack_data()
    {
        QTest::addColumn<QByteArray>("current");
        QTest::addColumn<QByteArray>("maximum");
        QTest::newRow("bad-current") << QByteArray("bad\n") << QByteArray("3\n");
        QTest::newRow("negative-current") << QByteArray("-1\n") << QByteArray("3\n");
        QTest::newRow("above-maximum") << QByteArray("4\n") << QByteArray("3\n");
        QTest::newRow("zero-maximum") << QByteArray("0\n") << QByteArray("0\n");
        QTest::newRow("bad-maximum") << QByteArray("1\n") << QByteArray("bad\n");
    }
    void invalidInitialSysfsFallsBack()
    {
        QFETCH(QByteArray, current);
        QFETCH(QByteArray, maximum);
        device("test::kbd_backlight", current, maximum);
        ownService();
        KeyboardBacklightWatcher watcher(options);
        QSignalSpy levels(&watcher, &KeyboardBacklightWatcher::levelChanged);
        watcher.componentComplete();
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "upower", 1000);
        QCOMPARE(levels.size(), 0);
        QCOMPARE(upower->calls, 1);
        upower->level(*server, 2);
        QTRY_COMPARE_WITH_TIMEOUT(levels.size(), 1, 500);
        upower->level(*server, 2, true);
        upower->level(*server, -1);
        upower->level(*server, 4, true);
        QTest::qWait(100);
        QCOMPARE(levels.size(), 1);
        upower->level(*server, 0, true);
        QTRY_COMPARE_WITH_TIMEOUT(levels.size(), 2, 500);
        QCOMPARE(levels.last(), QVariantList({0, 3}));
    }

    void unavailableServiceAndInvalidMaximumRecover()
    {
        options.device = "missing";
        KeyboardBacklightWatcher watcher(options);
        QSignalSpy levels(&watcher, &KeyboardBacklightWatcher::levelChanged);
        watcher.componentComplete();
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "unavailable", 1000);
        ownService();
        upower->maximum = 0;
        QTRY_VERIFY_WITH_TIMEOUT(upower->calls > 0, 2500);
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "unavailable", 500);
        upower->maximum = 5;
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "upower", 2500);
        QCOMPARE(levels.size(), 0);
        upower->level(*server, 4, true);
        QTRY_COMPARE_WITH_TIMEOUT(levels.size(), 1, 500);
        QCOMPARE(levels.first(), QVariantList({4, 5}));
        daemon.terminate();
        QVERIFY(daemon.waitForFinished(3000));
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "unavailable", 1000);
        releaseService();
        daemon.start("dbus-daemon", {"--session", "--nofork", "--address=" + address, "--print-address=1"});
        QVERIFY(daemon.waitForReadyRead(3000));
        daemon.readLine();
        ownService();
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "upower", 2500);
        QCOMPARE(levels.size(), 1);
    }

    void dormantServiceActivation_data()
    {
        QTest::addColumn<QString>("action");
        for (const auto action : {"observe", "disable", "destroy", "restart"})
            QTest::newRow(action) << QString::fromLatin1(action);
    }
    void dormantServiceActivation()
    {
        QFETCH(QString, action);
        ActivationBus activation;
        QVERIFY(activation.directory.isValid());
        const auto root = activation.directory.path();
        QVERIFY(QDir().mkpath(root + "/services"));
        writeFile(root + "/services/org.freedesktop.UPower.service",
            QString("[D-BUS Service]\nName=org.freedesktop.UPower\nExec=\"%1\" --activated-upower \"%2\"\n")
                .arg(QCoreApplication::applicationFilePath(), root).toUtf8());
        // No standard service directories or host bus are included.
        writeFile(root + "/bus.conf", QString(
            "<busconfig><type>session</type><listen>unix:path=%1/bus</listen><auth>EXTERNAL</auth>"
            "<servicedir>%1/services</servicedir><policy context=\"default\">"
            "<allow send_destination=\"*\"/><allow receive_sender=\"*\"/><allow own=\"*\"/>"
            "</policy></busconfig>").arg(root).toUtf8());
        activation.daemon.start("dbus-daemon", {"--nofork", "--config-file=" + root + "/bus.conf", "--print-address=1"});
        QVERIFY(activation.daemon.waitForReadyRead(3000));
        options.busAddress = QString::fromUtf8(activation.daemon.readLine()).trimmed();
        QVERIFY(options.busAddress.startsWith("unix:path=" + root + "/bus"));

        auto watcher = std::make_unique<KeyboardBacklightWatcher>(options);
        QSignalSpy levels(watcher.get(), &KeyboardBacklightWatcher::levelChanged);
        watcher->componentComplete();
        QTRY_VERIFY_WITH_TIMEOUT(QFile::exists(root + "/started"), 1000);
        QCOMPARE(watcher->status(), "connecting");
        QVERIFY(!QFile::exists(root + "/registered"));
        int heartbeats = 0;
        QTimer heartbeat;
        connect(&heartbeat, &QTimer::timeout, this, [&]() { ++heartbeats; });
        heartbeat.start(10);
        QTest::qWait(60);
        QVERIFY(heartbeats > 0);

        if (action == "destroy") watcher.reset();
        else if (action != "observe") {
            watcher->setEnabled(false);
            if (action == "restart") watcher->setEnabled(true);
        }
        writeFile(root + "/release", "1");
        QTRY_VERIFY_WITH_TIMEOUT(QFile::exists(root + "/registered"), 1000);
        if (action == "observe" || action == "restart") {
            QTRY_COMPARE_WITH_TIMEOUT(watcher->status(), "upower", 1000);
            QTRY_VERIFY_WITH_TIMEOUT(QFile::exists(root + "/calls"), 500);
            QCOMPARE(levels.size(), 0);
            writeFile(root + "/level", "1");
            QTRY_COMPARE_WITH_TIMEOUT(levels.size(), 1, 500);
            QCOMPARE(levels.first(), QVariantList({2, 3}));
            QTest::qWait(100);
            QCOMPARE(levels.size(), 1);
        } else {
            QTest::qWait(100);
            QVERIFY(!QFile::exists(root + "/calls"));
            QCOMPARE(levels.size(), 0);
            if (watcher) QCOMPARE(watcher->status(), "disabled");
        }
    }

    void lockReloadAndCloexec()
    {
        device();
        auto first = std::make_unique<KeyboardBacklightWatcher>(options);
        first->componentComplete();
        QCOMPARE(first->status(), "sysfs");
        KeyboardBacklightWatcher second(options);
        second.componentComplete();
        QCOMPARE(second.status(), "waiting-lock");
        const auto lock = options.runtimeDirectory + "/keyboard-backlight.lock";
        bool found = false;
        for (const auto &entry : QDir("/proc/self/fd").entryList(QDir::AllEntries | QDir::NoDotAndDotDot)) {
            bool valid = false;
            const int fd = entry.toInt(&valid);
            if (valid && QFile::symLinkTarget("/proc/self/fd/" + entry) == lock) {
                QVERIFY(fcntl(fd, F_GETFD) & FD_CLOEXEC);
                found = true;
            }
        }
        QVERIFY(found);
        const auto binary = QFile::encodeName(QCoreApplication::applicationFilePath());
        const auto encodedLock = QFile::encodeName(lock);
        const auto child = fork();
        QVERIFY(child >= 0);
        if (child == 0) {
            execl(binary.constData(), binary.constData(), "--check-no-lock-fd", encodedLock.constData(), nullptr);
            _exit(127);
        }
        int result = 0;
        QCOMPARE(waitpid(child, &result, 0), child);
        QVERIFY(WIFEXITED(result));
        QCOMPARE(WEXITSTATUS(result), 0);
        first.reset(); // The hosting process is still alive, as during a QML reload.
        QTRY_COMPARE_WITH_TIMEOUT(second.status(), "sysfs", 2500);
        second.setEnabled(false);
        KeyboardBacklightWatcher third(options);
        third.componentComplete();
        QCOMPARE(third.status(), "sysfs");
    }

    void delayedRepliesDisableDestroyAndOwnerReplacement()
    {
        ownService();
        upower->delay = true;
        auto watcher = std::make_unique<KeyboardBacklightWatcher>(options);
        QSignalSpy levels(watcher.get(), &KeyboardBacklightWatcher::levelChanged);
        watcher->componentComplete();
        QTRY_COMPARE_WITH_TIMEOUT(upower->requests.size(), 1, 500);
        int heartbeats = 0;
        QTimer heartbeat;
        connect(&heartbeat, &QTimer::timeout, this, [&heartbeats]() { ++heartbeats; });
        heartbeat.start(10);
        QTest::qWait(60);
        QVERIFY(heartbeats > 0);
        QCOMPARE(watcher->status(), "connecting");
        watcher->setEnabled(false);
        QVERIFY(server->send(upower->requests.takeFirst().createReply(99)));
        QTest::qWait(100);
        QCOMPARE(watcher->status(), "disabled");
        QCOMPARE(levels.size(), 0);
        watcher->setEnabled(true);
        QTRY_COMPARE_WITH_TIMEOUT(upower->requests.size(), 1, 500);
        watcher.reset();
        QVERIFY(server->send(upower->requests.takeFirst().createReply(99)));
        QTest::qWait(100); // A dead QObject must never receive the completion.
        auto current = std::make_unique<KeyboardBacklightWatcher>(options);
        QSignalSpy changes(current.get(), &KeyboardBacklightWatcher::levelChanged);
        current->componentComplete();
        QTRY_COMPARE_WITH_TIMEOUT(upower->requests.size(), 1, 500);
        const auto oldReply = upower->requests.takeFirst().createReply(99);
        // Keep the displaced connection alive to send its late reply and signal.
        auto oldServer = std::move(server);
        oldServer->unregisterService(service);
        oldServer->unregisterObject(path);
        ownService();
        upower->maximum = 7;
        QVERIFY(oldServer->send(oldReply));
        QTRY_COMPARE_WITH_TIMEOUT(current->status(), "upower", 3000);
        auto stale = QDBusMessage::createSignal(path, interface, "BrightnessChanged");
        stale << 6;
        QVERIFY(oldServer->send(stale));
        upower->level(*server, 3);
        QTRY_COMPARE_WITH_TIMEOUT(changes.size(), 1, 500);
        QCOMPARE(changes.first(), QVariantList({3, 7}));
        QTest::qWait(100);
        QCOMPARE(changes.size(), 1);
        const auto oldName = oldServer->name();
        oldServer.reset();
        QDBusConnection::disconnectFromBus(oldName);
    }

    void signalHandlerCanDisableAndRestart()
    {
        ownService();
        KeyboardBacklightWatcher watcher(options);
        watcher.componentComplete();
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "upower", 1000);
        connect(&watcher, &KeyboardBacklightWatcher::levelChanged, &watcher,
                [&watcher]() { watcher.setEnabled(false); });
        upower->level(*server, 1);
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "disabled", 500);
        watcher.setEnabled(true);
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "upower", 1000);
        upower->level(*server, 1, true);
        QTRY_COMPARE_WITH_TIMEOUT(watcher.status(), "disabled", 500);
    }

    void pollingDoesNotCreateChildren()
    {
        device();
        const auto children = QStringLiteral("/proc/self/task/%1/children").arg(getpid());
        QFile file(children);
        QVERIFY(file.open(QIODevice::ReadOnly));
        const auto before = file.readAll();
        KeyboardBacklightWatcher watcher(options);
        watcher.componentComplete();
        for (int sample = 0; sample < 60; ++sample) {
            QTest::qWait(20);
            file.seek(0);
            QCOMPARE(file.readAll(), before);
        }
    }
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    if (argc == 3 && QByteArray(argv[1]) == "--activated-upower")
        return activatedUPower(QString::fromLocal8Bit(argv[2]));
    if (argc == 3 && QByteArray(argv[1]) == "--check-no-lock-fd") {
        for (const auto &entry : QDir("/proc/self/fd").entryList(QDir::AllEntries | QDir::NoDotAndDotDot))
            if (QFile::symLinkTarget("/proc/self/fd/" + entry) == QString::fromLocal8Bit(argv[2])) return 1;
        return 0;
    }
    if (argc == 3 && QByteArray(argv[1]) == "--hold") {
        const QString root = QString::fromLocal8Bit(argv[2]);
        KeyboardBacklightWatcher watcher({root + "/leds", root + "/runtime", {}, "unix:path=" + root + "/no-bus"});
        watcher.componentComplete();
        if (watcher.status() != "sysfs") return 1;
        write(1, "ready\n", 6);
        return app.exec();
    }
    KeyboardTests tests;
    return QTest::qExec(&tests, argc, argv);
}

#include "keyboard_backlight_test.moc"
