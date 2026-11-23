"""Offscreen raster bounds and appearance checks for the production Image bindings."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SITES = (
    ('wallpaper-first', 'shell/modules/Wallpaper.qml', 0),
    ('wallpaper-second', 'shell/modules/Wallpaper.qml', 1),
    ('theme-preview', 'shell/modules/SettingsThemePreview.qml', 0),
    ('theme-card', 'shell/modules/SettingsThemePage.qml', 0),
    ('music', 'widgets/qml/Blox/Widgets/Native/MusicView.qml', 0),
)


def bindings():
    return [(name, re.findall(r'sourceSize: (.*?)(?=\n\s*[\w.]+:)',
             (ROOT / path).read_text(), re.S)[index].strip()) for name, path, index in SITES]


def worker(directory, dpr):
    from PySide6.QtCore import QObject, QUrl
    import time
    from PySide6.QtGui import QColor, QGuiApplication, QImage, QLinearGradient, QPainter
    from PySide6.QtQml import QQmlComponent, QQmlEngine
    from PySide6.QtQuick import QQuickRenderControl, QQuickRenderTarget, QQuickWindow
    app = QGuiApplication([])
    QQuickWindow.setSceneGraphBackend('software')
    control = QQuickRenderControl()
    window = QQuickWindow(control)
    engine = QQmlEngine()
    directory = Path(directory)
    for name, width, height in [('wide', 2400, 800), ('tall', 800, 2400), ('tile', 24, 18)]:
        image = QImage(width, height, QImage.Format_ARGB32_Premultiplied)
        painter = QPainter(image)
        gradient = QLinearGradient(0, 0, width, height)
        gradient.setColorAt(0, QColor('#f03020'))
        gradient.setColorAt(0.5, QColor('#20d040'))
        gradient.setColorAt(1, QColor('#2030f0'))
        painter.fillRect(image.rect(), gradient)
        painter.end()
        assert image.save(str(directory / (name + '.png')))

    def create(binding, path, fill, width=240, height=160, asynchronous=False):
        component = QQmlComponent(engine)
        component.setData(('''import QtQuick
import QtQuick.Window
Item { id: wallpaperWindow; width: %d; height: %d
 property real outputScale: %s
 property real attachedScreenDpr: Screen.devicePixelRatio
 Image { property int statusValue: status; objectName: "picture"; anchors.fill: parent; source: %s
 fillMode: Image.%s; smooth: true; cache: false
 asynchronous: %s; retainWhileLoading: true
 %s
 }
}''' % (width, height, dpr, json.dumps(QUrl.fromLocalFile(str(path)).toString()), fill,
        str(asynchronous).lower(), ('sourceSize: ' + binding) if binding else '')).encode(), QUrl())
        root = component.create()
        assert root, str(component.errors())
        root.setParentItem(window.contentItem())
        picture = root.findChild(QObject, 'picture')
        assert root.property('attachedScreenDpr') == dpr
        for _ in range(1000):
            app.processEvents()
            if picture.property('statusValue') == 1:
                break
        assert picture.property('statusValue') == 1, 'Image did not become Ready'
        return root, picture, component

    def render(root):
        width, height = int(root.width()), int(root.height())
        window.setGeometry(0, 0, width, height)
        image = QImage(round(width * dpr), round(height * dpr), QImage.Format_ARGB32_Premultiplied)
        image.fill(0)
        target = QQuickRenderTarget.fromPaintDevice(image)
        target.setDevicePixelRatio(dpr)
        window.setRenderTarget(target)
        for _ in range(3):
            app.processEvents()
            control.polishItems()
            control.sync()
            control.render()
        assert not window.isVisible()
        return image

    def dispose(root):
        root.setParentItem(None)
        root.deleteLater()
        app.sendPostedEvents()
        app.processEvents()

    def compare(reference, bounded):
        # Broad gradients reveal wrong crop/fit geometry without requiring identical resampling.
        maximum = 0
        for yi in range(1, 20):
            for xi in range(1, 20):
                x, y = reference.width() * xi // 20, reference.height() * yi // 20
                a, b = reference.pixelColor(x, y), bounded.pixelColor(x, y)
                maximum = max(maximum, *(abs(a.getRgb()[i] - b.getRgb()[i]) for i in range(4)))
        assert maximum <= 5, ('Raster appearance changed', maximum)
        return maximum

    results = []
    for name, binding in bindings():
        for shape in ('wide', 'tall'):
            for fill in ('PreserveAspectCrop', 'PreserveAspectFit'):
                path = directory / (shape + '.png')
                original, _, original_component = create('', path, fill)
                reference = render(original)
                dispose(original)
                root, picture, component = create(binding, path, fill)
                result = render(root)
                error = compare(reference, result)
                # Qt may retain the expanded crop raster. Both modes stay within that aspect-aware bound.
                source_width, source_height = (2400, 800) if shape == 'wide' else (800, 2400)
                scale = max(
                    240 * dpr / source_width, 160 * dpr / source_height)
                assert picture.property('implicitWidth') <= source_width * scale + 1
                assert picture.property('implicitHeight') <= source_height * scale + 1
                assert picture.property('sourceSize').width() == 240 * dpr
                assert picture.property('sourceSize').height() == 160 * dpr
                root.setWidth(360)
                root.setHeight(220)
                resized = render(root)
                reference_root, _, resized_component = create('', path, fill, width=360, height=220)
                compare(render(reference_root), resized)
                dispose(reference_root)
                assert picture.property('sourceSize').width() == 360 * dpr
                assert picture.property('sourceSize').height() == 220 * dpr
                scale = max(
                    360 * dpr / source_width, 220 * dpr / source_height)
                assert picture.property('implicitWidth') <= source_width * scale + 1
                assert picture.property('implicitHeight') <= source_height * scale + 1
                dispose(root)
                results.append({'site': name, 'shape': shape, 'fill': fill, 'sampleError': error})
        if name.startswith('wallpaper'):
            original, _, original_component = create('', directory / 'tile.png', 'Tile')
            reference = render(original)
            dispose(original)
            root, picture, component = create(binding, directory / 'tile.png', 'Tile')
            assert picture.property('implicitWidth') == 24
            assert picture.property('implicitHeight') == 18
            assert compare(reference, render(root)) == 0
            root.setWidth(320)
            render(root)
            assert picture.property('implicitWidth') == 24
            dispose(root)
    # Exercise the real native view, including its readiness contract, rather than a copied Image.
    component = QQmlComponent(engine)
    component.setData(('''import QtQuick
import %s as Native
import %s as Widgets
Item { id: fixture; width: 380; height: 280
 property real roundness: 0
 Widgets.WidgetTheme { id: widgetTheme; radiusScale: fixture.roundness }
 property string artUrl: %s
 property bool watchReadiness: false
 property int readinessDrops: 0
 property bool ready: music.contentReady
 Native.MusicView { id: music; objectName: "music"; anchors.fill: parent; theme: widgetTheme
   settings: ({style: "compact", showArtwork: true})
   snapshot: ({generation: 1, state: "ready", value: {artUrl: parent.artUrl}})
   onContentReadyChanged: if (parent.watchReadiness && !contentReady) parent.readinessDrops++
 }
}''' % (json.dumps(QUrl.fromLocalFile(str(ROOT / 'widgets/qml/Blox/Widgets/Native')).toString()),
         json.dumps(QUrl.fromLocalFile(str(ROOT / 'widgets/qml/Blox/Widgets')).toString()),
         json.dumps(QUrl.fromLocalFile(str(directory / 'wide.png')).toString()))).encode(), QUrl())
    root = component.create()
    assert root, str(component.errors())
    root.setParentItem(window.contentItem())
    art = root.findChild(QObject, 'musicArtworkImage')

    def wait_ready():
        deadline = time.monotonic() + 5
        while not root.property('ready') and time.monotonic() < deadline:
            # RenderControl has no window render loop to polish a Canvas for its readiness signal.
            render(root)
            app.processEvents()
            time.sleep(0.001)
        assert root.property('ready'), 'Music artwork never became ready'
        render(root)

    wait_ready()
    assert root.findChild(QObject, 'music').property('artworkReady')
    root.setProperty('watchReadiness', True)
    root.setWidth(1000)
    root.setHeight(700)
    root.findChild(QObject, 'music').setProperty('fullscreen', True)
    assert root.property('ready') and root.findChild(QObject, 'music').property('artworkReady')
    wait_ready()
    assert root.property('readinessDrops') == 0, 'Same-URL resizing hid the widget'
    root.setProperty('artUrl', QUrl.fromLocalFile(str(directory / 'tall.png')).toString())
    assert not root.property('ready'), 'A different track inherited readiness from old artwork'
    assert not root.findChild(QObject, 'music').property('artworkReady')
    wait_ready()
    assert root.findChild(QObject, 'music').property('artworkReady')
    assert root.property('readinessDrops') >= 1

    # Rounded software artwork owns one bounded decode and waits for the current clipped paint.
    root.setProperty('roundness', 2)
    assert not root.property('ready')
    wait_ready()
    canvas = root.findChild(QObject, 'softwareArtwork')
    assert canvas is not None and canvas.property('ready')
    assert not art.property('source').toString(), 'Software artwork duplicated the Image decode'
    root.setWidth(380)
    root.setHeight(280)
    root.findChild(QObject, 'music').setProperty('fullscreen', False)
    assert not root.property('ready'), 'A resized mask inherited the previous painted dimensions'
    wait_ready()
    assert canvas.property('sourceSize').width() <= 100 * dpr
    assert canvas.property('sourceSize').height() <= 100 * dpr
    dispose(root)
    print(json.dumps({'dpr': dpr, 'cases': results, 'musicLifecycle': True, 'unshown': True}))


class ImageDecodeSizeTests(unittest.TestCase):
    def test_production_raster_bounds_crop_fit_resize_and_natural_tiles(self):
        try:
            import PySide6  # noqa: F401
        except ImportError:
            self.skipTest('PySide6 is required for isolated rendering')
        for dpr in (1, 2):
            with self.subTest(dpr=dpr), tempfile.TemporaryDirectory(prefix='chester-image-bounds-') as directory:
                environment = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software',
                    QT_SCALE_FACTOR=str(dpr), QT_QPA_PLATFORMTHEME='', QT_STYLE_OVERRIDE='',
                    QT_QUICK_CONTROLS_STYLE='Basic')
                for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'QML_IMPORT_PATH',
                            'QML2_IMPORT_PATH', 'QT_PLUGIN_PATH', 'QT_QPA_PLATFORM_PLUGIN_PATH'):
                    environment.pop(key, None)
                result = subprocess.run([sys.executable, __file__, '--worker', directory, str(dpr)],
                    env=environment, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(len(report['cases']), 20)
                self.assertTrue(report['unshown'])
                self.assertTrue(report['musicLifecycle'])


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--worker':
        worker(sys.argv[2], float(sys.argv[3]))
    else:
        unittest.main()
