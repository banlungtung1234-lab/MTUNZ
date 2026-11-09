#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/app"

# Generate platform runners from the installed Flutter SDK. This produces real
# Windows and Android native shells; it does not create or launch a website.
flutter create --platforms=android,windows --org com.mtunz --project-name app .

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
else
  echo "Python 3 is required to prepare the native project." >&2
  exit 1
fi

copy_tree() {
  local source="$1" destination="$2"
  mkdir -p "$destination"
  cp -R "$source"/. "$destination"/
}

copy_tree "$ROOT/platform/android/app/src/main/kotlin" "$ROOT/app/android/app/src/main/kotlin"
copy_tree "$ROOT/platform/android/app/src/main/res/xml" "$ROOT/app/android/app/src/main/res/xml"
copy_tree "$ROOT/platform/android/app/src/main/res/values" "$ROOT/app/android/app/src/main/res/values"
cp "$ROOT/platform/android/app/src/main/AndroidManifest.xml" "$ROOT/app/android/app/src/main/AndroidManifest.xml"
cp "$ROOT/platform/android/app/proguard-rules.pro" "$ROOT/app/android/app/proguard-rules.pro"

# flutter_webrtc and the native MediaProjection bridge are built with Android
# API 24 as the minimum supported level for this project.
"$PYTHON_BIN" - "$ROOT/app/android/app" <<'PYMINSDK'
from pathlib import Path
import re
import sys

app_dir = Path(sys.argv[1])
for name in ("build.gradle.kts", "build.gradle"):
    path = app_dir / name
    if not path.exists():
        continue
    source = path.read_text(encoding="utf-8")
    if name.endswith(".kts"):
        updated = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 24", source)
        updated = re.sub(r"minSdk\s*=\s*\d+", "minSdk = 24", updated)
        marker = re.search(r"buildTypes\s*\{\s*release\s*\{", updated)
        if marker and "proguardFiles(" not in updated:
            updated = updated[:marker.end()] + '\n        proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")' + updated[marker.end():]
    else:
        updated = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", "minSdkVersion 24", source)
        updated = re.sub(r"minSdkVersion\s+\d+", "minSdkVersion 24", updated)
        marker = re.search(r"buildTypes\s*\{\s*release\s*\{", updated)
        if marker and "proguardFiles" not in updated:
            updated = updated[:marker.end()] + "\n        proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'" + updated[marker.end():]
    if updated != source:
        path.write_text(updated, encoding="utf-8")
    if "buildTypes" not in updated or "proguardFiles" not in updated:
        raise SystemExit("Could not configure release ProGuard rules in generated Android Gradle file")
    break
else:
    raise SystemExit("Could not find generated Android app Gradle file")
PYMINSDK

# Add the Windows native input bridge to the generated Flutter desktop runner.
copy_tree "$ROOT/platform/windows/runner" "$ROOT/app/windows/runner"
"$PYTHON_BIN" "$ROOT/scripts/inject-windows-controller.py" "$ROOT/app"

# Keep the native runner compatible with Windows 10 and Windows 11. The
# Windows 10 API baseline also applies to Windows 11, which reports NT 10.0.
"$PYTHON_BIN" - "$ROOT/app/windows/CMakeLists.txt" <<'PYWINDOWSAPI'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
marker = "project(${BINARY_NAME} LANGUAGES CXX)"
definitions = "add_compile_definitions(WINVER=0x0A00 _WIN32_WINNT=0x0A00)"
if marker not in source:
    raise SystemExit("Could not find generated Windows CMake project declaration")
if definitions not in source:
    source = source.replace(
        marker,
        marker + "\n\n# Build against the Windows 10+ API baseline for Windows 10/11.\n" + definitions,
        1,
    )
    path.write_text(source, encoding="utf-8")
PYWINDOWSAPI

# Give the packaged executable and its window the MTUNZ product name.
"$PYTHON_BIN" - "$ROOT/app/windows" <<'PYWINDOWNAME'
from pathlib import Path
import re
import sys

windows_dir = Path(sys.argv[1])
cmake = windows_dir / "CMakeLists.txt"
if cmake.exists():
    source = cmake.read_text(encoding="utf-8")
    source = re.sub(r'set\(BINARY_NAME "[^"]+"\)', 'set(BINARY_NAME "MTUNZ")', source, count=1)
    cmake.write_text(source, encoding="utf-8")

main = windows_dir / "runner" / "main.cpp"
if main.exists():
    source = main.read_text(encoding="utf-8").replace('L"app"', 'L"MTUNZ"')
    main.write_text(source, encoding="utf-8")

resource = windows_dir / "runner" / "Runner.rc"
if resource.exists():
    source = resource.read_text(encoding="utf-8")
    source = source.replace('"FileDescription", "app"', '"FileDescription", "MTUNZ"')
    source = source.replace('"ProductName", "app"', '"ProductName", "MTUNZ"')
    resource.write_text(source, encoding="utf-8")
PYWINDOWNAME

flutter pub get
