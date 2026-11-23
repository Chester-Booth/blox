import QtQuick
import QtQuick.Layouts
import qs.shared

Item {
    id: root

    required property var windowOwner
    property Flickable scrollHost: null
    property var sectionMap: []
    // Pages can map search-result labels to the exact control they describe.
    property var searchTargetMap: []
    property Item flashItem: null
    property real flashX: 0
    property real flashY: 0
    property real flashWidth: width
    property real flashHeight: 0

    default property alias content: body.data

    implicitWidth: body.implicitWidth
    implicitHeight: body.implicitHeight

    function sectionFor(id) {
        return sectionMap.find(entry => entry.id === id) || null;
    }

    function jumpToSection(id) {
        const section = sectionFor(id);
        if (!section || !section.item)
            return false;
        const point = section.item.mapToItem(scrollHost ? scrollHost.contentItem : root, 0, 0);
        if (scrollHost && scrollHost.contentHeight > scrollHost.height + 1)
            scrollHost.contentY = Math.max(0, Math.min(scrollHost.contentHeight - scrollHost.height, point.y - 12));
        flashSection(section.item);
        return true;
    }

    function normaliseTarget(value) {
        return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    }

    function findTarget(item, wanted) {
        if (!item)
            return null;
        const cleanWanted = normaliseTarget(wanted);
        const names = [];
        if (item.label !== undefined)
            names.push(item.label);
        if (item.text !== undefined)
            names.push(item.text);
        for (let i = 0; i < names.length; i++) {
            const cleanName = normaliseTarget(names[i]);
            if (cleanName === cleanWanted || cleanWanted.endsWith(" " + cleanName)
                    || cleanWanted.startsWith(cleanName + " "))
                return item;
        }
        for (const child of item.children || []) {
            const match = findTarget(child, wanted);
            if (match)
                return match;
        }
        return null;
    }

    function findObjectName(item, wanted) {
        if (!item)
            return null;
        if (item.objectName === wanted)
            return item;
        const children = [];
        for (const child of item.children || [])
            children.push(child);
        for (const child of item.data || []) {
            if (children.indexOf(child) < 0)
                children.push(child);
        }
        for (const child of children) {
            const match = findObjectName(child, wanted);
            if (match)
                return match;
        }
        return null;
    }

    function targetFor(sectionId, label) {
        const section = sectionFor(sectionId);
        if (!section || !section.item)
            return null;
        const mapping = (searchTargetMap || []).find(entry => entry.section === sectionId && entry.label === label);
        if (mapping && mapping.objectName)
            return findObjectName(section.item, mapping.objectName);
        return findTarget(section.item, label);
    }

    function focusFirstControl() {
        const item = firstFocusable(body);
        if (item) item.forceActiveFocus();
    }

    function firstFocusable(item) {
        if (!item || !item.visible || !item.enabled)
            return null;
        if (item.activeFocusOnTab)
            return item;
        for (const child of item.children || []) {
            const match = firstFocusable(child);
            if (match)
                return match;
        }
        return null;
    }

    function focusTarget(sectionId, label, kind) {
        const section = sectionFor(sectionId);
        if (!section || !section.item)
            return false;
        let target = targetFor(sectionId, label);
        if (kind !== "Page" && !target)
            return false;
        while (target && target !== section.item && !target.activeFocusOnTab)
            target = target.parent;
        if (kind === "Page" && (!target || !target.activeFocusOnTab))
            target = firstFocusable(section.item);
        else if (!target || !target.activeFocusOnTab)
            target = null;
        if (!target)
            return false;
        target.forceActiveFocus();
        return true;
    }

    function jumpToTarget(sectionId, label, kind) {
        const section = sectionFor(sectionId);
        if (!section || !section.item)
            return false;
        const target = targetFor(sectionId, label);
        if (kind !== "Page" && !target)
            return false;
        const item = target || section.item;
        const point = item.mapToItem(scrollHost ? scrollHost.contentItem : root, 0, 0);
        if (scrollHost && scrollHost.contentHeight > scrollHost.height + 1)
            scrollHost.contentY = Math.max(0, Math.min(scrollHost.contentHeight - scrollHost.height, point.y - 20));
        flashSection(item);
        return true;
    }

    function sectionAt(offset) {
        if (!scrollHost || scrollHost.contentHeight <= scrollHost.height + 1)
            return "";
        let active = sectionMap.length > 0 ? sectionMap[0].id : "";
        for (const entry of sectionMap) {
            if (entry.item && entry.item.y <= offset + 34)
                active = entry.id;
        }
        return active;
    }

    function flashSection(item) {
        flashItem = item;
        const point = item.mapToItem(root, 0, 0);
        flashX = Math.max(0, point.x - 5);
        flashY = Math.max(0, point.y - 5);
        flashWidth = Math.min(root.width - flashX, item.width + 10);
        flashHeight = Math.max(30, item.height + 10);
        flashTimer.restart();
    }

    ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 20
    }

    Rectangle {
        z: 20
        x: root.flashX
        y: root.flashY
        width: root.flashWidth
        height: root.flashHeight
        visible: root.flashItem !== null
        radius: Theme.scaledRadius(7)
        color: Theme.withAlpha(Theme.blue, 0.12)
        border.color: Theme.blue
        border.width: 1
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    Timer {
        id: flashTimer
        interval: 1600
        repeat: false
        onTriggered: root.flashItem = null
    }
}
