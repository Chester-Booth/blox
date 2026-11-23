import QtQuick

// Software Qt needs a painted clip. Only this Canvas loads the bounded artwork in that mode.
Canvas {
    id: root
    property url source: ""
    property size sourceSize: Qt.size(Math.max(1, Math.ceil(width)), Math.max(1, Math.ceil(height)))
    property real cornerRadius: 0
    readonly property string loadKey: JSON.stringify([String(source), sourceSize.width, sourceSize.height])
    readonly property bool imageReady: {
        const revision = loadRevision;
        return loadedSource !== "" && loadedSource === String(source) && isImageLoaded(loadedSource);
    }
    readonly property bool failed: {
        const revision = loadRevision;
        return loadedSource !== "" && loadedSource === String(source) && isImageError(loadedSource);
    }
    readonly property string requestKey: JSON.stringify([loadKey, imageReady, width, height, cornerRadius])
    readonly property bool ready: imageReady && paintedGeneration === generation
    property string loadedSource: ""
    property int loadRevision: 0
    property int generation: 0
    property int paintedGeneration: -1
    property int pendingGeneration: -1
    property bool complete: false
    renderStrategy: Canvas.Immediate
    antialiasing: true
    visible: ready

    function invalidate() {
        ++generation;
        paintedGeneration = -1;
        requestPaint();
    }
    function reload() {
        if (!complete) return;
        invalidate();
        if (loadedSource !== "") unloadImage(loadedSource);
        loadedSource = String(source);
        if (loadedSource !== "") loadImage(loadedSource, sourceSize);
        ++loadRevision;
    }
    onLoadKeyChanged: reload()
    onRequestKeyChanged: invalidate()
    onImageLoaded: { ++loadRevision; invalidate(); }
    onAvailableChanged: { if (available) invalidate(); }
    Component.onCompleted: { complete = true; reload(); }
    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        ctx.clearRect(0, 0, width, height);
        pendingGeneration = -1;
        if (!imageReady || width <= 0 || height <= 0) return;
        // createImageData shares the image already loaded with sourceSize, preserving its aspect ratio.
        const pixels = ctx.createImageData(loadedSource);
        if (pixels.width <= 0 || pixels.height <= 0) return;
        const scale = Math.max(width / pixels.width, height / pixels.height);
        const radius = Math.min(width / 2, height / 2, Math.max(0, cornerRadius));
        ctx.beginPath();
        ctx.roundedRect(0, 0, width, height, radius, radius);
        ctx.clip();
        ctx.drawImage(pixels, (width - pixels.width * scale) / 2,
            (height - pixels.height * scale) / 2, pixels.width * scale, pixels.height * scale);
        pendingGeneration = generation;
    }
    onPainted: {
        if (imageReady && pendingGeneration === generation) paintedGeneration = pendingGeneration;
    }
}
