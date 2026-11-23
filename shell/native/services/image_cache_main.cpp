#include "image_cache.h"
#include <QCoreApplication>
#include <QJsonDocument>
#include <QTextStream>
#include <sys/stat.h>

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    ::umask(0077);
    const auto arguments = app.arguments();
    if (arguments.size() != 2 || arguments[1].size() > 16384) return 2;
    const auto document = QJsonDocument::fromJson(arguments[1].toUtf8());
    if (!document.isObject()) return 2;
    const auto data = document.object();
    const auto width = data["width"], height = data["height"];
    if (!width.isDouble() || !height.isDouble() || width.toDouble() != width.toInt() || height.toDouble() != height.toInt()) return 2;
    auto request = BloxImages::request(QUrl(data["source"].toString()), width.toInt(), height.toInt(), data["fit"].toString(),
                                       data["sourceId"].toString(), data["cacheRoot"].toString());
    if (!data["identity"].isUndefined() && data["identity"] != request.identity) request.error = "Image source changed before preparation";
    if (!data["key"].isUndefined() && data["key"].toString() != request.key) request.error = "Image cache request identity changed";
    const auto result = BloxImages::prepare(request);
    QJsonObject output = result.data;
    output["status"] = result.status;
    output["source"] = result.source.toString();
    output["error"] = result.error;
    QTextStream(stdout) << QJsonDocument(output).toJson(QJsonDocument::Compact) << '\n';
    return result.status == "ready" ? 0 : 1;
}
