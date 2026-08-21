import QtQuick

QtObject {
    id: root

    required property var theme
    required property ThemeDefaults defaults

    function reset() {
        const fallback = root.defaults.themeDocument();
        const colours = fallback.colours;
        const fonts = fallback.fonts;
        const shell = fallback.shell;
        theme.previewActive = false;
        theme.previewThemeId = "";
        theme.themeId = fallback.id;
        theme.activeThemeId = theme.themeId;
        theme.variant = fallback.variant;
        theme.background = colours.background;
        theme.surface = colours.surface;
        theme.surfaceAlt = colours.surface_alt;
        theme.foreground = colours.foreground;
        theme.muted = colours.muted;
        theme.red = colours.red;
        theme.green = colours.green;
        theme.yellow = colours.yellow;
        theme.accent = colours.accent;
        theme.blue = colours.blue;
        theme.mauve = colours.mauve;
        theme.teal = colours.teal;
        theme.selectionForeground = colours.selection_foreground;
        theme.border = colours.border;
        theme.fontFamily = fonts.panel;
        theme.monoFontFamily = fonts.mono;
        theme.bodyFontFamily = fonts.ui;
        theme.barPosition = shell.bar.position;
        theme.barItems = theme.builtinBarItems();
        theme.osdPosition = shell.osd.position;
        theme.osdOffsetX = shell.osd.offset_x;
        theme.osdOffsetY = shell.osd.offset_y;
        theme.notificationPosition = shell.notifications.position;
        theme.notificationOffsetX = shell.notifications.offset_x;
        theme.notificationOffsetY = shell.notifications.offset_y;
        return theme.themeId;
    }

    function resetWidgets() {
        const profile = root.defaults.widgetProfile();
        theme.widgetProfile = root.defaults.document.widgets.profile;
        theme.widgetOpacity = profile.opacity;
        theme.widgetPadding = profile.padding;
        theme.widgetRadius = profile.radius;
        theme.widgetFontSize = profile.font_size;
        theme.widgetItems = [];
        return theme.widgetProfile;
    }

    function loadWidgets(raw) {
        try {
            const data = JSON.parse(raw);
            if (data.schema_version !== 1 || !data.profile)
                throw new Error("unsupported or incomplete widget profile");

            theme.widgetProfile = data.profile;
            theme.widgetOpacity = data.opacity;
            theme.widgetPadding = data.padding;
            theme.widgetRadius = data.radius;
            theme.widgetFontSize = data.font_size;
            theme.widgetItems = data.items || [];
            return true;
        } catch (error) {
            console.warn("[blox.theme] rejected widget profile: " + error);
            return false;
        }
    }

    function loadJson(raw) {
        try {
            const data = JSON.parse(raw);
            if (data.schema_version !== 1 || !data.id || !data.colours || !data.compatibility || !data.fonts)
                throw new Error("unsupported or incomplete theme document");

            theme.themeId = data.id;
            theme.activeThemeId = data.id;
            theme.variant = data.variant;
            theme.background = data.colours.background;
            theme.surface = data.colours.surface;
            theme.surfaceAlt = data.colours.surface_alt;
            theme.foreground = data.colours.foreground;
            theme.muted = data.colours.muted;
            theme.red = data.compatibility.red;
            theme.green = data.compatibility.green;
            theme.yellow = data.compatibility.yellow;
            theme.accent = data.colours.accent;
            theme.blue = data.compatibility.blue;
            theme.mauve = data.compatibility.mauve;
            theme.teal = data.compatibility.teal;
            theme.selectionForeground = data.colours.selection_foreground;
            theme.border = data.colours.border;
            theme.fontFamily = data.fonts.panel;
            theme.monoFontFamily = data.fonts.mono;
            theme.bodyFontFamily = data.fonts.ui;
            loadShell(data.shell);
            if (data.widgets)
                loadWidgetSource(data.widgets.profile);

            return true;
        } catch (error) {
            console.warn("[blox.theme] rejected generated theme: " + error);
            return false;
        }
    }

    function loadWidgetSource(profile) {
        const resolved = root.defaults.widgetProfile(profile);
        if (!resolved)
            return false;

        return loadWidgets(JSON.stringify({
            "schema_version": 1,
            "profile": profile || "minimal",
            "opacity": resolved.opacity,
            "margin": resolved.margin,
            "padding": resolved.padding,
            "radius": resolved.radius,
            "font_size": resolved.font_size
        }));
    }

    function loadShell(shell) {
        const fallback = root.defaults.themeDocument().shell;
        const data = shell || { };
        const bar = data.bar || fallback.bar;
        const osd = data.osd || fallback.osd;
        const notifications = data.notifications || fallback.notifications;
        theme.barPosition = bar.position;
        theme.barItems = defaults.resolvedBarItems(data.bar && data.bar.items ? data.bar.items : []);
        theme.osdPosition = osd.position;
        theme.osdOffsetX = osd.offset_x;
        theme.osdOffsetY = osd.offset_y;
        theme.notificationPosition = notifications.position;
        theme.notificationOffsetX = notifications.offset_x;
        theme.notificationOffsetY = notifications.offset_y;
        return true;
    }

    function loadActiveIdentity(raw) {
        try {
            const data = JSON.parse(raw);
            if (data.schema_version !== 1 || !data.id)
                throw new Error("unsupported or incomplete theme document");

            theme.activeThemeId = data.id;
            return true;
        } catch (error) {
            console.warn("[blox.theme] rejected active theme identity: " + error);
            return false;
        }
    }

    function previewSource(raw) {
        try {
            const data = typeof raw === "string" ? JSON.parse(raw) : raw;
            if (data.schema_version !== 1 || !data.id || !data.colours || !data.fonts)
                throw new Error("unsupported or incomplete source theme");

            theme.previewActive = true;
            theme.previewThemeId = data.id;
            theme.themeId = data.id;
            theme.variant = data.variant;
            theme.background = data.colours.background;
            theme.surface = data.colours.surface;
            theme.surfaceAlt = data.colours.surface_alt;
            theme.foreground = data.colours.foreground;
            theme.muted = data.colours.muted;
            theme.red = data.colours.danger;
            theme.green = data.colours.success;
            theme.yellow = data.colours.warning;
            theme.accent = data.colours.accent;
            theme.blue = data.colours.info;
            theme.mauve = data.colours.mauve;
            theme.teal = data.colours.teal;
            theme.selectionForeground = data.colours.selection_foreground;
            theme.border = data.colours.border;
            theme.fontFamily = data.fonts.panel;
            theme.monoFontFamily = data.fonts.mono;
            theme.bodyFontFamily = data.fonts.ui;
            loadShell(data.shell);
            loadWidgetSource(data.widgets ? data.widgets.profile : "minimal");
            if (data.widgets && data.widgets.items)
                theme.widgetItems = data.widgets.items;

            return true;
        } catch (error) {
            console.warn("[blox.theme] rejected source preview: " + error);
            return false;
        }
    }

}
