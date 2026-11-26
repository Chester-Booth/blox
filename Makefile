SHELL := /usr/bin/env bash
QS := shell
NATIVE_IMPORT_ROOT := $(CURDIR)/shell/native/qml
BUILD_NATIVE ?= 1
CHECK_JOBS ?=
LAUNCHER_PY_TESTS := tests/test_launcher_apps.py tests/test_launcher_clipboard.py tests/test_launcher_dmenu.py tests/test_launcher_emoji.py tests/test_launcher_processes.py
NATIVE_SERVICE_TESTS := tests.test_native_service_owner tests.test_native_image_cache tests.test_native_services_packaging tests.test_keyboard_backlight_watcher tests.test_bloxd

.PHONY: check check-serial ci native-services native-widgets qmllint py-compile shellcheck test-launcher test-native-services test-performance test-image-decode test-status-contracts test-bloxctl test-graphics-control test-lifecycle test-doctor test-cutover test-qml-paths test-qml-tokens test-widgets test-widgets-python test-widgets-qml validate-status validate-themes stylus-vendor stylus-source unit-check diff-check hygiene

check:
	@PYTHONDONTWRITEBYTECODE=1 LAUNCHER_PY_TESTS="$(LAUNCHER_PY_TESTS)" NATIVE_SERVICE_TESTS="$(NATIVE_SERVICE_TESTS)" python3 tools/run_checks.py $(if $(CHECK_JOBS),--jobs $(CHECK_JOBS),)

check-serial: qmllint py-compile shellcheck test-launcher test-native-services test-performance test-image-decode test-status-contracts test-bloxctl test-graphics-control test-lifecycle test-doctor test-cutover test-qml-paths test-qml-tokens test-widgets validate-status validate-themes unit-check diff-check

ci:
	@PYTHONDONTWRITEBYTECODE=1 LAUNCHER_PY_TESTS="$(LAUNCHER_PY_TESTS)" NATIVE_SERVICE_TESTS="$(NATIVE_SERVICE_TESTS)" python3 tools/run_checks.py --ci $(if $(CHECK_JOBS),--jobs $(CHECK_JOBS),)

test-performance:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_bench -v

test-image-decode:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_image_decode_sizes -v

native-services:
	@if [ "$(BUILD_NATIVE)" = "1" ]; then \
		PYTHONDONTWRITEBYTECODE=1 python3 packaging/build_native_services.py --output-import-path "$(NATIVE_IMPORT_ROOT)"; \
	fi

native-widgets:
	@if [ "$(BUILD_NATIVE)" = "1" ]; then \
		PYTHONDONTWRITEBYTECODE=1 python3 packaging/build_native_widgets.py --output-import-path "$(CURDIR)/widgets/qml"; \
	fi

qmllint: native-services native-widgets
	@QMLLINT="$$( [ -x /usr/lib/qt6/bin/qmllint ] && echo /usr/lib/qt6/bin/qmllint || command -v qmllint )"; \
	if [ -n "$$QMLLINT" ]; then \
		find $(QS) widgets/qml -type f -name '*.qml' -print0 | xargs -0 -r "$$QMLLINT" -I $(QS) -I widgets/qml -I "$(NATIVE_IMPORT_ROOT)"; \
	else \
		echo 'skip qmllint: command not found'; \
	fi

py-compile:
	@PYTHONDONTWRITEBYTECODE=1 python3 -c 'import ast, pathlib, sys; roots = [pathlib.Path(p) for p in sys.argv[1:]]; files = sorted(p for r in roots for p in r.rglob("*.py") if "__pycache__" not in p.parts); [ast.parse(p.read_text(encoding="utf-8"), filename=str(p)) for p in files]' $(QS)/scripts bin packaging widgets themes tools

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
		find $(QS) packaging -type f -name '*.sh' -print0 | xargs -0 -r shellcheck -x -P $(QS)/scripts/status; \
	else \
		echo 'skip shellcheck: command not found'; \
	fi

test-launcher: native-services native-widgets
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest $(LAUNCHER_PY_TESTS) -v
	@QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import "$(NATIVE_IMPORT_ROOT)" -import widgets/qml -import tests/qml/imports -import tests/qml/provider-imports -input tests/qml
	@QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml/imports -import "$(NATIVE_IMPORT_ROOT)" -input tests/native-qml

test-native-services: native-services
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest $(NATIVE_SERVICE_TESTS) -v

test-status-contracts:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_status_contracts.py tests/test_status_purity.py tests/test_power_safe.py -v

test-bloxctl:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_bloxctl.py tests/test_control_routing.py tests/test_settings_runtime.py tests/test_bundle_runtime.py tests/test_cursor_preview.py tests/test_apply_runtime.py tests/test_settings_shell_restart.py tests/test_obsidian_cli.py tests/test_obsidian_restore.py tests/test_hyprland_settings.py tests/test_settings_hyprland_preview_handoff.py tests/test_installed_helpers.py shell/tests/calendar/test_calendar_adapter.py shell/tests/calendar/test_calendar_store.py -v

test-graphics-control:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_graphics_control.py tests/test_multimonitor_foundations.py -v

test-lifecycle: native-services native-widgets
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_lifecycle.py tests/test_native_services_packaging.py tests/test_native_widgets_packaging.py -v

test-doctor:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_doctor.py -v

test-cutover:
	@bash tests/test_cutover.sh

test-qml-paths:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_quickshell_workflow_import.py tests/test_quickshell_fullscreen_visibility.py -v

test-qml-tokens:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_qml_token_hygiene.py -v

test-widgets: test-widgets-python test-widgets-qml

test-widgets-python: native-widgets
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_widget_metadata_bootstrap -v
	@BLOX_DATA_DIR="$(CURDIR)/themes" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(CURDIR)/widgets/lib$${PYTHONPATH:+:$$PYTHONPATH}" python3 -m unittest discover -s widgets/tests -p 'test_*.py' -v
	@PYTHONDONTWRITEBYTECODE=1 python3 widgets/tests/render_terminal.py

test-widgets-qml: native-widgets
	@QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic QT_QPA_PLATFORMTHEME= QML_DISABLE_DISK_CACHE=1 QML_IMPORT_PATH="$(CURDIR)/widgets/qml$${QML_IMPORT_PATH:+:$$QML_IMPORT_PATH}" /usr/lib/qt6/bin/qmltestrunner -import widgets/qml -input widgets/tests/qml

validate-status:
	@$(QS)/scripts/validate-status.py --timeout 10

validate-themes:
	@TMPDIR=/tmp BLOX_DATA_DIR="$(CURDIR)/themes" PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s themes/tests -v

stylus-vendor:
	@deno run -A themes/tools/vendor_catppuccin.ts

stylus-source:
	@deno run -A themes/tools/build_catppuccin.ts

unit-check: native-services native-widgets
	@python3 packaging/unit_check.py

diff-check:
	@git --no-pager diff --check

hygiene:
	@python3 packaging/hygiene.py
