#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
runner = root / "windows" / "runner"
window_cpp = runner / "flutter_window.cpp"
cmake = runner / "CMakeLists.txt"

if not window_cpp.exists() or not cmake.exists():
    raise SystemExit("Flutter Windows runner was not generated. Run flutter create first.")

source = window_cpp.read_text(encoding="utf-8")
if '#include "mtunz_input_plugin.h"' not in source:
    source = source.replace(
        '#include "flutter_window.h"',
        '#include "flutter_window.h"\n#include "mtunz_input_plugin.h"',
        1,
    )
needle = "RegisterPlugins(flutter_controller_->engine());"
if "RegisterMtunzInput(" not in source:
    if needle not in source:
        raise SystemExit("Could not find RegisterPlugins() in flutter_window.cpp")
    source = source.replace(
        needle,
        needle + "\n    RegisterMtunzInput(flutter_controller_->engine()->messenger());",
        1,
    )
window_cpp.write_text(source, encoding="utf-8")

cmake_source = cmake.read_text(encoding="utf-8")
cmake_lines = [
    'target_sources(${BINARY_NAME} PRIVATE "mtunz_input_plugin.cpp")',
    'target_compile_features(${BINARY_NAME} PRIVATE cxx_std_17)',
    'target_link_libraries(${BINARY_NAME} PRIVATE user32)',
]
for line in cmake_lines:
    if line not in cmake_source:
        cmake_source = cmake_source.rstrip() + "\n" + line + "\n"
cmake.write_text(cmake_source, encoding="utf-8")
