#include "terminal.h"

#include <QDataStream>
#include <QElapsedTimer>
#include <QFont>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPainter>
#include <QPainterPath>
#include <QQuickWindow>
#include <QRunnable>
#include <QSGImageNode>
#include <QThreadPool>
#include <QTimer>
#include <QSet>
#include <cmath>
#include <list>
#include <optional>

namespace BloxTerminal {
static QHash<QString, QPointer<FrameSource>> frameSources;
static quint64 sourceSequence = 0;
static std::atomic_int liveFrames = 0;
static QSet<Surface *> surfaces;
static quint64 fontEpoch = 0;
Frame::Frame() { ++liveFrames; }
Frame::~Frame() { --liveFrames; }
FrameSource::FrameSource(QObject *parent) : QObject(parent), token(QString::number(++sourceSequence, 36)) { frameSources.insert(token, this); }
FrameSource::~FrameSource() { frameSources.remove(token); }
namespace {
constexpr qsizetype MaxLine = 8 * 1024 * 1024;
constexpr qint64 MaxPixels = 16777216;
constexpr int MaxSide = 8192;
constexpr qsizetype CacheBytes = 4 * 1024 * 1024;
constexpr int CacheEntries = 2048;

bool integer(const QJsonValue &value, qint64 minimum, qint64 maximum) {
    return value.isDouble() && std::isfinite(value.toDouble()) && std::floor(value.toDouble()) == value.toDouble()
        && value.toDouble() >= double(minimum) && value.toDouble() <= double(maximum);
}
bool identifier(const QString &value) { return !value.isEmpty() && value.size() <= 128; }
bool cluster(const QString &text) {
    int count = 0;
    for (qsizetype i = 0; i < text.size(); ++i) {
        const QChar ch = text[i];
        if (ch.isHighSurrogate()) {
            if (++i == text.size() || !text[i].isLowSurrogate()) return false;
        } else if (ch.isLowSurrogate()) return false;
        if (++count > 8) return false;
    }
    return true;
}
bool colour(const QJsonValue &value, QColor &result) {
    if (value.isNull() || value.isUndefined()) { result = QColor(); return true; }
    if (!value.isString() || value.toString().size() > 64) return false;
    result = QColor(value.toString());
    return result.isValid();
}

std::shared_ptr<Frame> decode(const QJsonObject &value, int generation, qint64 revision, const std::shared_ptr<const Frame> &base) {
    if (!integer(value["generation"], 0, INT_MAX) || value["generation"].toInt() != generation
        || !integer(value["attempt"], 1, INT_MAX) || !integer(value["sequence"], 0, 9007199254740991LL)
        || !integer(value["columns"], 2, 240) || !integer(value["rowCount"], 1, 100)) return {};
    const int columns = value["columns"].toInt(), rowCount = value["rowCount"].toInt();
    const bool patch = value["rowFormat"] == "patch-v1";
    if (columns * rowCount > 12000 || value.contains("changedRuns")) return {};
    QJsonArray rows;
    if (patch) {
        if (!base || base->generation != generation || base->attempt != value["attempt"].toInt()
            || base->columns != columns || base->rows.size() != rowCount || value.contains("rows")
            || !integer(value["baseRevision"], 0, 9007199254740991LL)
            || !integer(value["baseSequence"], 0, 9007199254740991LL)
            || qint64(value["baseRevision"].toDouble()) != base->revision
            || qint64(value["baseSequence"].toDouble()) != base->sequence
            || revision <= base->revision || value["sequence"].toDouble() < base->sequence
            || !value["rowPatches"].isArray()) return {};
        rows = value["rowPatches"].toArray();
        if (rows.size() > rowCount) return {};
    } else {
        if (value["rowFormat"] != "full-v1" || !value["rows"].isArray()
            || value.contains("rowPatches") || value.contains("baseRevision") || value.contains("baseSequence")) return {};
        rows = value["rows"].toArray();
        if (rows.size() != rowCount) return {};
    }
    auto result = std::make_shared<Frame>();
    result->generation = generation; result->revision = revision;
    result->attempt = value["attempt"].toInt(); result->sequence = qint64(value["sequence"].toDouble());
    result->columns = columns; result->rows.reserve(rowCount);
    if (patch) result->rows = base->rows;
    int previousIndex = -1;
    for (const auto &encoded : rows) {
        QJsonValue entry = encoded;
        int index = result->rows.size();
        if (patch) {
            if (!encoded.isArray()) return {};
            const auto pair = encoded.toArray();
            if (pair.size() != 2 || !integer(pair[0], 0, rowCount - 1)) return {};
            index = pair[0].toInt();
            if (index <= previousIndex) return {};
            previousIndex = index; entry = pair[1];
        }
        if (!entry.isObject() || !entry.toObject()["runs"].isArray()) return {};
        const QJsonArray runs = entry.toObject()["runs"].toArray();
        if (runs.isEmpty() || runs.size() > columns) return {};
        QVector<Cell> cells; cells.reserve(columns);
        for (const auto &runEntry : runs) {
            if (!runEntry.isObject()) return {};
            const auto run = runEntry.toObject();
            if (!integer(run["column"], 0, columns - 1) || run["column"].toInt() != cells.size()
                || !run["cells"].isArray()) return {};
            const auto strings = run["cells"].toArray();
            if (strings.isEmpty() || strings.size() + cells.size() > columns) return {};
            Cell style;
            style.runStart = cells.size();
            if (!colour(run["foreground"], style.foreground) || !colour(run["background"], style.background)) return {};
            for (const char *flag : {"bold", "underline", "inverse"})
                if (!run[flag].isUndefined() && !run[flag].isBool()) return {};
            style.bold = run["bold"].toBool(); style.underline = run["underline"].toBool(); style.inverse = run["inverse"].toBool();
            for (const auto &string : strings) {
                if (!string.isString()) return {};
                auto text = string.toString();
                if (!cluster(text)) return {};
                Cell cell = style; cell.text = std::move(text);
                // ANSI insert/delete/erase can orphan wide-cell placeholders.
                // Preserve those parser cells and skip their glyphs, like Canvas.
                cells.append(std::move(cell));
            }
        }
        if (cells.size() != columns) return {};
        if (patch) result->rows[index] = std::move(cells);
        else result->rows.append(std::move(cells));
    }
    return result;
}

struct RasterSize { QSize logical, physical; };
RasterSize rasterSize(qreal width, qreal height, qreal scale, qreal dpr) {
    if (!(width > 0 && height > 0 && scale > 0 && dpr > 0)
        || !std::isfinite(width * height * scale * scale * dpr * dpr)) return {};
    const double factor = std::min({double(scale), MaxSide / (width * dpr), MaxSide / (height * dpr),
        std::sqrt(MaxPixels / (width * height * dpr * dpr))});
    int logicalWidth = std::max(1, int(std::floor(width * factor)));
    int logicalHeight = std::max(1, int(std::floor(height * factor)));
    if (qint64(qRound(logicalWidth * dpr)) * qRound(logicalHeight * dpr) > MaxPixels) {
        if (logicalWidth < logicalHeight) --logicalWidth; else --logicalHeight;
    }
    logicalWidth = std::max(1, logicalWidth); logicalHeight = std::max(1, logicalHeight);
    int w = std::clamp(qRound(logicalWidth * dpr), 1, MaxSide);
    int h = std::clamp(qRound(logicalHeight * dpr), 1, MaxSide);
    // Check the integers actually passed to QImage, not only the scale estimate.
    if (qint64(w) * h > MaxPixels) {
        if (w < h) w = int(MaxPixels / h); else h = int(MaxPixels / w);
    }
    return {QSize(logicalWidth, logicalHeight), QSize(w, h)};
}

// Cache outlines rather than device-rasterised tiles. The same path is filled
// at the actual fractional origin, so CJK fallback glyphs and fractional DPR
// do not change rasterisation through an intermediate image or DPI choice.
class GlyphCache {
    struct Entry { QByteArray key; QPainterPath path; qsizetype cost; };
    std::list<Entry> lru;
    QHash<QByteArray, std::list<Entry>::iterator> index;
public:
    qsizetype bytes = 0;
    int entries() const { return int(lru.size()); }
    QPainterPath path(const QFont &font, const QString &text, quint64 epoch) {
        QByteArray key;
        QDataStream stream(&key, QIODevice::WriteOnly);
        stream << font << text << epoch;
        auto found = index.find(key);
        if (found != index.end()) { lru.splice(lru.begin(), lru, found.value()); return found.value()->path; }
        QPainterPath shape; shape.addText(QPointF(0, 0), font, text);
        // Reserve conservatively for Qt's path element storage and map/list
        // overhead. Text is at most eight Unicode scalars per validated cell.
        const qsizetype cost = 1024 + key.size() * 2 + qsizetype(shape.elementCount()) * 96;
        if (cost > CacheBytes) return shape;
        while (!lru.empty() && (bytes + cost > CacheBytes || lru.size() >= CacheEntries)) {
            bytes -= lru.back().cost; index.remove(lru.back().key); lru.pop_back();
        }
        lru.push_front({key, shape, cost}); index.insert(key, lru.begin()); bytes += cost;
        return shape;
    }
};
} // namespace

Decoder::~Decoder() { clear(); }
bool Decoder::subscribe(const QString &id, const QString &provider, int generation) {
    if (clearing || !identifier(id) || !identifier(provider) || generation < 0 || (!consumers.contains(id) && consumers.size() >= 128)) return false;
    QPointer<Decoder> alive(this);
    const auto epoch = resetEpoch;
    unsubscribe(id);
    if (!alive || resetEpoch != epoch || consumers.contains(id)) return false;
    Consumer consumer{provider, generation};
    if (provider == "terminal") consumer.source = new FrameSource(this);
    consumers.insert(id, consumer); emit consumersChanged(); return true;
}
void Decoder::unsubscribe(const QString &id) {
    auto found = consumers.find(id);
    if (found == consumers.end()) return;
    QPointer<Decoder> alive(this);
    QPointer<FrameSource> source = found->source;
    consumers.erase(found);
    if (source) { source->staged.reset(); emit source->invalidated(); if (source) delete source; }
    if (alive) emit consumersChanged();
}
void Decoder::clear() {
    if (clearing) return;
    clearing = true; ++resetEpoch;
    QPointer<Decoder> alive(this);
    input.clear();
    const auto keys = consumers.keys();
    for (const auto &id : keys) { unsubscribe(id); if (!alive) return; }
    clearing = false;
}
void Decoder::readChunk(const QString &chunk) {
    QPointer<Decoder> alive(this);
    const auto epoch = resetEpoch;
    // A read can contain many valid lines. Bound conversion scratch space and
    // the unfinished line separately, not the total size of that read.
    for (qsizetype offset = 0; offset < chunk.size();) {
        qsizetype count = std::min<qsizetype>(65536, chunk.size() - offset);
        if (offset + count < chunk.size() && chunk[offset + count - 1].isHighSurrogate()
            && chunk[offset + count].isLowSurrogate()) ++count;
        const auto bytes = QStringView(chunk).mid(offset, count).toUtf8();
        offset += count;
        qsizetype start = 0;
        while (start < bytes.size()) {
            qsizetype end = bytes.indexOf('\n', start);
            const bool complete = end >= 0;
            if (!complete) end = bytes.size();
            if (input.size() + end - start > MaxLine) { clear(); if (alive) emit protocolError("Broker response exceeds limit"); return; }
            input.append(bytes.constData() + start, end - start);
            if (complete) {
                QJsonParseError error;
                const auto document = QJsonDocument::fromJson(input, &error);
                input.clear();
                if (error.error != QJsonParseError::NoError || !document.isObject()) {
                    clear(); if (alive) emit protocolError("Malformed broker response"); return;
                }
                readMessage(document.object());
                if (!alive || resetEpoch != epoch) return;
            }
            start = end + 1;
        }
    }
}
void Decoder::readMessage(const QJsonObject &message) {
    const auto id = message["consumerId"].toString();
    auto found = consumers.find(id);
    if (found == consumers.end() && message.contains("snapshot")) return;
    if (found == consumers.end() || found->provider != "terminal" || !message.contains("snapshot")) {
        emit messageReady(message.toVariantMap()); return;
    }
    if (!message["snapshot"].isObject()) { emit protocolError("Invalid terminal envelope"); return; }
    const auto envelope = message["snapshot"].toObject();
    const auto revisionValue = envelope["revision"];
    if (!integer(envelope["generation"], 0, INT_MAX) || envelope["generation"].toInt() != found->generation
        || !integer(revisionValue, 0, 9007199254740991LL) || revisionValue.toDouble() <= found->revision) return;
    if (!envelope["observedMonotonicMs"].isDouble() || !std::isfinite(envelope["observedMonotonicMs"].toDouble())
        || !QStringList{"preparing", "ready", "unavailable"}.contains(envelope["state"].toString())
        || !envelope["error"].isString() || envelope["error"].toString().size() > 512
        || !envelope["value"].isObject()) { emit protocolError("Invalid terminal envelope"); return; }
    const qint64 revision = qint64(revisionValue.toDouble());
    const auto value = envelope["value"].toObject();
    const auto previous = found->source->staged;
    const bool hasGrid = value.contains("rows") || value.contains("rowFormat") || value.contains("rowPatches");
    auto nativeFrame = hasGrid ? decode(value, found->generation, revision, previous) : std::shared_ptr<Frame>();
    if ((hasGrid && !nativeFrame) || (envelope["state"] == "ready" && !nativeFrame)) {
        emit protocolError("Invalid terminal frame"); return;
    }
    if (nativeFrame && previous && (nativeFrame->attempt < previous->attempt
        || (nativeFrame->attempt == previous->attempt && nativeFrame->sequence < previous->sequence))) return;
    QVariantMap small;
    for (const char *key : {"generation", "sequence", "columns", "rowCount", "readiness", "bytesObserved", "exited", "exitCode",
             "failure", "stopReason", "sourceCapabilities", "restartPolicy", "attempt", "lifecycle", "restartPending",
             "restartAtMonotonicMs", "restartDelaySeconds"})
        if (value.contains(key)) {
            const auto field = value[key];
            if (field.isArray() || (field.isObject() && QByteArray(key) != "failure" && QByteArray(key) != "sourceCapabilities")
                || (field.isObject() && QJsonDocument(field.toObject()).toJson(QJsonDocument::Compact).size() > 1024)
                || (field.isString() && field.toString().size() > 512)) {
                emit protocolError("Invalid terminal metadata"); return;
            }
            small.insert(key, field.toVariant());
        }
    if (nativeFrame) {
        int nonblank = 0;
        for (const auto &row : nativeFrame->rows) for (const auto &cell : row) if (!cell.text.trimmed().isEmpty()) ++nonblank;
        small["nonblankCells"] = nonblank;
        small["frameToken"] = found->source->token;
        small["frameRevision"] = revision;
    }
    // The envelope's value is never converted to QVariant or a QML JS object.
    QVariantMap output;
    for (const char *key : {"generation", "revision", "observedMonotonicMs", "state", "error"})
        output[key] = envelope[key].toVariant();
    found->revision = revision;
    found->source->staged = nativeFrame;
    output["value"] = small;
    emit messageReady({{"consumerId", id}, {"snapshot", output}});
}

struct RenderJob {
    std::shared_ptr<const Frame> frame, previous;
    QImage previousImage;
    QFont font;
    QColor foreground, background;
    qreal cw, ch, ascent, scale, dpr;
    QSize pixels;
    QSize logical;
    quint64 appearance;
    quint64 fonts;
    bool full;
    std::shared_ptr<std::atomic_bool> cancelled;
};
struct RenderResult {
    QImage image;
    bool changed = false;
    QVariantMap diagnostics;
};

static RenderResult render(const RenderJob &job, GlyphCache &cache) {
    RenderResult result;
    if (job.cancelled->load() || job.pixels.isEmpty()) return result;
    QElapsedTimer elapsed; elapsed.start();
    result.image = job.full ? QImage(job.pixels, QImage::Format_ARGB32_Premultiplied) : job.previousImage;
    if (result.image.isNull()) return result;
    if (job.full) result.image.fill(Qt::transparent);
    const qreal sx = job.logical.width() * job.dpr / (job.cw * job.frame->columns);
    const qreal sy = job.logical.height() * job.dpr / (job.ch * job.frame->rows.size());
    QVector<int> dirty;
    for (int row = 0; row < job.frame->rows.size(); ++row)
        if (job.full || !job.previous || job.frame->rows[row] != job.previous->rows[row]) dirty.append(row);
    auto describe = [&](int rows) {
        result.diagnostics = {{"rasterWidth", result.image.width()}, {"rasterHeight", result.image.height()},
            {"allocatedBytes", qint64(result.image.sizeInBytes())}, {"bytesPerLine", result.image.bytesPerLine()},
            {"paintedRows", rows}, {"rasterMs", elapsed.nsecsElapsed() / 1e6},
            {"logicalRasterWidth", job.logical.width()}, {"logicalRasterHeight", job.logical.height()},
            {"appearanceRevision", qint64(job.appearance)}, {"fontFamily", job.font.family()}, {"fontPixelSize", job.font.pixelSize()},
            {"cellWidth", job.cw}, {"cellHeight", job.ch}, {"drawScale", job.scale}, {"ascent", job.ascent},
            {"glyphCacheBytes", qint64(cache.bytes)}, {"glyphCacheEntries", cache.entries()},
            {"glyphCacheByteLimit", qint64(CacheBytes)}, {"glyphCacheEntryLimit", CacheEntries},
            {"dpr", job.dpr}, {"revision", job.frame->revision}};
    };
    // Constructing QPainter would detach and copy the retained image even if
    // no row changed. Metadata-only updates must not do that work.
    if (dirty.isEmpty()) { describe(0); return result; }
    QPainter painter(&result.image);
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.setPen(Qt::NoPen);
    int paintedRows = 0;
    for (int row : dirty) {
        if (job.cancelled->load()) { painter.end(); return {}; }
        const auto &cells = job.frame->rows[row];
        ++paintedRows;
        const int top = qRound(row * job.ch * sy), bottom = qRound((row + 1) * job.ch * sy);
        painter.resetTransform(); painter.setClipping(false);
        painter.setCompositionMode(QPainter::CompositionMode_Source);
        painter.fillRect(QRect(0, top, result.image.width(), bottom - top), Qt::transparent);
        painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
        painter.setClipRect(QRect(0, top, result.image.width(), bottom - top));
        painter.scale(sx, sy);
        auto colours = [&](const Cell &cell) {
            QColor fg = cell.foreground.isValid() ? cell.foreground : job.foreground;
            QColor bg = cell.background;
            if (cell.inverse) { bg = fg; fg = cell.background.isValid() ? cell.background : job.background; }
            return std::pair(fg, bg);
        };
        // Backgrounds precede every glyph, including wide continuation cells.
        for (int col = 0; col < cells.size();) {
            int end = col + 1;
            while (end < cells.size() && cells[end].runStart == cells[col].runStart) ++end;
            const auto [fg, bg] = colours(cells[col]);
            if (bg.isValid()) painter.fillRect(QRectF(col * job.cw, top / sy, (end-col) * job.cw, (bottom - top) / sy), bg);
            col = end;
        }
        for (int col = 0; col < cells.size(); ++col) {
            if (job.cancelled->load()) { painter.end(); return {}; }
            const auto &cell = cells[col];
            const auto [fg, bg] = colours(cell);
            if (!cell.text.isEmpty() && cell.text != " ") {
                QFont font = job.font; font.setBold(cell.bold);
                const int span = col + 1 < cells.size() && cells[col + 1].runStart == cell.runStart && cells[col + 1].text.isEmpty() ? 2 : 1;
                painter.save();
                painter.setClipRect(QRectF(col * job.cw, top / sy, span * job.cw, (bottom - top) / sy), Qt::IntersectClip);
                // Translate outline coordinates before the raster transform,
                // as Canvas fillText does. Combining the translation into the
                // painter transform changes a few subpixel coverage samples.
                painter.fillPath(cache.path(font, cell.text, job.fonts).translated(col * job.cw, row * job.ch + job.ascent), fg);
                painter.restore();
            }
        }
        for (int col = 0; col < cells.size();) {
            int end = col + 1;
            while (end < cells.size() && cells[end].runStart == cells[col].runStart) ++end;
            if (cells[col].underline) {
                const auto [fg, bg] = colours(cells[col]);
                painter.fillRect(QRectF(col * job.cw, row * job.ch + job.ascent + 1, (end-col)*job.cw, 1), fg);
            }
            col = end;
        }
    }
    painter.end();
    result.changed = paintedRows > 0;
    describe(paintedRows);
    return result;
}

// One worker and at most one pending slot per view. No periodic wake, FIFO of
// frames or GUI-thread font rasterisation. A view's latest state is read when
// its slot starts; completion may display an in-flight frame before the latest.
class Scheduler final : public QObject {
public:
    explicit Scheduler(QObject *parent) : QObject(parent) {
        pool.setMaxThreadCount(1); pool.setExpiryTimeout(-1);
        connect(qGuiApp, &QGuiApplication::fontDatabaseChanged, this, [] {
            ++fontEpoch;
            QList<QPointer<Surface>> live;
            for (auto surface : std::as_const(surfaces)) live.append(surface);
            for (auto surface : live) if (surface) surface->invalidate();
        });
        connect(qApp, &QCoreApplication::aboutToQuit, this, [this] {
            stopping = true; pending.clear();
            for (auto surface : std::as_const(surfaces))
                if (surface->cancellation) surface->cancellation->store(true);
            // Join before QGuiApplication tears down its font database.
            pool.waitForDone();
        });
    }
    ~Scheduler() override { pool.waitForDone(); }
    QThreadPool pool;
    GlyphCache cache;
    QList<QPointer<Surface>> pending;
    bool busy = false;
    bool scheduled = false;
    bool stopping = false;
    void enqueue(Surface *item) {
        if (stopping) return;
        if (!pending.contains(item)) pending.append(item);
        if (!busy && !scheduled) {
            scheduled = true;
            QTimer::singleShot(0, this, [this] { scheduled = false; next(); });
        }
    }
    void remove(Surface *item) { pending.removeAll(item); }
    void next() {
        if (busy || stopping) return;
        QPointer<Surface> item;
        while (!pending.isEmpty()) { item = pending.takeFirst(); if (item && item->requested && item->desired) break; item = nullptr; }
        if (!item) return;
        item->requested = false;
        const qreal dpr = item->window() ? item->window()->effectiveDevicePixelRatio() : 1;
        QFont font(item->family); font.setPixelSize(qRound(item->size));
        const auto raster = rasterSize(item->gridWidth(), item->gridHeight(), item->scale, dpr);
        const auto pixels = raster.physical;
        auto cancelled = std::make_shared<std::atomic_bool>(false);
        item->cancellation = cancelled;
        RenderJob job{item->desired, item->rendered, item->image, font, item->fg, item->bg,
            item->cw, item->ch, item->baseline, item->scale, dpr, pixels, raster.logical, item->appearance, fontEpoch,
            !item->rendered || item->image.size() != pixels || item->paintedAppearance != item->appearance
                || item->paintedDpr != dpr || item->rendered->generation != item->desired->generation
                || item->rendered->attempt != item->desired->attempt || item->rendered->columns != item->desired->columns
                || item->rendered->rows.size() != item->desired->rows.size(), cancelled};
        busy = true;
        pool.start(QRunnable::create([this, item, job] {
            auto result = render(job, cache);
            QMetaObject::invokeMethod(this, [this, item, job, result = std::move(result)]() mutable {
                busy = false;
                if (item) item->accept(std::move(result), job);
                next();
            }, Qt::QueuedConnection);
        }));
    }
};
static QPointer<Scheduler> renderScheduler;
static Scheduler *scheduler() {
    if (!renderScheduler) renderScheduler = new Scheduler(qApp);
    return renderScheduler;
}
void finishUnusedWorker() {
    // RenderControl/PySide owners may never enter app.exec(), so they emit no
    // aboutToQuit. Join after the last engine/view, before GUI font teardown.
    if (renderScheduler && surfaces.isEmpty()) renderScheduler->pool.waitForDone();
}

Surface::Surface(QQuickItem *parent) : QQuickItem(parent) {
    surfaces.insert(this);
    setFlag(ItemHasContents, true);
    connect(this, &QQuickItem::windowChanged, this, [this](QQuickWindow *window) {
        disconnect(screenChanged);
        if (window) screenChanged = connect(window, &QWindow::screenChanged, this, [this] { invalidate(); });
        invalidate();
    });
}
Surface::~Surface() {
    surfaces.remove(this);
    disconnect(sourceInvalidated); disconnect(sourceDestroyed); disconnect(screenChanged);
    disconnect(this, nullptr, this, nullptr);
    if (cancellation) cancellation->store(true);
    if (renderScheduler) renderScheduler->remove(this);
}
bool Surface::discard() {
    QPointer<Surface> alive(this);
    const auto epoch = ++frameEpoch;
    auto current = [&] { return alive && frameEpoch == epoch; };
    if (cancellation) cancellation->store(true);
    if (renderScheduler) renderScheduler->remove(this);
    requested = false;
    const bool hadGrid = bool(desired);
    desired.reset(); rendered.reset(); image = {}; metadata.clear();
    firstImageTimer.invalidate(); firstImageLatency = -1;
    textureDirty = true;
    if (ready) { ready = false; emit contentReadyChanged(); if (!current()) return false; }
    if (!geometry() || !current()) return false;
    if (hadGrid) { emit gridChanged(); if (!current()) return false; }
    update(); emit diagnosticsChanged();
    return current();
}
void Surface::setFrame(const QVariantMap &value) {
    if (value.isEmpty() || !value.contains("frameToken")) {
        disconnect(sourceInvalidated); disconnect(sourceDestroyed); source = nullptr;
        if (discard()) emit frameChanged();
        return;
    }
    const auto token = value.value("frameToken").toString();
    QPointer<FrameSource> next = frameSources.value(token);
    const auto candidate = next ? next->staged : nullptr;
    if (!candidate || candidate->revision != value.value("frameRevision").toLongLong()
        || candidate->generation != value.value("generation").toInt()
        || candidate->attempt != value.value("attempt").toInt()) return;
    QPointer<Surface> alive(this);
    auto epoch = ++frameEpoch;
    auto current = [&] { return alive && frameEpoch == epoch; };
    const bool replacement = source != next;
    const bool reset = replacement || (desired && (candidate->generation != desired->generation
        || candidate->attempt != desired->attempt || candidate->columns != desired->columns
        || candidate->rows.size() != desired->rows.size()));
    if (replacement) {
        disconnect(sourceInvalidated); disconnect(sourceDestroyed); source = nullptr;
    }
    if (reset) {
        // Every notification can run QML which clears, replaces or destroys us.
        // A guarded QObject alone is insufficient when a nested setter wins.
        if (!discard()) return;
        epoch = frameEpoch;
        if (!next || frameSources.value(token) != next || next->staged != candidate) return;
    }
    if (replacement) {
        source = next;
        sourceInvalidated = connect(next, &FrameSource::invalidated, this, [this] { discard(); });
        sourceDestroyed = connect(next, &QObject::destroyed, this, [this] { source = nullptr; discard(); });
    }
    const bool changedGrid = !desired || desired->columns != candidate->columns || desired->rows.size() != candidate->rows.size();
    if (!desired) firstImageTimer.start();
    desired = candidate; metadata = value;
    if (!geometry() || !current()) return;
    if (changedGrid) { emit gridChanged(); if (!current()) return; }
    request(); emit frameChanged();
}
bool Surface::geometry() {
    QPointer<Surface> alive(this);
    const auto epoch = frameEpoch;
    auto current = [&] { return alive && frameEpoch == epoch; };
    setWidth(displayWidth()); if (!current()) return false;
    setHeight(displayHeight()); if (!current()) return false;
    emit geometryUpdated();
    return current();
}
void Surface::invalidate() {
    QPointer<Surface> alive(this);
    const auto epoch = frameEpoch, version = ++appearance;
    if (cancellation) cancellation->store(true);
    const bool unchanged = geometry();
    if (!alive) return;
    if (unchanged && frameEpoch == epoch && appearance == version) request();
    // A nested frame change cancels this request, not the property notification.
    emit appearanceChanged();
}
void Surface::request() {
    if (!desired || !source || !window() || !(cw > 0 && ch > 0 && scale > 0) || (!isVisible() && ready)) return;
    requested = true; scheduler()->enqueue(this);
}
void Surface::accept(RenderResult result, const RenderJob &job) {
    if (job.cancelled->load() || !source || !desired || result.image.isNull() || job.appearance != appearance
        || job.frame->generation != desired->generation || job.frame->attempt != desired->attempt
        || job.frame->columns != desired->columns || job.frame->rows.size() != desired->rows.size()) return;
    rendered = job.frame; paintedAppearance = job.appearance; paintedDpr = job.dpr;
    image = std::move(result.image); stats = std::move(result.diagnostics); ++completed;
    if (result.changed) { textureDirty = true; update(); }
    if (!ready) {
        firstImageLatency = firstImageTimer.isValid() ? firstImageTimer.elapsed() : 0;
        QPointer<Surface> alive(this);
        const auto epoch = frameEpoch;
        ready = true; emit contentReadyChanged();
        if (!alive || frameEpoch != epoch) return;
    }
    emit diagnosticsChanged();
}
QVariantMap Surface::diagnostics() const {
    auto result = stats;
    result["completedFrames"] = qint64(completed);
    result["hasImage"] = !image.isNull();
    result["hasFrame"] = bool(desired);
    result["rasterWidth"] = image.width(); result["rasterHeight"] = image.height();
    result["allocatedBytes"] = qint64(image.sizeInBytes());
    result["firstImageLatencyMs"] = firstImageLatency;
    result["desiredAppearanceRevision"] = qint64(appearance);
    result["liveModels"] = liveFrames.load();
    result["liveSources"] = frameSources.size();
    return result;
}
void Surface::setFontFamily(const QString &value) { if (value == family || value.isEmpty() || value.size() > 1024) return; family = value; invalidate(); }
#define REAL_SETTER(Name, member, minimum, maximum) \
void Surface::set##Name(qreal value) { \
    if (!std::isfinite(value) || value < minimum || value > maximum || value == member) return; \
    member = value; invalidate(); \
}
REAL_SETTER(FontSize, size, 1, 1000000000)
REAL_SETTER(Ascent, baseline, 0, 1000000000)
REAL_SETTER(DrawScale, scale, 0, 1000000000)
#undef REAL_SETTER
void Surface::setCellWidth(qreal value) {
    if (!std::isfinite(value) || value < .001 || value > 1000000000 || value == cw) return;
    QPointer<Surface> alive(this);
    cw = value; invalidate(); if (alive) emit gridChanged();
}
void Surface::setCellHeight(qreal value) {
    if (!std::isfinite(value) || value < .001 || value > 1000000000 || value == ch) return;
    QPointer<Surface> alive(this);
    ch = value; invalidate(); if (alive) emit gridChanged();
}
void Surface::setForeground(const QColor &value) { if (!value.isValid() || value == fg) return; fg = value; invalidate(); }
void Surface::setBackground(const QColor &value) { if (!value.isValid() || value == bg) return; bg = value; invalidate(); }
void Surface::itemChange(ItemChange change, const ItemChangeData &data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemVisibleHasChanged) {
        if (data.boolValue) request();
        else if (ready) { if (cancellation) cancellation->store(true); requested = false; scheduler()->remove(this); }
    }
    if (change == ItemDevicePixelRatioHasChanged) invalidate();
}
void Surface::releaseResources() { textureDirty = true; }
QSGNode *Surface::updatePaintNode(QSGNode *old, UpdatePaintNodeData *) {
    auto node = static_cast<QSGImageNode *>(old);
    if (image.isNull() || !window()) { delete node; return nullptr; }
    if (!node) textureDirty = true;
    if (textureDirty) {
        auto texture = window()->createTextureFromImage(image);
        if (!texture) { delete node; return nullptr; }
        // Replace the owning node as a unit. Backends may inspect the previous
        // material texture during setTexture(), so never delete it beforehand.
        auto next = window()->createImageNode();
        if (!next) { delete texture; delete node; return nullptr; }
        delete node; node = next;
        node->setTexture(texture); node->setOwnsTexture(true);
        node->setFiltering(QSGTexture::Linear); textureDirty = false;
        node->setSourceRect(QRectF(0, 0, image.width(), image.height()));
    }
    node->setRect(boundingRect()); return node;
}
} // namespace BloxTerminal
