#!/bin/bash
# =============================================================================
# wkhtmltopdf 0.12.6 macOS build script (arm64, Apple Clang)
# 源码: wkhtmltopdf 工程 + qt 子模块(cve-hardening 分支,wk_4.8.7 @ cb88757e7c
#       + zlib 1.3.2 / libpng 1.6.58 / SQLite 3.54.1 / libjpeg-turbo 3.1.4.1)
# 产物: bin/wkhtmltopdf (静态链接单文件,与 Windows 成果物同口径)
#
# 与 Windows 构建(D:\001 CLAUDE.md 流程)的对应关系:
#   configure(nmake 树)      -> ./configure + make
#   corelib→gui→xml→svg→network→webkit → make 从 qt 顶层按依赖顺序自动完成
#   PaintHooks 合并           -> 跳过(Windows BeginPaint/EndPaint 专属,mac 不存在)
#   插件(imageformats 等)    -> make 自动构建(plugins 目录)
#   wkhtmltopdf 工程编译      -> qmake wkhtmltopdf.pro && make
# =============================================================================
set -euo pipefail

JOBS=$(sysctl -n hw.ncpu)
echo "=== toolchain ==="
xcodebuild -version
clang --version
sw_vers

# ---------------------------------------------------------------------------
# 环境变量:mac arm64 最低部署目标 11.0(10.7 是 Intel 时代目标,arm 不适用)
# ---------------------------------------------------------------------------
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}

# ---------------------------------------------------------------------------
# Step 1: 编译 Qt 4.8.7 (static, vendored 3rdparty)
# 与 Windows 侧一致:用 -qt-zlib/-qt-libpng/-qt-libjpeg 强制 vendored 版本
# (不用 -system-*,保证 mac 成果物的库版本 = Windows 成果物 = CVE 处置口径)
# 官方 packaging 对 qt/configure 的一处已知兼容修复(见 official.yml)在此保留
# ---------------------------------------------------------------------------
echo "=== Step 1: configure + build Qt ==="
cd "$QT_DIR"

# 官方 CI 的兼容修复:configure 脚本变量行补充 OBJECTIVE_CFLAGS
sed -i.bak -e 's/CFLAGS CXXFLAGS LDFLAGS/CFLAGS CXXFLAGS OBJECTIVE_CFLAGS LDFLAGS/g' configure

./configure \
    -opensource -confirm-license \
    -release -static \
    -cocoa \
    -webkit \
    -graphicssystem raster \
    -qt-zlib -qt-libpng -qt-libjpeg \
    -qt-freetype \
    -no-framework \
    -no-qt3support \
    -no-openssl \
    -no-dbus \
    -no-cups \
    -no-opengl \
    -no-openvg \
    -no-phonon -no-phonon-backend \
    -no-multimedia -no-audio-backend \
    -no-nis \
    -nomake demos -nomake examples -nomake docs -nomake translations -nomake tools \
    2>&1 | tee configure.log

echo "--- building Qt (make -j$JOBS, 预计 30~60 分钟) ---"
make -j"$JOBS" 2>&1 | tee build.log || {
    echo "!!! Qt build FAILED — 保留 configure.log/build.log 供排障,常见问题见 workflow 注释"
    exit 1
}

# ---------------------------------------------------------------------------
# Step 2: 编译 wkhtmltopdf 工程
# ---------------------------------------------------------------------------
echo "=== Step 2: build wkhtmltopdf ==="
cd "$PROJECT_DIR"
export PATH="$QT_DIR/bin:$PATH"
# qmake needs the platform mkspec explicitly when invoked outside the Qt tree
# (top-level Qt 4 qmake cannot deduce it: "QMAKESPEC has not been set")
build-mac: pass absolute build-tree mkspecs path to qmake
make -j"$JOBS" 2>&1 | tee wkbuild.log

# ---------------------------------------------------------------------------
# Step 3: 冒烟测试(无显示器环境下 headless 转换)
# ---------------------------------------------------------------------------
echo "=== Step 3: smoke test ==="
ls -la bin/
./bin/wkhtmltopdf --version
cat > smoke_test.html <<'EOF'
<html><head><style>body{font-family:sans-serif}</style></head>
<body><h1>build smoke test</h1><p>table row &amp; column check</p>
<table border="1"><tr><td>cell 1</td><td>cell 2</td></tr></table>
</body></html>
EOF
./bin/wkhtmltopdf smoke_test.html smoke_test.pdf
ls -la smoke_test.pdf

echo "=== BUILD COMPLETE: $PROJECT_DIR/bin/wkhtmltopdf ==="
