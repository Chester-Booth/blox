// Standard menu actions use the same regular Phosphor icons as the Blox controls.
function iconForEntry(entry) {
    const names = {
        "document-new": "plus", "list-add": "plus", "plus": "plus",
        "application-exit": "sign-out", "window-close": "x",
        "document-open": "folder-open", "document-save": "floppy-disk",
        "edit-copy": "copy", "edit-paste": "clipboard-text", "edit-delete": "trash",
        "preferences-system": "gear-six", "preferences-other": "gear-six",
        "view-refresh": "arrows-clockwise"
    };
    const source = String(entry.icon || "");
    const name = source.split("/").pop().split(/[?#]/)[0].replace(/\.(svg|png)$/i, "");
    if (names[name]) return names[name];
    if (entry.hasChildren || entry.buttonType) return "";
    const actions = {
        "new chat": "plus", "new conversation": "plus", "new window": "plus", "new tab": "plus",
        "quit": "sign-out", "exit": "sign-out", "close": "x",
        "settings": "gear-six", "preferences": "gear-six",
        "copy": "copy", "paste": "clipboard-text", "delete": "trash", "refresh": "arrows-clockwise"
    };
    const label = String(entry.text || "").replace(/&/g, "").replace(/(?:\.\.\.|…)$/, "").trim().toLowerCase();
    return actions[label] || "";
}
