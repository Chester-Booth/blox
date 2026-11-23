#include "emoji_index.h"
#include <QtCore/QAbstractListModel>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QSet>
#include <QtQml/qqml.h>
#include <algorithm>

namespace {

// Asset data stays native. QML requests payloads for displayed cells and keeps
// only row indices for browsing and search, rather than copying both datasets.
class NativeEmojiIndex : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
    Q_PROPERTY(int sourceCount READ sourceCount NOTIFY datasetChanged)
    Q_PROPERTY(int emojiCount READ emojiCount NOTIFY datasetChanged)
    Q_PROPERTY(int nerdFontCount READ nerdFontCount NOTIFY datasetChanged)
    Q_PROPERTY(QVariantList nerdFontPurposes READ nerdFontPurposes NOTIFY datasetChanged)
    Q_PROPERTY(QVariantList nerdFontSources READ nerdFontSources NOTIFY datasetChanged)

public:
    explicit NativeEmojiIndex(QObject *parent = nullptr) : QAbstractListModel(parent) {}

    int rowCount(const QModelIndex &parent = {}) const override { return parent.isValid() ? 0 : m_browse.size(); }
    int sourceCount() const { return m_records.size(); }
    int emojiCount() const { return m_emoji.size(); }
    int nerdFontCount() const { return m_nerds.size(); }
    QVariantList nerdFontPurposes() const { return m_purposes; }
    QVariantList nerdFontSources() const { return m_sources; }
    QHash<int, QByteArray> roleNames() const override { return {{Qt::UserRole + 1, "item"}}; }

    QVariant data(const QModelIndex &index, int role) const override
    {
        if (!index.isValid() || index.row() < 0 || index.row() >= m_browse.size() || role != Qt::UserRole + 1)
            return {};
        return item(m_browse[index.row()]);
    }

    Q_INVOKABLE bool loadEmojiData(const QString &text)
    {
        QJsonObject document;
        const bool valid = parse(text, document);
        m_emoji = valid ? document["items"].toArray() : QJsonArray{};
        m_emojiLoaded = true;
        rebuild();
        return valid;
    }

    Q_INVOKABLE bool loadNerdFontData(const QString &text)
    {
        QJsonObject document;
        bool valid = parse(text, document);
        for (const auto *key : {"purposes", "source_filters", "sources"})
            valid = valid && (!document.contains(key) || document[key].isArray());
        m_nerds = valid ? document["items"].toArray() : QJsonArray{};
        m_purposes = valid ? document["purposes"].toArray().toVariantList() : QVariantList{};
        m_sourceFilters = valid ? document[document.contains("source_filters") ? "source_filters" : "sources"].toArray().toVariantList() : QVariantList{};
        m_nerdsLoaded = true;
        rebuild();
        return valid;
    }

    Q_INVOKABLE void clearEmojiData() { m_emoji = {}; m_emojiLoaded = true; rebuild(); }
    Q_INVOKABLE void clearNerdFontData() { m_nerds = {}; m_nerdsLoaded = true; m_purposes.clear(); m_sourceFilters.clear(); rebuild(); }

    Q_INVOKABLE QVariantMap item(int sourceIndex) const
    {
        return validIndex(sourceIndex) ? m_records[sourceIndex].source.toVariantMap() : QVariantMap{};
    }
    Q_INVOKABLE int sourceIndexAt(int row) const { return row >= 0 && row < m_browse.size() ? m_browse[row] : -1; }
    Q_INVOKABLE QString subcategoryAt(int sourceIndex) const { return validIndex(sourceIndex) ? m_records[sourceIndex].source["subcategory"].toString() : QString{}; }
    Q_INVOKABLE QVariantMap variantsForGroup(const QString &group) const { return m_variants.value(group); }
    Q_INVOKABLE QString toneValue(const QString &key) const { return m_tones.value(key); }
    Q_INVOKABLE bool hasMixedTones(const QString &group) const { return m_multi.contains(group); }

    Q_INVOKABLE void setPins(const QStringList &pins)
    {
        const QSet<QString> selected(pins.begin(), pins.end());
        beginResetModel();
        m_browse.clear();
        for (int index : m_base) if (selected.contains(m_records[index].key)) m_browse.append(index);
        for (int index : m_base) if (!selected.contains(m_records[index].key)) m_browse.append(index);
        endResetModel();
        emit countChanged();
    }

    Q_INVOKABLE QVariantList filteredIndices(const QString &category, const QString &source, const QStringList &pins) const
    {
        const QSet<QString> selected(pins.begin(), pins.end());
        QStringList sourceKeys;
        bool filterSource = false;
        if (category == "Nerd Fonts" && source != "all") {
            for (const auto &value : m_sources) {
                const auto entry = value.toMap();
                if (entry["key"].toString() != source) continue;
                filterSource = true;
                if (entry.contains("keys")) {
                    for (const auto &key : entry["keys"].toList()) sourceKeys.append(key.toString());
                } else sourceKeys.append(source);
                break;
            }
        }
        QVariantList pinned, unpinned;
        for (int index : m_base) {
            const auto &record = m_records[index];
            if (category != "Search" && record.source["category"].toString() != category) continue;
            if (filterSource && !sourceKeys.contains(record.source["source"].toString())) continue;
            (selected.contains(record.key) ? pinned : unpinned).append(index);
        }
        pinned.append(unpinned);
        return pinned;
    }

    Q_INVOKABLE QVariantList search(const QString &normalisedQuery, const QStringList &pins) const
    {
        struct Match { int index; bool pinned; double score; };
        const QSet<QString> selected(pins.begin(), pins.end());
        QVector<Match> matches;
        for (int index : m_base) {
            const auto &record = m_records[index];
            const double value = score(normalisedQuery, record.searchText);
            if (value >= 0) matches.append({index, selected.contains(record.key), value + (record.isEmoji ? 200 : 0)});
        }
        std::sort(matches.begin(), matches.end(), [](const auto &a, const auto &b) {
            if (a.pinned != b.pinned) return a.pinned > b.pinned;
            if (a.score != b.score) return a.score > b.score;
            return a.index < b.index;
        });
        QVariantList result;
        result.reserve(std::min(512, int(matches.size())));
        for (int i = 0; i < std::min(512, int(matches.size())); ++i) result.append(matches[i].index);
        return result;
    }

signals:
    void countChanged();
    void datasetChanged();

private:
    struct Record { QJsonObject source; QString key, searchText; bool isEmoji; };
    bool validIndex(int index) const { return index >= 0 && index < m_records.size(); }

    static bool parse(const QString &text, QJsonObject &object)
    {
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(text.toUtf8(), &error);
        if (error.error != QJsonParseError::NoError || !document.isObject()) return false;
        object = document.object();
        if (!object["items"].isArray()) return false;
        for (const auto &value : object["items"].toArray()) {
            const auto item = value.toObject();
            if (!value.isObject() || !item["value"].isString() || !item["name"].isString() || !item["keywords"].isString()) return false;
        }
        return true;
    }

    static QString baseEmoji(QString text)
    {
        for (char32_t cp = 0x1f3fb; cp <= 0x1f3ff; ++cp) text.replace(QString::fromUcs4(&cp, 1), QString{});
        return text;
    }
    static QString toneKey(QString text) { return baseEmoji(text).remove(QChar(0xfe0f)).remove(QChar(0xfe0e)); }
    static QList<int> tonePair(const QString &value)
    {
        QList<int> pair;
        for (char32_t cp : value.toUcs4()) if (cp >= 0x1f3fb && cp <= 0x1f3ff) pair.append(cp - 0x1f3fb + 1);
        return pair;
    }
    static QString groupName(QString name)
    {
        const QStringList tones = {"light skin tone", "medium-light skin tone", "medium skin tone", "medium-dark skin tone", "dark skin tone"};
        bool changed = true;
        while (changed) {
            changed = false;
            for (const auto &tone : tones) {
                const auto comma = ", " + tone, colon = ": " + tone;
                if (name.endsWith(comma)) { name.chop(comma.size()); changed = true; }
                else if (name.endsWith(colon)) { name.chop(colon.size()); changed = true; }
            }
        }
        if (name == "couple with heart: person, person") return "couple with heart";
        if (name == "kiss: person, person") return "kiss";
        return name;
    }
    static double score(const QString &query, const QString &candidate)
    {
        const int exact = candidate.indexOf(query);
        if (exact >= 0) return 10000 - exact * 10 - candidate.size();
        int position = -1;
        double total = 0;
        for (int i = 0; i < query.size(); ++i) {
            const int next = candidate.indexOf(query[i], position + 1);
            if (next < 0) return -1;
            total += next == position + 1 ? 12 : 4;
            if (next == 0 || QStringLiteral(" -_/.").contains(candidate[next - 1])) total += 9;
            total -= std::max(0, next - position - 1);
            position = next;
        }
        return total - candidate.size() * 0.02;
    }

    void rebuild()
    {
        m_sources = {QVariantMap{{"key", "all"}, {"title", "All sources"}, {"count", m_nerds.size()}}};
        m_sources.append(m_sourceFilters);
        if (!m_emojiLoaded || !m_nerdsLoaded) { emit datasetChanged(); return; }
        beginResetModel();
        m_records.clear(); m_base.clear(); m_browse.clear();
        m_variants.clear(); m_tones.clear(); m_multi.clear();
        m_records.reserve(m_emoji.size() + m_nerds.size());
        const QJsonArray sources[] = {m_emoji, m_nerds};
        for (const auto &source : sources) for (const auto &value : source) {
            const auto item = value.toObject();
            const auto text = item["value"].toString(), name = item["name"].toString();
            const int index = m_records.size();
            const auto key = baseEmoji(item["baseValue"].toString().isEmpty() ? text : item["baseValue"].toString());
            m_records.append({item, key, (name + " " + item["keywords"].toString()).toLower(), item["kind"].toString() != "nerd-font" && !item["subcategory"].toString().startsWith("text-")});
            const auto pair = tonePair(text);
            if (pair.isEmpty()) m_base.append(index);
            else {
                const auto group = groupName(item["variantGroup"].toString().isEmpty() ? name : item["variantGroup"].toString());
                QStringList joined;
                for (int tone : pair) joined.append(QString::number(tone));
                m_variants[group][joined.join(":")] = text;
                if (pair.size() == 1) m_variants[group][joined[0] + ":" + joined[0]] = text;
                if (pair.size() > 1) m_multi.insert(group);
                const QSet<int> unique(pair.begin(), pair.end());
                if (unique.size() == 1) m_tones[toneKey(text) + ":" + joined[0]] = text;
            }
        }
        m_browse = m_base;
        endResetModel();
        emit datasetChanged();
        emit countChanged();
    }

    QJsonArray m_emoji, m_nerds;
    bool m_emojiLoaded = false, m_nerdsLoaded = false;
    QVariantList m_purposes, m_sourceFilters, m_sources;
    QVector<Record> m_records;
    QVector<int> m_base, m_browse;
    QHash<QString, QString> m_tones;
    QSet<QString> m_multi;
    QHash<QString, QVariantMap> m_variants;
};
}

void BloxEmoji::registerIndex(const char *uri) { qmlRegisterType<NativeEmojiIndex>(uri, 1, 0, "NativeEmojiIndex"); }

#include "emoji_index.moc"
