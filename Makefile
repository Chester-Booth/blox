SHELL := /usr/bin/env bash
QS := shell

.PHONY: check ci qmllint py-compile shellcheck test-launcher test-status-contracts test-bloxctl test-lifecycle test-doctor test-cutover test-qml-paths test-qml-tokens validate-status validate-themes stylus-vendor stylus-source unit-check diff-check hygiene

check: qmllint py-compile shellcheck test-launcher test-status-contracts test-bloxctl test-lifecycle test-doctor test-cutover test-qml-paths test-qml-tokens validate-status validate-themes unit-check diff-check

ci: check hygiene

qmllint:
	@if command -v qmllint >/dev/null 2>&1; then \
		find $(QS) -type f -name '*.qml' -print0 | xargs -0 -r qmllint -I $(QS); \
	else \
		echo 'skip qmllint: command not found'; \
	fi

py-compile:
	@while IFS= read -r -d '' file; do \
		python3 -c 'import ast, pathlib, sys; path = pathlib.Path(sys.argv[1]); ast.parse(path.read_text(), filename=str(path))' "$$file"; \
	done < <(find $(QS)/scripts bin packaging -type f -name '*.py' -print0)
	@while IFS= read -r -d '' file; do \
		python3 -c 'import ast, pathlib, sys; path = pathlib.Path(sys.argv[1]); ast.parse(path.read_text(), filename=str(path))' "$$file"; \
	done < <(find themes -type f -name '*.py' -print0)

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
		find $(QS) packaging -type f -name '*.sh' -print0 | xargs -0 -r shellcheck -x -P $(QS)/scripts/status; \
	else \
		echo 'skip shellcheck: command not found'; \
	fi

test-launcher:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_launcher_apps.py tests/test_launcher_clipboard.py tests/test_launcher_dmenu.py tests/test_launcher_emoji.py tests/test_launcher_processes.py -v
	@QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml/imports -input tests/qml

test-status-contracts:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_status_contracts.py tests/test_status_purity.py -v

test-bloxctl:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_bloxctl.py -v

test-lifecycle:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_lifecycle.py -v

test-doctor:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_doctor.py -v

test-cutover:
	@bash tests/test_cutover.sh

test-qml-paths:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_qml_no_legacy_paths.py -v

test-qml-tokens:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_qml_token_hygiene.py -v

validate-status:
	@$(QS)/scripts/validate-status.py --timeout 10

validate-themes:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s themes/tests -v

stylus-vendor:
	@deno run -A themes/tools/vendor_catppuccin.ts

stylus-source:
	@deno run -A themes/tools/build_catppuccin.ts

unit-check:
	@python3 packaging/unit_check.py

diff-check:
	@git diff --check

hygiene:
	@python3 packaging/hygiene.py
