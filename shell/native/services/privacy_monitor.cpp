#include "privacy_monitor.h"

#include <QtCore/QDateTime>
#include <QtCore/QMetaObject>
#include <QtCore/QPointer>
#include <QtQml/qqml.h>
#include <pipewire/pipewire.h>
#include <spa/utils/dict.h>
#include <spa/utils/hook.h>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

namespace {
std::once_flag pwInitFlag;

void ensurePipewireInit()
{
    std::call_once(pwInitFlag, []() { pw_init(nullptr, nullptr); });
}

QVariantMap makePrivacyPayload(int mic, int video, bool available, bool ready, const QString &reason)
{
    QStringList parts;
    if (mic > 0) parts.append(QStringLiteral("Microphone capture: %1").arg(mic));
    if (video > 0) parts.append(QStringLiteral("Video/screen capture: %1").arg(video));
    const bool isActive = !parts.isEmpty();
    const QString tooltip = !available || !ready
        ? QStringLiteral("Privacy status unavailable")
        : isActive ? parts.join(QStringLiteral("\n"))
                   : QStringLiteral("No active microphone, camera or screen capture");
    const QString stateClass = !available || !ready ? QStringLiteral("error")
        : isActive ? QStringLiteral("active") : QStringLiteral("idle");

    QVariantMap cap;
    cap.insert(QStringLiteral("available"), available);
    cap.insert(QStringLiteral("ready"), ready);
    cap.insert(QStringLiteral("canChange"), false);
    cap.insert(QStringLiteral("permission"), QStringLiteral("not-required"));
    cap.insert(QStringLiteral("reason"), reason.isEmpty() ? QVariant() : QVariant(reason));

    QVariantMap payload;
    payload.insert(QStringLiteral("icon"), QStringLiteral("󰍹"));
    payload.insert(QStringLiteral("class"), stateClass);
    payload.insert(QStringLiteral("active"), isActive);
    payload.insert(QStringLiteral("microphoneCount"), mic);
    payload.insert(QStringLiteral("videoCount"), video);
    payload.insert(QStringLiteral("details"), tooltip);
    payload.insert(QStringLiteral("tooltip"), tooltip);
    payload.insert(QStringLiteral("capability"), cap);
    return payload;
}
}

struct NativePrivacyMonitor::Impl {
    struct LinkEntry {
        uint32_t id = 0;
        uint32_t outputNode = 0;
        uint32_t inputNode = 0;
        bool active = false;
        pw_proxy *proxy = nullptr;
        spa_hook listener{};
        Impl *owner = nullptr;
    };

    QPointer<NativePrivacyMonitor> target;
    pw_thread_loop *loop = nullptr;
    pw_context *context = nullptr;
    pw_core *core = nullptr;
    pw_registry *registry = nullptr;
    spa_hook coreListener{};
    spa_hook registryListener{};
    std::unordered_map<uint32_t, std::string> nodeClasses;
    std::unordered_map<uint32_t, std::unique_ptr<LinkEntry>> links;
    int lastMic = -1;
    int lastVideo = -1;
    bool connected = false;

    void recomputeAndNotify(bool force = false)
    {
        std::unordered_set<uint32_t> micStreams;
        std::unordered_set<uint32_t> videoStreams;
        for (const auto &[_, link] : links) {
            if (!link->active) continue;
            const auto outIt = nodeClasses.find(link->outputNode);
            const auto inIt = nodeClasses.find(link->inputNode);
            const std::string &outClass = outIt != nodeClasses.end() ? outIt->second : std::string();
            const std::string &inClass = inIt != nodeClasses.end() ? inIt->second : std::string();
            if (outClass == "Audio/Source" && inClass.rfind("Stream/Input/Audio", 0) == 0)
                micStreams.insert(link->inputNode);
            if (outClass.find("Video") != std::string::npos || inClass.find("Video") != std::string::npos) {
                const uint32_t streamId = inClass.rfind("Stream/", 0) == 0 ? link->inputNode : link->outputNode;
                videoStreams.insert(streamId);
            }
        }
        const int mic = static_cast<int>(micStreams.size());
        const int video = static_cast<int>(videoStreams.size());
        if (!force && mic == lastMic && video == lastVideo) return;
        lastMic = mic;
        lastVideo = video;
        QPointer<NativePrivacyMonitor> guard = target;
        if (!guard) return;
        QMetaObject::invokeMethod(guard.data(), [guard, mic, video]() {
            if (guard) guard->publishCounts(mic, video, true, QString());
        }, Qt::QueuedConnection);
    }

    static void onLinkInfo(void *data, const pw_link_info *info)
    {
        auto *entry = static_cast<LinkEntry *>(data);
        if (!entry || !info) return;
        entry->outputNode = info->output_node_id;
        entry->inputNode = info->input_node_id;
        entry->active = info->state == PW_LINK_STATE_ACTIVE;
        entry->owner->recomputeAndNotify();
    }

    static void onRegistryGlobal(void *data, uint32_t id, uint32_t, const char *type,
                                 uint32_t version, const spa_dict *props)
    {
        auto *self = static_cast<Impl *>(data);
        if (!self || !type) return;
        if (std::string_view(type) == PW_TYPE_INTERFACE_Node && props) {
            if (const char *cls = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS)) {
                self->nodeClasses[id] = cls;
                self->recomputeAndNotify();
            }
        } else if (std::string_view(type) == PW_TYPE_INTERFACE_Link) {
            static const pw_link_events linkEvents = {
                PW_VERSION_LINK_EVENTS,
                &Impl::onLinkInfo,
            };
            auto entry = std::make_unique<LinkEntry>();
            entry->id = id;
            entry->owner = self;
            entry->proxy = static_cast<pw_proxy *>(
                pw_registry_bind(self->registry, id, type, version, 0));
            if (entry->proxy) {
                pw_proxy_add_object_listener(entry->proxy, &entry->listener, &linkEvents, entry.get());
                self->links[id] = std::move(entry);
            }
        }
    }

    static void onRegistryGlobalRemove(void *data, uint32_t id)
    {
        auto *self = static_cast<Impl *>(data);
        if (!self) return;
        bool changed = self->nodeClasses.erase(id) > 0;
        auto it = self->links.find(id);
        if (it != self->links.end()) {
            spa_hook_remove(&it->second->listener);
            if (it->second->proxy) pw_proxy_destroy(it->second->proxy);
            self->links.erase(it);
            changed = true;
        }
        if (changed) self->recomputeAndNotify();
    }

    static void onCoreDone(void *data, uint32_t, int)
    {
        auto *self = static_cast<Impl *>(data);
        if (self) self->recomputeAndNotify(true);
    }

    static void onCoreError(void *data, uint32_t id, int, int, const char *message)
    {
        auto *self = static_cast<Impl *>(data);
        if (!self || id != PW_ID_CORE) return;
        QPointer<NativePrivacyMonitor> guard = self->target;
        const QString err = message ? QString::fromUtf8(message) : QStringLiteral("PipeWire core error");
        if (!guard) return;
        QMetaObject::invokeMethod(guard.data(), [guard, err]() {
            if (guard) guard->publishCounts(0, 0, false, err);
        }, Qt::QueuedConnection);
    }

    bool begin()
    {
        ensurePipewireInit();
        loop = pw_thread_loop_new("blox-privacy", nullptr);
        if (!loop) return false;
        context = pw_context_new(pw_thread_loop_get_loop(loop), nullptr, 0);
        if (!context) return false;

        pw_thread_loop_lock(loop);
        if (pw_thread_loop_start(loop) < 0) {
            pw_thread_loop_unlock(loop);
            return false;
        }
        core = pw_context_connect(context, nullptr, 0);
        if (!core) {
            pw_thread_loop_unlock(loop);
            return false;
        }
        static const pw_core_events coreEvents = {
            PW_VERSION_CORE_EVENTS,
            nullptr,
            &Impl::onCoreDone,
            nullptr,
            &Impl::onCoreError,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
        };
        pw_core_add_listener(core, &coreListener, &coreEvents, this);

        registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
        if (!registry) {
            pw_thread_loop_unlock(loop);
            return false;
        }
        static const pw_registry_events registryEvents = {
            PW_VERSION_REGISTRY_EVENTS,
            &Impl::onRegistryGlobal,
            &Impl::onRegistryGlobalRemove,
        };
        pw_registry_add_listener(registry, &registryListener, &registryEvents, this);
        pw_core_sync(core, PW_ID_CORE, 0);
        connected = true;
        pw_thread_loop_unlock(loop);
        return true;
    }

    void teardown()
    {
        if (!loop) return;
        pw_thread_loop_lock(loop);
        for (auto &[_, entry] : links) {
            spa_hook_remove(&entry->listener);
            if (entry->proxy) pw_proxy_destroy(entry->proxy);
        }
        links.clear();
        nodeClasses.clear();
        if (registry) {
            spa_hook_remove(&registryListener);
            pw_proxy_destroy(reinterpret_cast<pw_proxy *>(registry));
            registry = nullptr;
        }
        if (core) {
            spa_hook_remove(&coreListener);
            pw_core_disconnect(core);
            core = nullptr;
        }
        connected = false;
        pw_thread_loop_unlock(loop);
        pw_thread_loop_stop(loop);
        if (context) {
            pw_context_destroy(context);
            context = nullptr;
        }
        pw_thread_loop_destroy(loop);
        loop = nullptr;
    }
};

NativePrivacyMonitor::NativePrivacyMonitor(QObject *parent)
    : QObject(parent), m_json(makePrivacyPayload(0, 0, true, true, QString())) {}

NativePrivacyMonitor::~NativePrivacyMonitor() { stop(); }

void NativePrivacyMonitor::componentComplete()
{
    m_complete = true;
    if (m_enabled) start();
}

void NativePrivacyMonitor::setEnabled(bool value)
{
    if (m_enabled == value) return;
    m_enabled = value;
    emit enabledChanged();
    if (!m_complete) return;
    if (m_enabled) start();
    else stop();
}

void NativePrivacyMonitor::start()
{
    stop();
    auto impl = std::make_unique<Impl>();
    impl->target = this;
    if (!impl->begin()) {
        impl->teardown();
        publishCounts(0, 0, false, QStringLiteral("PipeWire unavailable"));
        return;
    }
    m_impl = std::move(impl);
}

void NativePrivacyMonitor::stop()
{
    if (m_impl) {
        m_impl->teardown();
        m_impl.reset();
    }
}

void NativePrivacyMonitor::refresh()
{
    if (!m_enabled || !m_complete) return;
    if (!m_impl || !m_impl->connected) {
        start();
    }
}

void NativePrivacyMonitor::publishCounts(int microphones, int videos, bool ready, const QString &error)
{
    m_microphoneCount = microphones;
    m_videoCount = videos;
    m_ok = ready;
    m_lastError = error;
    m_lastUpdatedMs = static_cast<qreal>(QDateTime::currentMSecsSinceEpoch());
    m_json = makePrivacyPayload(microphones, videos, ready, ready, ready ? QString() : QStringLiteral("query-failed"));
    emit stateChanged();
    emit jsonChanged();
}

namespace BloxPrivacy {
void registerMonitor(const char *uri)
{
    qmlRegisterType<NativePrivacyMonitor>(uri, 1, 0, "NativePrivacyMonitor");
}
}
