#include "terminal.h"
#include <QQmlExtensionPlugin>
#include <QQmlEngine>
#include <QCoreApplication>
#include <qqml.h>

class TerminalPlugin final : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    void initializeEngine(QQmlEngine *engine, const char *) override {
        QObject::connect(engine, &QObject::destroyed, qApp, [] { BloxTerminal::finishUnusedWorker(); });
    }
    void registerTypes(const char *uri) override {
        qmlRegisterType<BloxTerminal::Decoder>(uri, 1, 0, "TerminalDecoder");
        qmlRegisterType<BloxTerminal::Surface>(uri, 1, 0, "TerminalSurface");
    }
};
#include "plugin.moc"
