#include "image_cache.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QHash>
#include <QJsonDocument>
#include <QPointer>
#include <QProcess>
#include <QQueue>
#include <QTimer>
#include <QQmlParserStatus>
#include <QtQml/qqml.h>
#include <dlfcn.h>
#include <functional>
#include <memory>

namespace BloxImages {
namespace {
QString helperPath;

// All consumers share one decoder process and one pending job for each request.
class ImageCacheManager : public QObject {
    struct Waiter { QPointer<QObject> owner; std::function<void(Result)> deliver; };
    struct Job { Request request; QList<Waiter> waiters; };
public:
    static ImageCacheManager *instance() {
        static QPointer<ImageCacheManager> value;
        if (!value) value = new ImageCacheManager(QCoreApplication::instance());
        return value;
    }
    explicit ImageCacheManager(QObject *parent) : QObject(parent) {
        m_timeout.setSingleShot(true);
        connect(&m_timeout, &QTimer::timeout, this, [this] { m_error = "Image preparation timed out"; m_process.kill(); });
        connect(&m_process, &QProcess::readyReadStandardOutput, this, [this] {
            m_output += m_process.readAllStandardOutput();
            if (m_output.size() > 16384) { m_error = "Image helper response exceeded its limit"; m_process.kill(); }
        });
        connect(&m_process, &QProcess::readyReadStandardError, this, [this] { m_process.readAllStandardError(); });
        connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart) finish("Image helper is unavailable");
        });
        connect(&m_process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
            finish(code == 0 && status == QProcess::NormalExit ? QString() : "Image preparation failed");
        });
    }
    void cancel(QObject *owner) {
        for (auto it = m_jobs.begin(); it != m_jobs.end();) {
            it.value()->waiters.removeIf([owner](const Waiter &waiter) { return !waiter.owner || waiter.owner == owner; });
            if (it.key() != m_current && it.value()->waiters.isEmpty()) it = m_jobs.erase(it);
            else ++it;
        }
        m_queue.removeIf([this](const QString &key) { return !m_jobs.contains(key); });
    }
    void submit(const Request &request, QObject *owner, std::function<void(Result)> deliver) {
        cancel(owner);
        const QString jobKey = request.key + ":" + request.sourceId;
        auto job = m_jobs.value(jobKey);
        if (!job) {
            if (m_jobs.size() >= 64) { deliver({"error", "Image preparation queue is full", {}, {}}); return; }
            job = std::make_shared<Job>();
            job->request = request;
            m_jobs.insert(jobKey, job);
            m_queue.enqueue(jobKey);
        }
        job->waiters.append({owner, std::move(deliver)});
        QTimer::singleShot(0, this, [this] { startNext(); });
    }
private:
    void startNext() {
        if (!m_current.isEmpty()) return;
        while (!m_queue.isEmpty()) {
            const QString key = m_queue.dequeue();
            const auto job = m_jobs.value(key);
            if (!job) continue;
            job->waiters.removeIf([](const Waiter &waiter) { return !waiter.owner; });
            if (job->waiters.isEmpty()) { m_jobs.remove(key); continue; }
            m_current = key;
            m_error.clear();
            m_output.clear();
            const auto cached = lookup(job->request);
            if (cached.status != "missing") { finish(cached.error); return; }
            m_process.start(helperPath, {QString::fromUtf8(QJsonDocument(serialise(job->request)).toJson(QJsonDocument::Compact))});
            m_timeout.start(35000);
            return;
        }
    }
    void finish(QString error) {
        if (m_current.isEmpty()) return;
        m_timeout.stop();
        const auto job = m_jobs.take(m_current);
        m_current.clear();
        Result result{"error", m_error.isEmpty() ? error : m_error, {}, {}};
        if (result.error.isEmpty()) {
            result = lookup(job->request);
            if (result.status != "ready") result = {"error", "Prepared image was not published or its source changed", {}, {}};
        } else {
            const auto reply = QJsonDocument::fromJson(m_output).object();
            if (!reply["error"].toString().isEmpty()) result.error = reply["error"].toString().left(500);
        }
        for (const auto &waiter : job->waiters) if (waiter.owner) waiter.deliver(result);
        QTimer::singleShot(0, this, [this] { startNext(); });
    }
    QHash<QString, std::shared_ptr<Job>> m_jobs;
    QQueue<QString> m_queue;
    QString m_current, m_error;
    QByteArray m_output;
    QProcess m_process;
    QTimer m_timeout;
};

class ImageCacheResolver : public QObject, public QQmlParserStatus {
    Q_OBJECT
    Q_INTERFACES(QQmlParserStatus)
    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceId READ sourceId WRITE setSourceId NOTIFY sourceIdChanged)
    Q_PROPERTY(int pixelWidth READ pixelWidth WRITE setPixelWidth NOTIFY pixelWidthChanged)
    Q_PROPERTY(int pixelHeight READ pixelHeight WRITE setPixelHeight NOTIFY pixelHeightChanged)
    Q_PROPERTY(QString fit READ fit WRITE setFit NOTIFY fitChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(QUrl readySource READ readySource NOTIFY readySourceChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
public:
    ~ImageCacheResolver() override { if (!QCoreApplication::closingDown()) ImageCacheManager::instance()->cancel(this); }
    void classBegin() override {}
    void componentComplete() override { m_complete = true; schedule(); }
    QUrl source() const { return m_source; }
    QString sourceId() const { return m_sourceId; }
    int pixelWidth() const { return m_width; }
    int pixelHeight() const { return m_height; }
    QString fit() const { return m_fit; }
    bool active() const { return m_active; }
    QUrl readySource() const { return m_readySource; }
    QString status() const { return m_status; }
    QString error() const { return m_error; }
    void setSource(const QUrl &value) { if (m_source != value) { m_source = value; schedule(); emit sourceChanged(); } }
    void setSourceId(const QString &value) { if (m_sourceId != value) { m_sourceId = value; schedule(); emit sourceIdChanged(); } }
    void setPixelWidth(int value) { if (m_width != value) { m_width = value; schedule(); emit pixelWidthChanged(); } }
    void setPixelHeight(int value) { if (m_height != value) { m_height = value; schedule(); emit pixelHeightChanged(); } }
    void setFit(const QString &value) { if (m_fit != value) { m_fit = value; schedule(); emit fitChanged(); } }
    void setActive(bool value) { if (m_active != value) { m_active = value; schedule(); emit activeChanged(); } }
signals:
    void sourceChanged();
    void sourceIdChanged();
    void pixelWidthChanged();
    void pixelHeightChanged();
    void fitChanged();
    void activeChanged();
    void readySourceChanged();
    void statusChanged();
    void errorChanged();
private:
    void apply(const Result &result, bool clear = false) {
        const bool statusDiffers = m_status != result.status;
        const bool errorDiffers = m_error != result.error;
        const QUrl ready = clear ? QUrl() : result.status == "ready" ? result.source : m_readySource;
        const bool sourceDiffers = ready != m_readySource;
        m_status = result.status;
        m_error = result.error;
        m_readySource = ready;
        QPointer<ImageCacheResolver> alive(this);
        if (sourceDiffers) emit readySourceChanged();
        if (!alive) return;
        if (statusDiffers) emit statusChanged();
        if (!alive) return;
        if (errorDiffers) emit errorChanged();
    }
    void schedule() {
        ++m_generation;
        if (!m_complete || m_scheduled) return;
        m_scheduled = true;
        QTimer::singleShot(0, this, [this] {
            m_scheduled = false;
            ImageCacheManager::instance()->cancel(this);
            if (!m_active || m_source.isEmpty()) { apply({"idle", {}, {}, {}}, true); return; }
            const auto request = BloxImages::request(m_source, m_width, m_height, m_fit, m_sourceId);
            const auto result = lookup(request);
            if (result.status != "missing") { apply(result); return; }
            const quint64 generation = m_generation;
            QPointer<ImageCacheResolver> alive(this);
            apply({"loading", {}, {}, {}});
            if (!alive || generation != m_generation) return;
            ImageCacheManager::instance()->submit(request, this, [alive, generation](const Result &reply) {
                if (alive && alive->m_generation == generation) alive->apply(reply);
            });
        });
    }
    QUrl m_source, m_readySource;
    QString m_sourceId, m_fit = "cover", m_status = "idle", m_error;
    int m_width = 0, m_height = 0;
    quint64 m_generation = 0;
    bool m_active = true, m_complete = false, m_scheduled = false;
};
}

void registerResolver(const char *uri) {
    Dl_info location{};
    if (::dladdr(reinterpret_cast<void *>(&registerResolver), &location))
        helperPath = QFileInfo(QString::fromLocal8Bit(location.dli_fname)).absoluteDir().filePath("blox-image-cache");
    qmlRegisterType<ImageCacheResolver>(uri, 1, 0, "ImageCacheResolver");
}
}

#include "image_cache_resolver.moc"
