#include <QGuiApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QFontDatabase>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickGraphicsDevice>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickRenderTarget>
#include <QQuickWindow>
#include <QThread>
#include <QVulkanInstance>
#include <rhi/qrhi.h>
#include <rhi/qrhi_platform.h>
#include <private/qbasicvulkanplatforminstance_p.h>
#include <private/qvulkaninstance_p.h>
#include <memory>
#include <unistd.h>

// Reused from the isolated phase 5 probe. Qt 6.12 private API, no surface or presentation.
class HeadlessVulkanInstance final : public QBasicPlatformVulkanInstance {
public:
    explicit HeadlessVulkanInstance(QVulkanInstance *instance) : instance(instance) {
        loadVulkanLibrary(QStringLiteral("vulkan"), 1);
    }
    void createOrAdoptInstance() override { initInstance(instance, {}); }
    bool supportsPresent(VkPhysicalDevice, uint32_t, QWindow *) override { return false; }
private:
    QVulkanInstance *instance;
};

static QStringList warnings;
static void message(QtMsgType type, const QMessageLogContext &, const QString &text) {
    fprintf(stderr, "%s\n", qPrintable(text));
    if (type == QtWarningMsg || type == QtCriticalMsg || type == QtFatalMsg) warnings.append(text);
}
static QJsonObject readJson(const QString &path) {
    QFile input(path);
    if (!input.open(QIODevice::ReadOnly)) qFatal("Cannot read fixture configuration");
    return QJsonDocument::fromJson(input.readAll()).object();
}
static bool samePixels(const QImage &a, const QImage &b) {
    return a.convertToFormat(QImage::Format_RGBA8888) == b.convertToFormat(QImage::Format_RGBA8888);
}

int main(int argc, char **argv) {
    alarm(12);
    QGuiApplication app(argc, argv);
    if (argc != 2) return 1;
    qInstallMessageHandler(message);
    const bool gpu = QString::fromUtf8(argv[1]) == "vulkan";
    const QString backend = gpu ? "vulkan" : "software";
    const auto config = readJson("/work/config.json");
    const QSize size(640, 360);
    QFontDatabase::addApplicationFont("/usr/share/fonts/TTF/GoogleSans-Regular.ttf");
    QFontDatabase::addApplicationFont("/usr/share/fonts/TTF/MartianMonoNerdFontMono-Regular.ttf");
    QQuickWindow::setSceneGraphBackend(gpu ? "rhi" : "software");
    std::unique_ptr<QVulkanInstance> instance;
    std::unique_ptr<QRhi> rhi;
    if (gpu) {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
        instance = std::make_unique<QVulkanInstance>();
        QVulkanInstancePrivate::get(instance.get())->platformInst.reset(new HeadlessVulkanInstance(instance.get()));
        instance->setApiVersion(QVersionNumber(1, 1));
        instance->setExtensions(QRhiVulkanInitParams::preferredInstanceExtensions());
        if (!instance->create()) return 2;
        QRhiVulkanInitParams params; params.inst = instance.get();
        rhi.reset(QRhi::create(QRhi::Vulkan, &params));
        if (!rhi) return 3;
    }
    QQuickRenderControl control;
    QQuickWindow window(&control);
    window.setGeometry(0, 0, size.width(), size.height());
    window.setColor(Qt::transparent);
    QImage softwareImage(size, QImage::Format_ARGB32_Premultiplied);
    softwareImage.fill(Qt::transparent);
    std::unique_ptr<QRhiTexture> texture;
    std::unique_ptr<QRhiRenderBuffer> depth;
    std::unique_ptr<QRhiTextureRenderTarget> target;
    std::unique_ptr<QRhiRenderPassDescriptor> pass;
    if (gpu) {
        window.setVulkanInstance(instance.get());
        window.setGraphicsDevice(QQuickGraphicsDevice::fromRhi(rhi.get()));
        if (!control.initialize()) return 4;
        texture.reset(rhi->newTexture(QRhiTexture::RGBA8, size, 1, QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource));
        depth.reset(rhi->newRenderBuffer(QRhiRenderBuffer::DepthStencil, size));
        if (!texture->create() || !depth->create()) return 5;
        QRhiTextureRenderTargetDescription description{QRhiColorAttachment(texture.get())};
        description.setDepthStencilBuffer(depth.get());
        target.reset(rhi->newTextureRenderTarget(description));
        pass.reset(target->newCompatibleRenderPassDescriptor());
        target->setRenderPassDescriptor(pass.get());
        if (!target->create()) return 6;
        window.setRenderTarget(QQuickRenderTarget::fromRhiRenderTarget(target.get()));
    } else {
        window.setRenderTarget(QQuickRenderTarget::fromPaintDevice(&softwareImage));
    }
    QQmlEngine engine;
    engine.addImportPath("/widgets/qml");
    engine.addImportPath("/work/native-qml");
    QQmlComponent component(&engine, QUrl("file:///fixture/WidgetGpu.qml"));
    std::unique_ptr<QObject> root(component.create());
    auto item = qobject_cast<QQuickItem *>(root.get());
    if (!item) { qCritical() << component.errors(); return 7; }
    item->setParentItem(window.contentItem());
    root->setProperty("themeData", config["theme"].toObject().toVariantMap());
    int frameCount = 0;
    auto draw = [&](qint64 terminalRevision = -1) {
        QCoreApplication::processEvents();
        control.polishItems();
        bool contentFrame = root->property("phase").toString() == "visible";
        if (terminalRevision >= 0) {
            auto terminal = root->findChild<QObject *>("terminalCanvas");
            const auto stats = terminal ? terminal->property("diagnostics").toMap() : QVariantMap();
            contentFrame = contentFrame && stats.value("hasImage").toBool()
                && stats.value("revision").toLongLong() == terminalRevision;
        }
        if (gpu) control.beginFrame();
        control.sync();
        control.render();
        if (gpu) control.endFrame();
        frameCount++;
        if (window.isVisible() || window.handle()) qFatal("Fixture created a native window");
        return contentFrame;
    };
    auto capture = [&]() -> QImage {
        if (!gpu) return softwareImage.copy();
        QRhiReadbackResult readback;
        bool complete = false;
        readback.completed = [&]() { complete = true; };
        control.beginFrame();
        auto updates = rhi->nextResourceUpdateBatch();
        updates->readBackTexture(QRhiReadbackDescription(texture.get()), &readback);
        control.commandBuffer()->resourceUpdate(updates);
        control.endFrame();
        rhi->finish();
        if (!complete || readback.data.size() != size.width() * size.height() * 4) qFatal("Incomplete GPU readback");
        QImage image(reinterpret_cast<const uchar *>(readback.data.constData()), size.width(), size.height(), QImage::Format_RGBA8888_Premultiplied);
        return rhi->isYUpInFramebuffer() ? image.flipped(Qt::Vertical) : image.copy();
    };
    QJsonArray rows;
    auto record = [&](const QString &name, qint64 terminalRevision = -1) {
        // The first draw whose pre-sync state is visible is the first content draw.
        // An already-visible retained update must also prepare its requested
        // revision. It intentionally keeps its old image whilst the worker runs.
        bool ready = false;
        QElapsedTimer deadline; deadline.start();
        while (deadline.elapsed() < 1500) {
            if (draw(terminalRevision)) { ready = true; break; }
            QThread::msleep(3);
        }
        if (!ready) { qCritical() << name << root->property("phase") << root->property("error"); return false; }
        const auto first = capture();
        draw(); draw();
        const auto stable = capture();
        first.save("/work/" + backend + "-" + name + "-first.png");
        stable.save("/work/" + backend + "-" + name + ".png");
        auto host = root->findChild<QObject *>("fixtureHost");
        rows.append(QJsonObject{{"name", name}, {"firstEqualsStable", samePixels(first, stable)},
            {"phase", root->property("phase").toString()}, {"generation", root->property("generation").toInt()},
            {"cellHeight", root->property("cellHeight").toDouble()},
            {"contentInset", root->property("contentInset").toDouble()},
            {"geometry", QJsonArray{host->property("x").toDouble(), host->property("y").toDouble(), host->property("width").toDouble(), host->property("height").toDouble()}}});
        return true;
    };
    for (const auto &entry : config["cases"].toArray()) {
        const auto test = entry.toObject();
        root->setProperty("observation", test["value"].toObject().toVariantMap());
        root->setProperty("revision", 0);
        root->setProperty("caseData", test.toVariantMap());
        if (!record(test["name"].toString())) return 8;
        if (test["name"] == "terminal-painted") {
            // The retained rows include a clear whose delta was coalesced away.
            root->setProperty("observation", config["terminalDropped"].toObject().toVariantMap());
            QMetaObject::invokeMethod(root.get(), "publish");
            if (!record("terminal-dropped-clear", root->property("revision").toLongLong())) return 9;
            QMetaObject::invokeMethod(root.get(), "hideHost");
            if (root->property("phase").toString() != "hidden") return 10;
            draw();
            root->setProperty("observation", config["terminalFresh"].toObject().toVariantMap());
            QMetaObject::invokeMethod(root.get(), "revealHost");
            if (!record("terminal-fresh-reveal")) return 11;
        }
    }
    QJsonObject result{{"backend", backend}, {"nativeWindow", window.handle() != nullptr}, {"visible", window.isVisible()},
        {"frames", frameCount}, {"cases", rows}, {"warnings", QJsonArray::fromStringList(warnings)}};
    if (gpu) {
        const auto driver = rhi->driverInfo();
        result["deviceName"] = QString::fromUtf8(driver.deviceName);
        result["deviceType"] = int(driver.deviceType);
        result["rhiBackend"] = QString::fromLatin1(rhi->backendName());
    }
    QFile output("/work/" + backend + "-result.json");
    if (!output.open(QIODevice::WriteOnly)) return 12;
    output.write(QJsonDocument(result).toJson()); output.close();
    root.reset();
    window.setRenderTarget(QQuickRenderTarget());
    control.invalidate();
    return 0;
}
