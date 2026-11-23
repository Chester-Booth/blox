"""Exercise real Qt decoding, cache publication and the native QML resolver offline."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def private_environment(directory):
    env = dict(os.environ, XDG_CACHE_HOME=str(directory / "cache"), QT_QPA_PLATFORM="offscreen",
               QT_QUICK_BACKEND="software", QT_QUICK_CONTROLS_STYLE="Basic", QT_QPA_PLATFORMTHEME="",
               QT_STYLE_OVERRIDE="", QML_DISABLE_DISK_CACHE="1", PYTHONDONTWRITEBYTECODE="1")
    for key in ("DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "QML_IMPORT_PATH", "QML2_IMPORT_PATH"):
        env.pop(key, None)
    return env


def worker(data):
    from PySide6.QtCore import QCoreApplication, QObject, QUrl
    from PySide6.QtGui import QColor, QColorSpace, QGuiApplication, QImage
    from PySide6.QtQml import QQmlComponent, QQmlEngine
    from PySide6.QtQuick import QQuickRenderControl, QQuickRenderTarget, QQuickWindow
    directory = Path(data["directory"])
    if data["scenario"] == "fixtures":
        paths = {}
        for name, width, height in (("wide", 240, 120), ("alpha", 73, 117), ("large", 4096, 2160)):
            image = QImage(width, height, QImage.Format_ARGB32)
            if name == "large":
                image.fill(QColor("#204080"))
            else:
                for y in range(height):
                    for x in range(width):
                        image.setPixelColor(x, y, QColor(x*255//width, y*255//height, (x+y)%256,
                                                        (x*7+y*3)%256 if name == "alpha" else 255))
            image.setColorSpace(QColorSpace(QColorSpace.DisplayP3))
            path = directory / (name + ".png")
            assert image.save(str(path))
            paths[name] = str(path)
        jpeg = directory / "rotated.jpg"
        image = QImage(paths["wide"])
        assert image.save(str(jpeg), "JPEG", 100)
        # Add a standard EXIF orientation entry without another imaging dependency.
        exif = b"Exif\0\0II" + struct.pack("<HIH", 42, 8, 1) + struct.pack("<HHIHHI", 0x112, 3, 1, 6, 0, 0)
        raw = jpeg.read_bytes()
        jpeg.write_bytes(raw[:2] + b"\xff\xe1" + struct.pack(">H", len(exif)+2) + exif + raw[2:])
        paths["rotated"] = str(jpeg)
        print(json.dumps(paths))
        return
    app = QGuiApplication([]) if data["scenario"] == "pixels" else QCoreApplication([])
    engine = QQmlEngine()
    if data["scenario"] == "pixels":
        QQuickWindow.setSceneGraphBackend("software")
        control = QQuickRenderControl()
        window = QQuickWindow(control)
        images = []
        for path in (data["source"], data["derived"]):
            component = QQmlComponent(engine)
            width, height, dpr, fit = data["width"], data["height"], data["dpr"], data["fit"]
            cap = "" if fit == "Tile" else f"sourceSize:Qt.size({round(width*dpr)},{round(height*dpr)});"
            component.setData((f'''import QtQuick
Item {{width:{width};height:{height}; Image {{anchors.fill:parent;source:{json.dumps(Path(path).as_uri())};
fillMode:Image.{fit};smooth:true;cache:false;{cap}}} }}''').encode(), QUrl())
            root = component.create()
            assert root, [str(error) for error in component.errors()]
            root.setParentItem(window.contentItem())
            window.setGeometry(0, 0, width, height)
            image = QImage(round(width*dpr), round(height*dpr), QImage.Format_ARGB32_Premultiplied)
            image.fill(0)
            target = QQuickRenderTarget.fromPaintDevice(image)
            target.setDevicePixelRatio(dpr)
            window.setRenderTarget(target)
            for _ in range(3):
                app.processEvents(); control.polishItems(); control.sync(); control.render()
            assert not window.isVisible()
            images.append(image.copy())
            root.setParentItem(None)
            root.deleteLater()
            app.processEvents()
        one, two = images
        a, b = bytes(one.constBits()), bytes(two.constBits())
        result = {"exact": one == two, "maxChannelDifference": max(abs(x-y) for x,y in zip(a,b))}
        source_image, derived_image = QImage(data["source"]), QImage(data["derived"])
        result["colourSpacePreserved"] = source_image.colorSpace() == derived_image.colorSpace()
        print(json.dumps(result))
        return

    engine.addImportPath(data["imports"])
    component = QQmlComponent(engine)
    component.setData(b"import Blox.Services 1.0\nImageCacheResolver {}", QUrl())
    assert component.isReady(), [str(error) for error in component.errors()]
    objects = []

    def create(source, source_id=""):
        item = component.createWithInitialProperties({"source": QUrl.fromLocalFile(source), "sourceId": source_id,
                                                     "pixelWidth": 97, "pixelHeight": 53})
        assert item, [str(error) for error in component.errors()]
        objects.append(item)
        return item

    def wait(condition, timeout=10):
        until = time.monotonic()+timeout
        while not condition() and time.monotonic() < until:
            app.processEvents(); time.sleep(.003)
        assert condition(), [(item.property("status"), item.property("error")) for item in objects]

    log = directory / "helper-calls"
    if data["scenario"].startswith("identities"):
        valid_id = hashlib.sha256(Path(data["source"]).read_bytes()).hexdigest()
        order = ["0"*64, valid_id] if data["scenario"].endswith("wrong-first") else [valid_id, "0"*64]
        probes = [create(data["source"], source_id) for source_id in order]
        wait(lambda: all(item.property("status") in ("ready", "error") for item in probes))
        for source_id, item in zip(order, probes):
            assert item.property("status") == ("ready" if source_id == valid_id else "error")
        print(json.dumps({"independentIdentities": True}))
    elif data["scenario"] == "coalesce":
        first = create(data["source"])
        second = create(data["source"])
        wait(lambda: all(item.property("status") == "ready" for item in (first, second)))
        assert first.property("readySource") == second.property("readySource")
        third = create(data["source"])
        wait(lambda: third.property("status") == "ready")
        tile = create(data["source"])
        tile.setProperty("fit", "tile")
        wait(lambda: tile.property("status") == "ready")
        assert tile.property("readySource").toLocalFile() == data["source"]
        print(json.dumps({"calls": len(log.read_text().splitlines()), "ready": 4}))
    elif data["scenario"] == "stale":
        first = create(data["source"])
        wait(log.exists)
        first.setProperty("source", QUrl.fromLocalFile(data["secondSource"]))
        wait(lambda: first.property("status") == "ready")
        path = Path(first.property("readySource").toLocalFile())
        records = [json.loads(p.read_text()) for p in (directory/"cache/blox/images/v1").glob("*.json")]
        matching = [record for record in records if record["imageIdentity"]["inode"] == str(path.stat().st_ino)]
        assert matching[0]["sourceId"] == hashlib.sha256(Path(data["secondSource"]).read_bytes()).hexdigest()
        print(json.dumps({"calls": len(log.read_text().splitlines()), "staleRejected": True}))
    elif data["scenario"] == "inactive":
        first = create(data["source"])
        wait(log.exists)
        first.setProperty("active", False)
        wait(lambda: first.property("status") == "idle")
        until = time.monotonic()+.5
        while time.monotonic() < until: app.processEvents(); time.sleep(.005)
        assert first.property("status") == "idle" and first.property("readySource").isEmpty()
        print(json.dumps({"stayedIdle": True}))
    for item in objects: item.deleteLater()
    app.processEvents()


class NativeImageCacheTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.imports = ROOT / "shell/native/qml"
        result = subprocess.run([sys.executable, "-B", str(ROOT/"packaging/build_native_services.py"), "--output-import-path", str(cls.imports)],
                                capture_output=True, text=True, timeout=90)
        if result.returncode: raise RuntimeError(result.stdout+result.stderr)
        cls.module = cls.imports/"Blox/Services"
        cls.helper = cls.module/"blox-image-cache"

    @classmethod
    def tearDownClass(cls):
        pass

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="blox-image-cache-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.env = private_environment(self.directory)
        self.sources = self.run_worker(scenario="fixtures")

    def run_worker(self, **data):
        request = {"directory": str(self.directory), **data}
        result = subprocess.run([sys.executable, "-B", __file__, "worker", json.dumps(request)], env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stdout+result.stderr)
        return json.loads(result.stdout)

    def request(self, source="wide", **changes):
        return {"source": Path(self.sources[source]).as_uri(), "width": 97, "height": 53, "fit": "cover", **changes}

    def prepare(self, request, *, valid=True):
        result = subprocess.run([str(self.helper), json.dumps(request)], env=self.env, capture_output=True, text=True, timeout=35)
        self.assertEqual(0 if valid else 1, result.returncode, result.stdout+result.stderr)
        return json.loads(result.stdout)

    def test_ready_hit_reuses_identity_and_corrupt_files_are_rebuilt(self):
        request = self.request(sourceId=hashlib.sha256(Path(self.sources["wide"]).read_bytes()).hexdigest())
        first = self.prepare(request)
        self.assertFalse(first["cacheHit"])
        path = Path(first["source"].removeprefix("file://"))
        before = path.stat()
        self.assertTrue(self.prepare(request)["cacheHit"])
        self.assertEqual(before.st_ino, path.stat().st_ino)
        path.write_bytes(b"corrupt derivative")
        self.assertFalse(self.prepare(request)["cacheHit"])
        index = next((self.directory/"cache/blox/images/v1").glob("*.json"))
        index.write_text("not JSON")
        self.assertFalse(self.prepare(request)["cacheHit"])
        Path(self.sources["wide"]).write_bytes(Path(self.sources["alpha"]).read_bytes())
        self.assertIn("identity", self.prepare(request, valid=False)["error"].lower())

    def test_concurrent_misses_publish_once_and_share_the_ready_result(self):
        request = self.request("large")
        processes = [subprocess.Popen([str(self.helper), json.dumps(request)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(4)]
        results = []
        for process in processes:
            out, err = process.communicate(timeout=35)
            self.assertEqual(0, process.returncode, out+err)
            results.append(json.loads(out))
        self.assertEqual(1, sum(not result["cacheHit"] for result in results))
        self.assertEqual(1, len({result["source"] for result in results}))

    def test_source_changes_during_preparation_do_not_publish_an_index(self):
        source = Path(self.sources["large"])
        process = subprocess.Popen([str(self.helper), json.dumps(self.request("large"))], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        while process.poll() is None:
            os.utime(source, None)
            time.sleep(.002)
        out, err = process.communicate(timeout=5)
        self.assertEqual(1, process.returncode, out+err)
        self.assertIn("changed", json.loads(out)["error"])
        self.assertFalse(list((self.directory/"cache").rglob("*.json")))

    def test_cache_paths_cannot_redirect_publication_outside_the_owned_cache(self):
        outside = self.directory/"outside"
        outside.mkdir()
        cache = self.directory/"cache/blox/images"
        cache.mkdir(parents=True)
        (cache/"v1").symlink_to(outside, target_is_directory=True)
        self.assertIn("unsafe", self.prepare(self.request(), valid=False)["error"])
        self.assertEqual([], list(outside.iterdir()))
        (cache/"v1").unlink()
        self.assertIn("owned", self.prepare(self.request(cacheRoot=str(outside)), valid=False)["error"])
        first = self.prepare(self.request())
        image = Path(first["source"].removeprefix("file://"))
        image.unlink()
        target = outside/"personal"
        target.write_bytes(b"personal bytes")
        image.symlink_to(target)
        self.assertIn("unsafe", self.prepare(self.request(), valid=False)["error"])
        self.assertEqual(b"personal bytes", target.read_bytes())

    def test_invalid_urls_and_physical_dimensions_cannot_create_cache_files(self):
        for changes in ({"source": "https://example.invalid/image.png"}, {"width": 20000},
                        {"width": 16384, "height": 16384}, {"fit": "stretch"}):
            with self.subTest(changes=changes):
                self.prepare({**self.request(), **changes}, valid=False)
                self.assertFalse((self.directory/"cache").exists())

    def test_alpha_colour_profile_exif_and_dpr_match_the_existing_qt_image(self):
        for source, width, height, dpr in (("wide", 57, 101, 1), ("alpha", 27, 39, 2), ("rotated", 61, 43, 1)):
            for fit in ("PreserveAspectCrop", "PreserveAspectFit"):
                with self.subTest(source=source, fit=fit):
                    prepared = self.prepare(self.request(source, width=round(width*dpr), height=round(height*dpr), fit="cover" if fit.endswith("Crop") else "contain"))
                    result = self.run_worker(scenario="pixels", source=self.sources[source], derived=prepared["source"].removeprefix("file://"),
                                             width=width, height=height, dpr=dpr, fit=fit)
                    self.assertTrue(result["exact"], result)
                    self.assertTrue(result["colourSpacePreserved"], result)
        before = set((self.directory/"cache").rglob("*"))
        tile = self.prepare(self.request("alpha", fit="tile"))
        self.assertEqual(Path(self.sources["alpha"]).as_uri(), tile["source"])
        self.assertEqual(before, set((self.directory/"cache").rglob("*")))

    def test_native_resolver_coalesces_misses_uses_direct_hits_and_discards_stale_work(self):
        for scenario in ("coalesce", "stale", "inactive", "identities-wrong-first", "identities-valid-first"):
            with self.subTest(scenario=scenario):
                directory = self.directory/scenario
                directory.mkdir()
                imports = directory/"qml"
                shutil.copytree(self.imports, imports)
                helper = imports/"Blox/Services/blox-image-cache"
                real = helper.with_name("image-cache-real")
                helper.rename(real)
                helper.write_text('#!/bin/sh\nprintf "call\\n" >> "' + str(directory/"helper-calls") + '"\nsleep 0.15\nexec "' + str(real) + '" "$@"\n')
                helper.chmod(0o700)
                environment = self.env
                self.env = private_environment(directory)
                original_directory = self.directory
                self.directory = directory
                try:
                    result = self.run_worker(scenario=scenario, imports=str(imports), source=self.sources["wide"], secondSource=self.sources["alpha"])
                finally:
                    self.directory = original_directory
                    self.env = environment
                if scenario.startswith("identities"): self.assertTrue(result["independentIdentities"])
                elif scenario == "coalesce": self.assertEqual(1, result["calls"])
                elif scenario == "stale": self.assertTrue(result["staleRejected"])
                else: self.assertTrue(result["stayedIdle"])


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "worker": worker(json.loads(sys.argv[2]))
    else: unittest.main()
