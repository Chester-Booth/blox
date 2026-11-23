#include "image_cache.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QImageWriter>
#include <QJsonDocument>
#include <QLockFile>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef BLOX_IMAGE_CACHE_BUILD_ID
#error The image cache requires a native build identity
#endif

namespace BloxImages {
namespace {
constexpr qint64 MaxSourceBytes = 48 * 1024 * 1024;
constexpr qint64 MaxPixels = 64 * 1024 * 1024;

QString decoder() { return QStringLiteral("qt-image-v1:") + BLOX_IMAGE_CACHE_BUILD_ID + ":" + qVersion(); }
QString hash(const QByteArray &value) { return QString::fromLatin1(QCryptographicHash::hash(value, QCryptographicHash::Sha256).toHex()); }
QByteArray json(const QJsonObject &value) { return QJsonDocument(value).toJson(QJsonDocument::Compact); }
Result failure(const QString &message) { return {"error", message, {}, {}}; }

QJsonObject identity(const struct stat &info) {
    return {{"device", QString::number(info.st_dev)}, {"inode", QString::number(info.st_ino)},
            {"size", QString::number(info.st_size)},
            {"modifiedNs", QString::number(qint64(info.st_mtim.tv_sec) * 1000000000 + info.st_mtim.tv_nsec)},
            {"changedNs", QString::number(qint64(info.st_ctim.tv_sec) * 1000000000 + info.st_ctim.tv_nsec)}};
}

QJsonObject fileIdentity(const QString &path) {
    struct stat info;
    if (::lstat(QFile::encodeName(path).constData(), &info) || !S_ISREG(info.st_mode)) return {};
    return identity(info);
}

bool digestValid(const QString &value) {
    static const QRegularExpression pattern("^[0-9a-f]{64}$");
    return pattern.match(value).hasMatch();
}

bool safeCache(const QString &path) {
    QString current = QDir::cleanPath(QFileInfo(path).absoluteFilePath());
    while (current != "/") {
        if (QFileInfo(current).isSymLink()) return false;
        current = QFileInfo(current).absolutePath();
    }
    const QFileInfo root(path);
    return !root.exists() || root.isDir() && root.ownerId() == ::getuid();
}

QString directory(const Request &request) { return QDir(request.cacheRoot).filePath("v1"); }
QString indexPath(const Request &request) { return QDir(directory(request)).filePath(request.key + ".json"); }
QString imagePath(const Request &request, const QString &sourceId) {
    const QJsonObject options{{"decoder", decoder()}, {"sourceId", sourceId},
                             {"width", request.size.width()}, {"height", request.size.height()},
                             {"fit", request.fit}, {"autoTransform", false}};
    return QDir(directory(request)).filePath(hash(json(options)) + ".png");
}

bool pngHeader(const QString &path, const QSize &size) {
    QFile input(path);
    if (!input.open(QIODevice::ReadOnly)) return false;
    const QByteArray header = input.read(33);
    if (header.size() != 33 || !header.startsWith(QByteArray::fromHex("89504e470d0a1a0a0000000d49484452"))) return false;
    auto number = [&](int offset) {
        quint32 value = 0;
        for (int n = 0; n < 4; ++n) value = value * 256 + quint8(header[offset+n]);
        return value;
    };
    quint32 crc = 0xffffffff;
    for (int i = 12; i < 29; ++i) {
        crc ^= quint8(header[i]);
        for (int bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ (0xedb88320 & (0 - (crc & 1)));
    }
    return number(16) == quint32(size.width()) && number(20) == quint32(size.height()) && (crc ^ 0xffffffff) == number(29);
}

QJsonObject readIndex(const QString &path) {
    if (QFileInfo(path).isSymLink()) return {};
    QFile input(path);
    if (!input.open(QIODevice::ReadOnly) || input.size() > 8192) return {};
    const auto document = QJsonDocument::fromJson(input.readAll());
    return document.isObject() ? document.object() : QJsonObject{};
}
}

QString cacheDirectory() {
    return QDir(QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation)).filePath("blox/images");
}

Request request(const QUrl &url, int width, int height, const QString &fit,
                const QString &sourceId, const QString &cacheRoot) {
    Request result;
    result.fit = fit;
    result.size = QSize(width, height);
    result.sourceId = sourceId;
    result.cacheRoot = cacheRoot.isEmpty() ? cacheDirectory() : QFileInfo(cacheRoot).absoluteFilePath();
    if (!url.isLocalFile()) result.error = "A local image file is required";
    else if (!QStringList{"cover", "contain", "tile"}.contains(fit)) result.error = "Unsupported image fit";
    else if (!sourceId.isEmpty() && !digestValid(sourceId)) result.error = "Invalid wallpaper identity";
    else if (width < 1 || height < 1 || width > 16384 || height > 16384 || qint64(width) * height > MaxPixels)
        result.error = "Invalid physical image dimensions";
    else {
        const QFileInfo source(url.toLocalFile());
        if (source.isSymLink() || !source.isFile() || source.size() > MaxSourceBytes)
            result.error = "Image source is missing, linked or too large";
        else {
            result.source = source.canonicalFilePath();
            result.identity = fileIdentity(result.source);
            if (result.identity.isEmpty()) result.error = "Image source could not be inspected";
        }
    }
    if (result.error.isEmpty() && QDir::cleanPath(result.cacheRoot) != QDir::cleanPath(cacheDirectory()))
        result.error = "Image output must remain inside the owned image cache";
    if (result.error.isEmpty() && (!safeCache(result.cacheRoot) || !safeCache(directory(result))))
        result.error = "Image cache directory is unsafe";
    if (result.error.isEmpty()) {
        QJsonObject options{{"source", result.source}, {"identity", result.identity}, {"decoder", decoder()},
                            {"width", width}, {"height", height}, {"fit", fit}, {"autoTransform", false}};
        result.key = hash(json(options));
    }
    return result;
}

QJsonObject serialise(const Request &request) {
    return {{"source", QUrl::fromLocalFile(request.source).toString()}, {"sourceId", request.sourceId},
            {"width", request.size.width()}, {"height", request.size.height()}, {"fit", request.fit},
            {"cacheRoot", request.cacheRoot}, {"identity", request.identity}, {"key", request.key}};
}

Result lookup(const Request &request) {
    if (!request.error.isEmpty()) return failure(request.error);
    if (!safeCache(request.cacheRoot) || !safeCache(directory(request))) return failure("Image cache directory is unsafe");
    if (fileIdentity(request.source) != request.identity) return failure("Image source changed");
    if (request.fit == "tile") return {"ready", {}, QUrl::fromLocalFile(request.source), {{"tile", true}, {"cacheHit", true}}};
    const auto metadata = readIndex(indexPath(request));
    const QString sourceId = metadata["sourceId"].toString();
    if (metadata["format"] != 1 || metadata["decoder"] != decoder() || metadata["key"] != request.key
        || metadata["sourceIdentity"] != request.identity || !digestValid(sourceId)
        || !request.sourceId.isEmpty() && request.sourceId != sourceId) return {"missing", {}, {}, {}};
    const QString path = imagePath(request, sourceId);
    const auto actual = fileIdentity(path);
    const QSize size(metadata["width"].toInt(), metadata["height"].toInt());
    if (actual.isEmpty() || actual != metadata["imageIdentity"].toObject() || !size.isValid()
        || qint64(size.width()) * size.height() > MaxPixels || !pngHeader(path, size)) return {"missing", {}, {}, {}};
    return {"ready", {}, QUrl::fromLocalFile(path), {{"cacheHit", true}, {"sourceId", sourceId},
            {"width", size.width()}, {"height", size.height()}, {"key", request.key}}};
}

Result prepare(const Request &request) {
    auto existing = lookup(request);
    if (existing.status != "missing") return existing;
    if (!safeCache(request.cacheRoot) || !safeCache(directory(request)) || !QDir().mkpath(directory(request))
        || !safeCache(directory(request))) return failure("Could not create image cache");
    const QString lockPath = QDir(directory(request)).filePath(request.key + ".lock");
    if (QFileInfo(lockPath).isSymLink()) return failure("Image cache lock is linked");
    QLockFile lock(lockPath);
    lock.setStaleLockTime(0);
    if (!lock.tryLock(30000)) return failure("Image cache request is busy");
    existing = lookup(request);
    if (existing.status != "missing") return existing;
    const int descriptor = ::open(QFile::encodeName(request.source).constData(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) return failure("Image source could not be opened");
    QFile input;
    if (!input.open(descriptor, QIODevice::ReadOnly, QFileDevice::AutoCloseHandle)) { ::close(descriptor); return failure("Image source could not be read"); }
    struct stat before;
    if (::fstat(descriptor, &before) || !S_ISREG(before.st_mode) || identity(before) != request.identity)
        return failure("Image source changed");
    QCryptographicHash digest(QCryptographicHash::Sha256);
    qint64 bytes = 0;
    while (!input.atEnd()) {
        const QByteArray chunk = input.read(1024 * 1024);
        if (chunk.isEmpty() && input.error() != QFileDevice::NoError) return failure("Image source could not be hashed");
        bytes += chunk.size();
        if (bytes > MaxSourceBytes) return failure("Image source grew beyond its limit");
        digest.addData(chunk);
    }
    const QString sourceId = QString::fromLatin1(digest.result().toHex());
    if (!request.sourceId.isEmpty() && sourceId != request.sourceId) return failure("Wallpaper identity no longer matches the source");
    if (!input.seek(0)) return failure("Image source could not be rewound");
    struct stat hashed;
    if (::fstat(descriptor, &hashed) || identity(hashed) != request.identity) return failure("Image source changed while hashing");
    QImageReader::setAllocationLimit(256);
    QImageReader reader(&input);
    reader.setAutoTransform(false);
    const QByteArray format = reader.format();
    const QSize native = reader.size();
    if (!QList<QByteArray>{"png", "jpeg", "webp"}.contains(format) || !native.isValid()
        || qint64(native.width()) * native.height() > MaxPixels) return failure("Unsupported image source");
    const QSizeF proposed = QSizeF(native).scaled(QSizeF(request.size), Qt::KeepAspectRatioByExpanding);
    const QSize scaled = proposed.width() > native.width() || proposed.height() > native.height() ? native : proposed.toSize();
    reader.setScaledSize(scaled);
    const QImage image = reader.read();
    if (image.isNull()) return failure("Image decode failed: " + reader.errorString());
    struct stat after;
    if (::fstat(descriptor, &after) || identity(before) != identity(after) || fileIdentity(request.source) != request.identity)
        return failure("Image source changed during decoding");
    const QString path = imagePath(request, sourceId);
    if (!safeCache(directory(request)) || QFileInfo(path).isSymLink() || QFileInfo(indexPath(request)).isSymLink())
        return failure("Image cache publication path is unsafe");
    QSaveFile output(path);
    output.setDirectWriteFallback(false);
    if (!output.open(QIODevice::WriteOnly)) return failure("Could not create image derivative");
    QImageWriter writer(&output, "png");
    writer.setCompression(1);
    if (!writer.write(image) || !output.commit()) return failure("Could not publish image derivative");
    QJsonObject metadata{{"format", 1}, {"decoder", decoder()}, {"key", request.key}, {"sourceId", sourceId},
                         {"sourceIdentity", request.identity}, {"imageIdentity", fileIdentity(path)},
                         {"width", image.width()}, {"height", image.height()}};
    QSaveFile index(indexPath(request));
    index.setDirectWriteFallback(false);
    if (!index.open(QIODevice::WriteOnly) || index.write(json(metadata)) < 0 || !index.commit())
        return failure("Could not publish image cache index");
    auto result = lookup(request);
    if (result.status != "ready") return failure("Image cache publication could not be verified");
    result.data["cacheHit"] = false;
    return result;
}
}
