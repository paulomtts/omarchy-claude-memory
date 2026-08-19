#!/usr/bin/env bash
# Both suites: pytest for the scripts, Qt's own qmltestrunner for logic.js
# (the panel's rules, on the same engine the panel runs on).
set -euo pipefail
cd "$(dirname "$0")"

python3 -m pytest tests

# Packaged under /usr/lib/qt6/bin on Arch, where a Qt5 qmltestrunner may
# also be first on PATH and will silently fail to load a Qt6 test.
qmltestrunner=$(command -v /usr/lib/qt6/bin/qmltestrunner || command -v qmltestrunner)
QT_QPA_PLATFORM=offscreen "$qmltestrunner" -input tests/qml
