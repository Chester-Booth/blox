#pragma once

#include <QColor>
#include <QElapsedTimer>
#include <QImage>
#include <QJsonObject>
#include <QPointer>
#include <QQuickItem>
#include <QVariantMap>
#include <memory>
#include <atomic>

namespace BloxTerminal {

struct Cell {
    QString text;
    QColor foreground, background;
    int runStart = 0;
    bool bold = false, underline = false, inverse = false;
    bool operator==(const Cell &) const = default;
};
struct Frame {
    Frame();
    ~Frame();
    Frame(const Frame &) = delete;
    Frame &operator=(const Frame &) = delete;
    int generation = 0, attempt = 0, columns = 0;
    qint64 revision = 0, sequence = 0;
    QVector<QVector<Cell>> rows;
};

// One staging slot per live subscription. Staging never changes an adopted
// renderer frame. Host acceptance must deliver the matching metadata first.
class FrameSource final : public QObject {
    Q_OBJECT
public:
    explicit FrameSource(QObject *parent = nullptr);
    ~FrameSource() override;
    QString token;
    std::shared_ptr<const Frame> staged;
signals:
    void invalidated();
};

class Decoder : public QObject {
    Q_OBJECT
    Q_PROPERTY(int consumerCount READ consumerCount NOTIFY consumersChanged)
public:
    explicit Decoder(QObject *parent = nullptr) : QObject(parent) {}
    ~Decoder() override;
    int consumerCount() const { return consumers.size(); }
    Q_INVOKABLE bool subscribe(const QString &id, const QString &provider, int generation);
    Q_INVOKABLE void unsubscribe(const QString &id);
    Q_INVOKABLE void clear();
    Q_INVOKABLE void readChunk(const QString &chunk);
signals:
    void messageReady(const QVariantMap &message);
    void protocolError(const QString &error);
    void consumersChanged();
private:
    struct Consumer { QString provider; int generation; qint64 revision = -1; FrameSource *source = nullptr; };
    QHash<QString, Consumer> consumers;
    QByteArray input;
    quint64 resetEpoch = 0;
    bool clearing = false;
    void readMessage(const QJsonObject &message);
};

class Scheduler;
void finishUnusedWorker();
struct RenderJob;
struct RenderResult;

class Surface : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QVariantMap frame READ frame WRITE setFrame NOTIFY frameChanged)
    Q_PROPERTY(QString fontFamily READ fontFamily WRITE setFontFamily NOTIFY appearanceChanged)
    Q_PROPERTY(qreal fontSize READ fontSize WRITE setFontSize NOTIFY appearanceChanged)
    Q_PROPERTY(qreal cellWidth READ cellWidth WRITE setCellWidth NOTIFY appearanceChanged)
    Q_PROPERTY(qreal cellHeight READ cellHeight WRITE setCellHeight NOTIFY appearanceChanged)
    Q_PROPERTY(qreal ascent READ ascent WRITE setAscent NOTIFY appearanceChanged)
    Q_PROPERTY(QColor foreground READ foreground WRITE setForeground NOTIFY appearanceChanged)
    Q_PROPERTY(QColor background READ background WRITE setBackground NOTIFY appearanceChanged)
    Q_PROPERTY(qreal drawScale READ drawScale WRITE setDrawScale NOTIFY appearanceChanged)
    Q_PROPERTY(qreal gridWidth READ gridWidth NOTIFY gridChanged)
    Q_PROPERTY(qreal gridHeight READ gridHeight NOTIFY gridChanged)
    Q_PROPERTY(qreal displayWidth READ displayWidth NOTIFY geometryUpdated)
    Q_PROPERTY(qreal displayHeight READ displayHeight NOTIFY geometryUpdated)
    Q_PROPERTY(bool contentReady READ contentReady NOTIFY contentReadyChanged)
    Q_PROPERTY(QVariantMap diagnostics READ diagnostics NOTIFY diagnosticsChanged)
public:
    explicit Surface(QQuickItem *parent = nullptr);
    ~Surface() override;
    QVariantMap frame() const { return metadata; }
    void setFrame(const QVariantMap &value);
    QString fontFamily() const { return family; }
    qreal fontSize() const { return size; }
    qreal cellWidth() const { return cw; }
    qreal cellHeight() const { return ch; }
    qreal ascent() const { return baseline; }
    qreal drawScale() const { return scale; }
    QColor foreground() const { return fg; }
    QColor background() const { return bg; }
    void setFontFamily(const QString &value);
    void setFontSize(qreal value);
    void setCellWidth(qreal value);
    void setCellHeight(qreal value);
    void setAscent(qreal value);
    void setDrawScale(qreal value);
    void setForeground(const QColor &value);
    void setBackground(const QColor &value);
    qreal gridWidth() const { return desired ? desired->columns * cw : 0; }
    qreal gridHeight() const { return desired ? desired->rows.size() * ch : 0; }
    qreal displayWidth() const { return gridWidth() * scale; }
    qreal displayHeight() const { return gridHeight() * scale; }
    bool contentReady() const { return ready; }
    QVariantMap diagnostics() const;
signals:
    void frameChanged();
    void appearanceChanged();
    void geometryUpdated();
    void gridChanged();
    void contentReadyChanged();
    void diagnosticsChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *, UpdatePaintNodeData *) override;
    void itemChange(ItemChange change, const ItemChangeData &data) override;
    void releaseResources() override;
private:
    friend class Scheduler;
    QVariantMap metadata, stats;
    QPointer<FrameSource> source;
    QMetaObject::Connection sourceInvalidated, sourceDestroyed;
    QMetaObject::Connection screenChanged;
    std::shared_ptr<const Frame> desired, rendered;
    std::shared_ptr<std::atomic_bool> cancellation;
    QImage image;
    QString family = QStringLiteral("monospace");
    qreal size = 14, cw = 9, ch = 18, baseline = 14, scale = 1;
    QColor fg = QColor("#e8edf4"), bg = QColor("#161a20");
    quint64 appearance = 0, paintedAppearance = 0;
    quint64 frameEpoch = 0; // A nested adoption or discard supersedes interrupted notifications.
    qreal paintedDpr = 0;
    bool ready = false, textureDirty = true, requested = false;
    quint64 completed = 0;
    QElapsedTimer firstImageTimer;
    qint64 firstImageLatency = -1;
    void invalidate();
    bool discard();
    bool geometry();
    void request();
    void accept(RenderResult result, const RenderJob &job);
};

} // namespace BloxTerminal
