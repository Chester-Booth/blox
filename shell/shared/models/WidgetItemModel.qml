import QtQuick
import Blox.Widgets 1.0 as Widgets

// Keep Repeater delegates attached to widget IDs across profile reloads and edits.
ListModel {
    id: root
    property var items: []

    function reconcile() {
        const desired = items || [];
        const retained = new Set(desired.map(item => item.id));
        for (let index = count - 1; index >= 0; --index)
            if (!retained.has(get(index).widgetId)) remove(index);
        for (let index = 0; index < desired.length; ++index) {
            const item = desired[index];
            const document = Widgets.JsonValue.stringify(item);
            let current = index;
            while (current < count && get(current).widgetId !== item.id) ++current;
            if (current === count) insert(index, {widgetId: item.id, document: document});
            else {
                if (current !== index) move(current, index, 1);
                if (get(index).document !== document) setProperty(index, "document", document);
            }
        }
    }
    onItemsChanged: reconcile()
    Component.onCompleted: reconcile()
}
