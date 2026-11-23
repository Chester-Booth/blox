#pragma once

#include <QJsonObject>
#include <QSize>
#include <QString>
#include <QUrl>

namespace BloxImages {
struct Request {
    QString source, sourceId, cacheRoot, key, error;
    QSize size;
    QString fit;
    QJsonObject identity;
};

struct Result {
    QString status, error;
    QUrl source;
    QJsonObject data;
};

QString cacheDirectory();
// Dimensions are physical pixels. Lookup reads only stat data and small cache headers.
Request request(const QUrl &source, int width, int height, const QString &fit,
                const QString &sourceId = {}, const QString &cacheRoot = {});
QJsonObject serialise(const Request &request);
Result lookup(const Request &request);
// Only the short-lived helper calls prepare. The QML plugin never decodes source images.
Result prepare(const Request &request);
void registerResolver(const char *uri);
}
