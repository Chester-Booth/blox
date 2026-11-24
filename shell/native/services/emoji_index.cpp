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
    Q_PROPERTY(int gridCount READ gridCount NOTIFY gridChanged)
    Q_PROPERTY(int sourceCount READ sourceCount NOTIFY datasetChanged)
    Q_PROPERTY(int emojiCount READ emojiCount NOTIFY datasetChanged)
    Q_PROPERTY(int nerdFontCount READ nerdFontCount NOTIFY datasetChanged)
    Q_PROPERTY(QVariantList nerdFontPurposes READ nerdFontPurposes NOTIFY datasetChanged)
    Q_PROPERTY(QVariantList nerdFontSources READ nerdFontSources NOTIFY datasetChanged)

public:
    explicit NativeEmojiIndex(QObject *parent = nullptr) : QAbstractListModel(parent) {}

    int rowCount(const QModelIndex &parent = {}) const override { return parent.isValid() ? 0 : m_browse.size(); }
    int gridCount() const { return m_gridCells.size(); }
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
    Q_INVOKABLE int searchSourceIndexAt(int row) const { return row >= 0 && row < m_searchResults.size() ? m_searchResults[row] : -1; }
    Q_INVOKABLE int sectionedItemCount() const { return m_sectionSourceIndices.size(); }
    Q_INVOKABLE int sectionedSourceIndexAt(int itemIndex) const { return itemIndex >= 0 && itemIndex < m_sectionSourceIndices.size() ? m_sectionSourceIndices[itemIndex] : -1; }
    Q_INVOKABLE int gridRowKind(int row) const { return row >= 0 && row < m_gridCells.size() ? m_gridCells[row].kind : 2; }
    Q_INVOKABLE int gridRowItemIndex(int row) const { return row >= 0 && row < m_gridCells.size() ? m_gridCells[row].itemIndex : -1; }
    Q_INVOKABLE QString gridRowTitle(int row) const
    {
        if (row < 0 || row >= m_gridCells.size()) return {};
        const int sec = m_gridCells[row].sectionIdx;
        return sec >= 0 && sec < m_sectionTitles.size() ? m_sectionTitles[sec] : QString{};
    }
    Q_INVOKABLE QString gridRowSectionKey(int row) const
    {
        if (row < 0 || row >= m_gridCells.size()) return {};
        const int sec = m_gridCells[row].sectionIdx;
        return sec >= 0 && sec < m_sectionKeys.size() ? m_sectionKeys[sec] : QString{};
    }
    Q_INVOKABLE int gridIndexForItem(int itemIndex) const
    {
        return itemIndex >= 0 && itemIndex < m_itemToGridRow.size() ? m_itemToGridRow[itemIndex] : -1;
    }
    Q_INVOKABLE int gridHeadingRow(const QString &sectionKey) const
    {
        for (const auto &entry : m_headingRows) {
            if (entry.key == sectionKey) return entry.row;
        }
        return -1;
    }
    Q_INVOKABLE QString activeSectionForRow(int firstVisibleRow, const QString &fallback) const
    {
        QString active = fallback;
        for (const auto &entry : m_headingRows) {
            if (entry.row <= firstVisibleRow) active = entry.key;
            else break;
        }
        return active;
    }
    Q_INVOKABLE QString subcategoryAt(int sourceIndex) const { return validIndex(sourceIndex) ? m_records[sourceIndex].subcategory : QString{}; }
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
            if (category != "Search" && record.category != category) continue;
            if (filterSource && !sourceKeys.contains(record.sourceKey)) continue;
            (selected.contains(record.key) ? pinned : unpinned).append(index);
        }
        pinned.append(unpinned);
        return pinned;
    }

    Q_INVOKABLE int buildSectionedGrid(const QString &category, const QString &source, const QStringList &pins, const QVariantList &sections, int columns)
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
        m_sectionKeys.clear();
        m_sectionTitles.clear();
        QHash<QString, int> sectionLookup;
        m_sectionKeys.reserve(sections.size());
        m_sectionTitles.reserve(sections.size());
        for (const auto &value : sections) {
            const auto map = value.toMap();
            const QString key = map["key"].toString();
            sectionLookup.insert(key, m_sectionKeys.size());
            m_sectionKeys.append(key);
            m_sectionTitles.append(map["title"].toString());
        }
        QVector<QVector<int>> pinnedBuckets(m_sectionKeys.size());
        QVector<QVector<int>> unpinnedBuckets(m_sectionKeys.size());
        const bool isSymbols = (category == "Symbols");
        for (int index : m_base) {
            const auto &record = m_records[index];
            if (record.category != category) continue;
            if (filterSource && !sourceKeys.contains(record.sourceKey)) continue;
            const QString key = isSymbols ? symbolSectionKey(record.subcategory) : record.subcategory;
            const int secIdx = sectionLookup.value(key, -1);
            if (secIdx < 0) continue;
            (selected.contains(record.key) ? pinnedBuckets[secIdx] : unpinnedBuckets[secIdx]).append(index);
        }
        m_sectionSourceIndices.clear();
        m_sectionBuckets.clear();
        m_sectionBuckets.resize(m_sectionKeys.size());
        int totalItems = 0;
        for (int sec = 0; sec < m_sectionKeys.size(); ++sec)
            totalItems += pinnedBuckets[sec].size() + unpinnedBuckets[sec].size();
        m_sectionSourceIndices.reserve(totalItems);
        for (int sec = 0; sec < m_sectionKeys.size(); ++sec) {
            auto &bucket = m_sectionBuckets[sec];
            bucket.reserve(pinnedBuckets[sec].size() + unpinnedBuckets[sec].size());
            for (int srcIdx : pinnedBuckets[sec]) {
                bucket.append(m_sectionSourceIndices.size());
                m_sectionSourceIndices.append(srcIdx);
            }
            for (int srcIdx : unpinnedBuckets[sec]) {
                bucket.append(m_sectionSourceIndices.size());
                m_sectionSourceIndices.append(srcIdx);
            }
        }
        m_gridColumns = -1;
        packSectionedGrid(std::max(1, columns));
        return m_sectionSourceIndices.size();
    }

    Q_INVOKABLE void relayoutSectionedGrid(int columns)
    {
        const int clamped = std::max(1, columns);
        if (clamped == m_gridColumns || m_sectionBuckets.isEmpty()) return;
        packSectionedGrid(clamped);
    }

    Q_INVOKABLE void clearSectionedGrid()
    {
        if (m_gridCells.isEmpty() && m_sectionSourceIndices.isEmpty()) return;
        m_gridCells.clear();
        m_sectionBuckets.clear();
        m_sectionKeys.clear();
        m_sectionTitles.clear();
        m_sectionSourceIndices.clear();
        m_itemToGridRow.clear();
        m_headingRows.clear();
        m_gridColumns = 0;
        emit gridChanged();
    }

    Q_INVOKABLE int setSearchResults(const QString &normalisedQuery, const QStringList &pins)
    {
        m_searchResults = computeSearch(normalisedQuery, pins);
        return m_searchResults.size();
    }

    Q_INVOKABLE QVariantList search(const QString &normalisedQuery, const QStringList &pins) const
    {
        const auto indices = computeSearch(normalisedQuery, pins);
        QVariantList result;
        result.reserve(indices.size());
        for (int index : indices) result.append(index);
        return result;
    }

signals:
    void countChanged();
    void datasetChanged();
    void gridChanged();

private:
    struct Record { QJsonObject source; QString key, searchText, category, subcategory, sourceKey; bool isEmoji; };
    struct GridCell { int8_t kind; int itemIndex; int sectionIdx; };
    struct HeadingRow { int row; QString key; };
    bool validIndex(int index) const { return index >= 0 && index < m_records.size(); }

    static bool isWordBoundary(QChar c)
    {
        return c == u' ' || c == u'-' || c == u'_' || c == u'/' || c == u'.';
    }

    static QString symbolSectionKey(const QString &subgroup)
    {
        if (!subgroup.startsWith(u"text-")) return QStringLiteral("emoji");
        if (subgroup == u"text-common" || subgroup == u"text-punctuation") return QStringLiteral("common");
        if (subgroup == u"text-shape") return QStringLiteral("shape");
        if (subgroup == u"text-arrow") return QStringLiteral("arrow");
        if (subgroup == u"text-maths") return QStringLiteral("maths");
        if (subgroup == u"text-currency") return QStringLiteral("currency");
        return QStringLiteral("technical");
    }

    QVector<int> computeSearch(const QString &normalisedQuery, const QStringList &pins) const
    {
        struct Match { int index; bool pinned; double score; };
        const QSet<QString> selected(pins.begin(), pins.end());
        QVector<Match> matches;
        matches.reserve(512);
        for (int index : m_base) {
            const auto &record = m_records[index];
            const double value = score(normalisedQuery, record.searchText);
            if (value >= 0) matches.append({index, selected.contains(record.key), value + (record.isEmoji ? 200 : 0)});
        }
        const int limit = std::min(512, int(matches.size()));
        auto cmp = [](const Match &a, const Match &b) {
            if (a.pinned != b.pinned) return a.pinned > b.pinned;
            if (a.score != b.score) return a.score > b.score;
            return a.index < b.index;
        };
        if (limit < matches.size())
            std::partial_sort(matches.begin(), matches.begin() + limit, matches.end(), cmp);
        else
            std::sort(matches.begin(), matches.end(), cmp);
        QVector<int> result;
        result.reserve(limit);
        for (int i = 0; i < limit; ++i) result.append(matches[i].index);
        return result;
    }

    void packSectionedGrid(int columns)
    {
        m_gridColumns = columns;
        m_gridCells.clear();
        m_headingRows.clear();
        m_itemToGridRow.fill(-1, m_sectionSourceIndices.size());
        m_gridCells.reserve(m_sectionSourceIndices.size() + m_sectionBuckets.size() * (columns * 2));
        for (int sec = 0; sec < m_sectionBuckets.size(); ++sec) {
            const auto &bucket = m_sectionBuckets[sec];
            if (bucket.isEmpty()) continue;
            while (m_gridCells.size() % columns)
                m_gridCells.append({2, -1, -1});
            m_headingRows.append({int(m_gridCells.size()), m_sectionKeys[sec]});
            m_gridCells.append({1, -1, sec});
            for (int col = 1; col < columns; ++col)
                m_gridCells.append({2, -1, -1});
            for (int itemIdx : bucket) {
                m_itemToGridRow[itemIdx] = int(m_gridCells.size());
                m_gridCells.append({0, itemIdx, -1});
            }
        }
        emit gridChanged();
    }

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
            if (next == 0 || isWordBoundary(candidate[next - 1])) total += 9;
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
        m_records.clear(); m_base.clear(); m_browse.clear(); m_searchResults.clear();
        clearSectionedGrid();
        m_variants.clear(); m_tones.clear(); m_multi.clear();
        m_records.reserve(m_emoji.size() + m_nerds.size());
        const QJsonArray sources[] = {m_emoji, m_nerds};
        for (const auto &source : sources) for (const auto &value : source) {
            const auto item = value.toObject();
            const auto text = item["value"].toString(), name = item["name"].toString();
            const int index = m_records.size();
            const auto key = baseEmoji(item["baseValue"].toString().isEmpty() ? text : item["baseValue"].toString());
            const auto subcategory = item["subcategory"].toString();
            m_records.append({item, key, (name + " " + item["keywords"].toString()).toLower(),
                              item["category"].toString(), subcategory, item["source"].toString(),
                              item["kind"].toString() != "nerd-font" && !subcategory.startsWith(u"text-")});
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
    QVector<int> m_base, m_browse, m_searchResults;
    QVector<GridCell> m_gridCells;
    QVector<QVector<int>> m_sectionBuckets;
    QStringList m_sectionKeys, m_sectionTitles;
    QVector<int> m_sectionSourceIndices, m_itemToGridRow;
    QVector<HeadingRow> m_headingRows;
    int m_gridColumns = 0;
    QHash<QString, QString> m_tones;
    QSet<QString> m_multi;
    QHash<QString, QVariantMap> m_variants;
};
}

void BloxEmoji::registerIndex(const char *uri) { qmlRegisterType<NativeEmojiIndex>(uri, 1, 0, "NativeEmojiIndex"); }

#include "emoji_index.moc"
