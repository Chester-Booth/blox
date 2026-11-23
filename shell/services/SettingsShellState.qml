import QtQuick

// Navigation state for the Settings window. Persistent values stay with their owners.
QtObject {
    id: root

    property string category: "review"
    property string page: "landing"
    property string section: ""
    property string settingsSearch: ""
    property bool searchResultsOpen: false
    property string activeSearchCategory: "all"
    property int suggestionIndex: 0
    property string selectedSearchLabel: ""
    property string selectedSearchKind: ""

    readonly property string pageTitle: root.categoryLabel(root.category)
    readonly property var categories: [
        {id: "theme", label: "Theme", icon: "palette"},
        {id: "bar", label: "Bar", icon: "app-window"},
        {id: "bar-items", label: "Bar items", icon: "squares-four"},
        {id: "colours", label: "Colours & type", icon: "palette"},
        {id: "windows", label: "Windows & cursor", icon: "gear-six"},
        {id: "widgets", label: "Widgets", icon: "squares-four"},
        {id: "targets", label: "Targets & files", icon: "code"},
        {id: "review", label: "Apply & review", icon: "arrows-clockwise"}
    ]

    readonly property var searchIndex: [
        {category: "theme", page: "landing", section: "theme-name", label: "Theme name", terms: "theme name internal id"},
        {category: "theme", page: "landing", section: "style", label: "Theme roundness", terms: "style shape round rounded roundness corners"},
        {category: "theme", page: "landing", section: "style", label: "Slightly round corners", terms: "slightly small round"},
        {category: "theme", page: "landing", section: "style", label: "Square corners", terms: "square crisp"},
        {category: "theme", page: "landing", section: "density", label: "Density", terms: "density spacing"},
        {category: "theme", page: "landing", section: "density", label: "Comfortable density", terms: "comfortable balanced"},
        {category: "theme", page: "landing", section: "density", label: "Spacious density", terms: "spacious more room"},
        {category: "theme", page: "landing", section: "wallpaper", label: "Wallpaper fit", terms: "wallpaper fit cover contain tile"},
        {category: "theme", page: "landing", section: "wallpaper", label: "Import wallpaper", terms: "import file"},
        {category: "theme", page: "landing", section: "wallpaper", label: "Wallpaper library", terms: "built in imported library"},
        {category: "theme", page: "advanced", section: "shape-density", label: "Roundness scale", terms: "advanced style shape roundness radius"},
        {category: "theme", page: "advanced", section: "shape-density", label: "Density scale", terms: "advanced density spacing"},
        {category: "theme", page: "advanced", section: "shape-density", label: "Window gap", terms: "window gap automatic"},
        {category: "bar", page: "landing", section: "bar-settings", label: "Bar settings", terms: "bar settings"},
        {category: "bar", page: "landing", section: "bar-settings", label: "Bar position", terms: "position left right top bottom"},
        {category: "bar", page: "landing", section: "bar-settings", label: "Separate bar groups", terms: "separate groups"},
        {category: "bar", page: "landing", section: "bar-settings", label: "Bar border", terms: "border"},
        {category: "bar", page: "landing", section: "bar-settings", label: "Edge inset", terms: "edge inset"},
        {category: "bar", page: "landing", section: "osd", label: "OSD and notifications", terms: "osd notifications notification"},
        {category: "bar", page: "landing", section: "osd", label: "OSD position", terms: "osd position"},
        {category: "bar", page: "landing", section: "osd", label: "Notification position", terms: "notification position"},
        {category: "bar", page: "landing", section: "bar-spacing", label: "Bar roundness", terms: "bar spacing roundness"},
        {category: "bar", page: "landing", section: "bar-spacing", label: "Automatic bar roundness", terms: "automatic bar roundness"},
        {category: "bar", page: "landing", section: "bar-spacing", label: "Bar density", terms: "bar density"},
        {category: "bar", page: "landing", section: "bar-spacing", label: "Automatic bar density", terms: "automatic bar density"},
        {category: "bar", page: "advanced", section: "position-offsets", label: "Bar inset", terms: "advanced inset bar edge"},
        {category: "bar", page: "advanced", section: "position-offsets", label: "OSD horizontal offset", terms: "osd horizontal offset x"},
        {category: "bar", page: "advanced", section: "position-offsets", label: "OSD vertical offset", terms: "osd vertical offset y"},
        {category: "bar", page: "advanced", section: "position-offsets", label: "Notification horizontal offset", terms: "notification horizontal offset x"},
        {category: "bar", page: "advanced", section: "position-offsets", label: "Notification vertical offset", terms: "notification vertical offset y"},
        {category: "bar", page: "advanced", section: "window-shape-density", label: "Window roundness", terms: "window shape roundness radius"},
        {category: "bar", page: "advanced", section: "window-shape-density", label: "Window density", terms: "window density spacing"},
        {category: "bar", page: "advanced", section: "window-shape-density", label: "Window gap", terms: "window gap"},
        {category: "bar", page: "advanced", section: "window-shape-density", label: "Automatic window gap", terms: "automatic gap"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Bar items", terms: "bar items add reset order start centre end hidden edit visibility orientation numeric"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Power", terms: "power"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Notes", terms: "notes"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Workspaces", terms: "workspaces workspace"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Clock", terms: "clock time"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Active window title", terms: "active window title"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Battery", terms: "battery"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Tray", terms: "tray"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Notifications", terms: "notifications notification"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Wi-Fi", terms: "wifi network wireless"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Sound", terms: "sound audio volume"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Privacy", terms: "privacy"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Awake", terms: "awake caffeine"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Display", terms: "display brightness"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Bluetooth", terms: "bluetooth bt"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Updates", terms: "updates update"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Fan", terms: "fan"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "GPU", terms: "gpu graphics"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Application tray", terms: "application tray"},
        {category: "bar-items", page: "landing", section: "bar-items", label: "Touchpad", terms: "touchpad"},
        {category: "colours", page: "landing", section: "semantic", label: "Semantic palette", terms: "semantic palette colours"},
        {category: "colours", page: "landing", section: "semantic", label: "Background colour", terms: "background"},
        {category: "colours", page: "landing", section: "semantic", label: "Surface colour", terms: "surface"},
        {category: "colours", page: "landing", section: "semantic", label: "Alternate surface colour", terms: "surface alt"},
        {category: "colours", page: "landing", section: "semantic", label: "Foreground colour", terms: "foreground"},
        {category: "colours", page: "landing", section: "semantic", label: "Muted colour", terms: "muted"},
        {category: "colours", page: "landing", section: "semantic", label: "Accent colour", terms: "accent"},
        {category: "colours", page: "landing", section: "semantic", label: "Danger colour", terms: "danger"},
        {category: "colours", page: "landing", section: "semantic", label: "Success colour", terms: "success"},
        {category: "colours", page: "landing", section: "semantic", label: "Warning colour", terms: "warning"},
        {category: "colours", page: "landing", section: "semantic", label: "Info colour", terms: "info"},
        {category: "colours", page: "landing", section: "semantic", label: "Mauve colour", terms: "mauve"},
        {category: "colours", page: "landing", section: "semantic", label: "Teal colour", terms: "teal"},
        {category: "colours", page: "landing", section: "semantic", label: "Selection background colour", terms: "selection background"},
        {category: "colours", page: "landing", section: "semantic", label: "Selection foreground colour", terms: "selection foreground"},
        {category: "colours", page: "landing", section: "semantic", label: "Border colour", terms: "border"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal palette", terms: "terminal palette ansi"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 0", terms: "color0 colour0 ansi 0"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 1", terms: "color1 colour1 ansi 1"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 2", terms: "color2 colour2 ansi 2"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 3", terms: "color3 colour3 ansi 3"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 4", terms: "color4 colour4 ansi 4"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 5", terms: "color5 colour5 ansi 5"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 6", terms: "color6 colour6 ansi 6"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 7", terms: "color7 colour7 ansi 7"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 8", terms: "color8 colour8 ansi 8"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 9", terms: "color9 colour9 ansi 9"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 10", terms: "color10 colour10 ansi 10"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 11", terms: "color11 colour11 ansi 11"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 12", terms: "color12 colour12 ansi 12"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 13", terms: "color13 colour13 ansi 13"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 14", terms: "color14 colour14 ansi 14"},
        {category: "colours", page: "landing", section: "terminal", label: "Terminal colour 15", terms: "color15 colour15 ansi 15"},
        {category: "colours", page: "landing", section: "fonts", label: "Fonts", terms: "font fonts typeface family picker"},
        {category: "colours", page: "landing", section: "fonts", label: "UI font", terms: "ui interface"},
        {category: "colours", page: "landing", section: "fonts", label: "Mono font", terms: "mono monospace code"},
        {category: "colours", page: "landing", section: "fonts", label: "Panel font", terms: "panel bar"},
        {category: "colours", page: "landing", section: "font-samples", label: "Font samples", terms: "font samples interface panel preview"},
        {category: "colours", page: "landing", section: "icons", label: "Icon theme", terms: "icon icons theme adwaita papirus hicolor"},
        {category: "windows", page: "landing", section: "cursor", label: "Follow theme roundness", terms: "cursor pointer follow roundness"},
        {category: "windows", page: "landing", section: "cursor", label: "Cursor shape", terms: "cursor shape classic modern"},
        {category: "windows", page: "landing", section: "cursor", label: "Cursor size", terms: "cursor size"},
        {category: "windows", page: "landing", section: "cursor", label: "Pointer direction", terms: "pointer direction right left"},
        {category: "windows", page: "landing", section: "window", label: "Inactive opacity", terms: "window appearance inactive opacity"},
        {category: "windows", page: "landing", section: "window", label: "Border size", terms: "window border size"},
        {category: "windows", page: "landing", section: "window-preview", label: "Preview", terms: "preview cursor window"},
        {category: "widgets", page: "landing", section: "widgets", label: "Widgets", terms: "widgets list edit new import export enabled disabled"},
        {category: "widgets", page: "landing", section: "widgets", label: "Clock widget", terms: "clock time"},
        {category: "widgets", page: "landing", section: "widgets", label: "Music widget", terms: "music mpris"},
        {category: "widgets", page: "landing", section: "widgets", label: "System widget", terms: "system cpu memory graph"},
        {category: "widgets", page: "landing", section: "widgets", label: "Network widget", terms: "network traffic"},
        {category: "widgets", page: "landing", section: "widgets", label: "Calendar widget", terms: "calendar"},
        {category: "widgets", page: "landing", section: "widgets", label: "Notes widget", terms: "notes"},
        {category: "widgets", page: "landing", section: "widgets", label: "Files widget", terms: "files directory"},
        {category: "widgets", page: "landing", section: "widgets", label: "Shortcuts widget", terms: "shortcuts launch"},
        {category: "widgets", page: "landing", section: "widgets", label: "Weather widget", terms: "weather location"},
        {category: "widgets", page: "landing", section: "widgets", label: "Terminal widget", terms: "terminal command"},
        {category: "widgets", page: "landing", section: "widgets", label: "Command output widget", terms: "command output widget text script"},
        {category: "widgets", page: "landing", section: "widgets", label: "QML widget", terms: "qml custom sdk"},
        {category: "widgets", page: "landing", section: "widgets", label: "Background opacity", terms: "background opacity transparency"},
        {category: "widgets", page: "landing", section: "widgets", label: "Workspace assignment", terms: "workspace ranges named special"},
        {category: "widgets", page: "landing", section: "widgets", label: "Fullscreen", terms: "fullscreen layout scrollbars"},
        {category: "targets", page: "landing", section: "targets", label: "Theme targets", terms: "theme targets manage outputs"},
        {category: "targets", page: "landing", section: "targets", label: "Target quickshell", terms: "target quickshell"},
        {category: "targets", page: "landing", section: "targets", label: "Target widgets", terms: "target widgets"},
        {category: "targets", page: "landing", section: "targets", label: "Target gtk", terms: "target gtk"},
        {category: "targets", page: "landing", section: "targets", label: "Target helium", terms: "target helium browser"},
        {category: "targets", page: "landing", section: "targets", label: "Target chromium", terms: "target chromium browser"},
        {category: "targets", page: "landing", section: "targets", label: "Target cursor", terms: "target cursor pointer"},
        {category: "targets", page: "landing", section: "targets", label: "Target wallpaper", terms: "target wallpaper"},
        {category: "targets", page: "landing", section: "targets", label: "Target kitty", terms: "target kitty terminal"},
        {category: "targets", page: "landing", section: "targets", label: "Target hyprland", terms: "target hyprland"},
        {category: "targets", page: "landing", section: "targets", label: "Target hyprlock", terms: "target hyprlock"},
        {category: "targets", page: "landing", section: "targets", label: "Target btop", terms: "target btop"},
        {category: "targets", page: "landing", section: "targets", label: "Target micro", terms: "target micro editor"},
        {category: "targets", page: "landing", section: "targets", label: "Target glow", terms: "target glow"},
        {category: "targets", page: "landing", section: "targets", label: "Target code", terms: "target code visual studio code vscode"},
        {category: "targets", page: "landing", section: "targets", label: "Target cursor_editor", terms: "target cursor editor cursor_editor"},
        {category: "targets", page: "landing", section: "targets", label: "Target t3code", terms: "target t3code"},
        {category: "targets", page: "landing", section: "targets", label: "Target zed", terms: "target zed"},
        {category: "targets", page: "landing", section: "targets", label: "Target stylus", terms: "target stylus"},
        {category: "targets", page: "landing", section: "targets", label: "Target obsidian", terms: "target obsidian"},
        {category: "targets", page: "landing", section: "targets", label: "Target powerlevel10k", terms: "target powerlevel10k"},
        {category: "targets", page: "landing", section: "targets", label: "Target sddm", terms: "target sddm unavailable"},
        {category: "targets", page: "landing", section: "targets", label: "Target grub", terms: "target grub unavailable"},
        {category: "targets", page: "landing", section: "generated-files", label: "Generated files", terms: "generated files download archive output"},
        {category: "targets", page: "landing", section: "overrides", label: "Target colour overrides", terms: "target specific colour overrides inherit semantic reset undo"},
        {category: "targets", page: "landing", section: "overrides", label: "GTK background override", terms: "gtk background override"},
        {category: "targets", page: "landing", section: "overrides", label: "GTK foreground override", terms: "gtk foreground override"},
        {category: "targets", page: "landing", section: "overrides", label: "GTK accent override", terms: "gtk accent override"},
        {category: "targets", page: "landing", section: "overrides", label: "GTK border override", terms: "gtk border override"},
        {category: "targets", page: "landing", section: "overrides", label: "Hyprlock background override", terms: "hyprlock background override"},
        {category: "targets", page: "landing", section: "overrides", label: "Hyprlock foreground override", terms: "hyprlock foreground override"},
        {category: "targets", page: "landing", section: "overrides", label: "Hyprlock accent override", terms: "hyprlock accent override"},
        {category: "targets", page: "landing", section: "overrides", label: "Hyprlock border override", terms: "hyprlock border override"},
        {category: "review", page: "landing", section: "apply-review", label: "Apply & review", terms: "apply theme review result outcome retry rollback restart manual setup"}
    ]

    function categoryLabel(id) {
        const match = categories.find(entry => entry.id === id);
        return match ? match.label : id;
    }

    function baseSectionsFor(id) {
        const values = {
            "theme": [{id: "theme-name", label: "Theme name"}, {id: "style", label: "Style"}, {id: "density", label: "Density"}, {id: "wallpaper", label: "Wallpaper"}],
            "bar": [{id: "bar-settings", label: "Bar settings"}, {id: "osd", label: "OSD and notifications"}, {id: "bar-spacing", label: "Bar spacing"}],
            "bar-items": [{id: "bar-items", label: "Bar items"}],
            "colours": [{id: "semantic", label: "Semantic palette"}, {id: "terminal", label: "Terminal palette"}, {id: "fonts", label: "Fonts"}, {id: "font-samples", label: "Font samples"}, {id: "icons", label: "Icon theme"}],
            "windows": [{id: "cursor", label: "Cursor"}, {id: "window", label: "Window appearance"}, {id: "window-preview", label: "Preview"}],
            "widgets": [{id: "widgets", label: "Widgets"}],
            "targets": [{id: "targets", label: "Theme targets"}, {id: "generated-files", label: "Generated files"}, {id: "overrides", label: "Target colour overrides"}]
        };
        return values[id] || [];
    }

    function advancedSectionsFor(id) {
        const values = {
            "theme": [{id: "shape-density", label: "Advanced style"}],
            "bar": [{id: "position-offsets", label: "Position offsets"}, {id: "window-shape-density", label: "Window shape & density"}]
        };
        return values[id] || [];
    }

    function sectionsFor(id) {
        if (id === "theme" && page === "advanced")
            return advancedSectionsFor(id);
        if (id === "bar" && page === "advanced")
            return advancedSectionsFor(id);
        return baseSectionsFor(id);
    }

    function sectionLabel(categoryId, sectionId) {
        const match = baseSectionsFor(categoryId).concat(advancedSectionsFor(categoryId))
            .find(entry => entry.id === sectionId);
        return match ? match.label : sectionId;
    }

    function searchTextMatches(text, query) {
        const words = String(query || "").trim().toLowerCase().split(/\s+/).filter(word => word.length > 0);
        const haystack = String(text || "").toLowerCase();
        return words.length > 0 && words.every(word => {
            if (/^\d+$/.test(word))
                return new RegExp("(^|[^0-9])" + word + "([^0-9]|$)").test(haystack);
            return haystack.indexOf(word) >= 0;
        });
    }

    function searchSectionsFor(id) {
        const all = baseSectionsFor(id).concat(advancedSectionsFor(id));
        const query = settingsSearch.trim().toLowerCase();
        if (!query)
            return all;
        const category = categories.find(entry => entry.id === id);
        if (category && searchTextMatches(category.label, query))
            return all;
        return all.filter(section => searchTextMatches(section.label, query)
            || searchIndex.some(entry => entry.category === id && entry.section === section.id
                && searchTextMatches(entry.label + " " + entry.terms, query)));
    }

    function visibleCategories() {
        // Keep the sidebar stable while search filters sections and results.
        return categories;
    }

    function filteredSectionsFor(id) {
        return settingsSearch.trim().length > 0 ? searchSectionsFor(id) : sectionsFor(id);
    }

    function searchResults() {
        const query = settingsSearch.trim().toLowerCase();
        if (!query)
            return [];
        const matches = [];
        function append(entry) {
            const duplicate = matches.some(current => current.category === entry.category
                && current.page === entry.page && current.section === entry.section
                && current.label === entry.label);
            if (!duplicate)
                matches.push(entry);
        }
        categories.forEach(category => {
            if (!searchTextMatches(category.label, query))
                return;
            const first = baseSectionsFor(category.id)[0];
            if (first)
                append({category: category.id, page: "landing", section: first.id,
                    label: category.label, kind: "Page", detail: "Open the " + category.label + " settings page"});
        });
        searchIndex.forEach(entry => {
            if (searchTextMatches(entry.label + " " + entry.terms + " " + sectionLabel(entry.category, entry.section), query)) {
                append(Object.assign({}, entry, {
                    kind: !entry.section ? "Page" : entry.page === "advanced" ? "Advanced control" : "Setting",
                    detail: resultDetail(entry)
                }));
            }
        });
        return matches.sort((left, right) => resultRank(left, query) - resultRank(right, query));
    }

    function resultRank(entry, query) {
        const label = String(entry.label || "").toLowerCase();
        const category = categoryLabel(entry.category).toLowerCase();
        if (label === query)
            return 0;
        if (category.startsWith(query))
            return 1;
        if (label.startsWith(query))
            return 2;
        return 3;
    }

    function suggestionResults() {
        return searchResults().slice(0, 4);
    }

    function resultDetail(entry) {
        if (entry.category === "theme" && entry.section === "style")
            return "Shape preset and corner roundness";
        if (entry.category === "theme" && entry.page === "advanced")
            return "Fine roundness, radius and density controls";
        if (entry.category === "bar" && entry.section === "bar-spacing")
            return "Bar roundness and density";
        if (entry.category === "bar" && entry.page === "advanced")
            return "Window roundness, gaps and position offsets";
        if (entry.category === "windows" && entry.section === "cursor")
            return "Cursor shape, direction and size";
        return String(entry.terms || "").split(" ").slice(0, 7).join(" ");
    }

    function openCategory(id) {
        searchResultsOpen = false;
        selectedSearchLabel = "";
        selectedSearchKind = "";
        const sections = settingsSearch.trim().length > 0 ? filteredSectionsFor(id) : baseSectionsFor(id);
        const first = sections.length > 0 ? sections[0] : null;
        category = id;
        page = first && isAdvancedSection(id, first.id) ? "advanced" : "landing";
        section = settingsSearch.trim().length > 0 && first ? first.id : "";
    }

    function openSection(categoryId, sectionId) {
        searchResultsOpen = false;
        selectedSearchLabel = "";
        selectedSearchKind = "";
        category = categoryId;
        page = isAdvancedSection(categoryId, sectionId) ? "advanced" : "landing";
        section = sectionId;
    }

    function openSearchResult(result) {
        if (!result)
            return;
        searchResultsOpen = false;
        if (!result.section) {
            selectedSearchLabel = result.label || "";
            selectedSearchKind = result.kind || "Page";
            category = result.category;
            page = result.page || "landing";
            section = "";
            return;
        }
        openSection(result.category, result.section);
        selectedSearchLabel = result.label || "";
        selectedSearchKind = result.kind || "Setting";
    }

    function openAllSearchResults() {
        if (settingsSearch.trim().length === 0)
            return false;
        const matches = searchResults();
        if (matches.length === 1) {
            openSearchResult(matches[0]);
            return true;
        }
        activeSearchCategory = "all";
        searchResultsOpen = true;
        return true;
    }

    function acceptSearch() {
        const suggestions = suggestionResults();
        if (suggestions.length > 0) {
            openSearchResult(suggestions[Math.min(suggestionIndex, suggestions.length - 1)]);
            return true;
        }
        return openAllSearchResults();
    }

    function breadcrumbs() {
        if (searchResultsOpen)
            return [
                {label: "Settings", category: "theme", page: "landing", section: ""},
                {label: "Search", category: category, page: page, section: ""},
                {label: settingsSearch, category: category, page: page, section: ""}
            ];
        if (category === "bar" && page === "advanced")
            return [
                {label: "Bar", category: "bar", page: "landing", section: ""},
                {label: "Advanced", category: "bar", page: "advanced", section: "position-offsets"}
            ];
        if (category === "theme" && page === "advanced")
            return [
                {label: "Settings", category: "theme", page: "landing", section: ""},
                {label: "Theme", category: "theme", page: "landing", section: ""},
                {label: "Style", category: "theme", page: "landing", section: "style"},
                {label: "Advanced", category: "theme", page: "advanced", section: "shape-density"}
            ];
        return [
            {label: "Settings", category: "theme", page: "landing", section: ""},
            {label: categoryLabel(category), category: category, page: "landing", section: ""}
        ];
    }

    function openBreadcrumb(index) {
        const crumbs = breadcrumbs();
        if (index < 0 || index >= crumbs.length)
            return;
        const destination = crumbs[index];
        selectedSearchLabel = "";
        selectedSearchKind = "";
        if (destination.page === "advanced") {
            category = destination.category;
            page = "advanced";
            section = destination.section;
        } else {
            category = destination.category;
            page = "landing";
            section = destination.section;
        }
        searchResultsOpen = false;
    }

    function isAdvancedSection(categoryId, sectionId) {
        return advancedSectionsFor(categoryId).some(sectionEntry => sectionEntry.id === sectionId);
    }
}
