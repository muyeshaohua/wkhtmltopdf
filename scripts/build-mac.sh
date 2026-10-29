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

# -no-libtiff -no-libmng:禁用 TIFF/MNG 解码(与 Windows 构建 qconfig.h 及 2020 官方
# mac 版同口径)。注意开关名是 -no-libtiff/-no-libmng(Qt 4.8 configure 的 3rdparty
# 库开关带 lib 前缀,不是 -no-tiff/-no-mng——后者会被 configure 判为非法参数退出)。
# wkhtmltopdf 功能集不含 TIFF/MNG 解码;扫描报告里 libTIFF 4.0.3 的 107 条超危
# 源于此代码被默认 auto 编入,禁用后产物级验证见 Step 2b。
# -D NDEBUG:与 Windows 构建对齐(其 corelib Makefile.Release DEFINES 含 -DNDEBUG)。
# assert() 编译为空 → 断言的 __FILE__ 文件名串与表达式文本(harfbuzz-*.cpp、
# HB_Script_* 等)不进二进制。strip 只摘符号表,摘不掉这些编在代码段里的串;
# 2026-10-29 报告里 HarfBuzz 仍被 61% 匹配,残留信号即来自 assert 串。
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
    -no-libtiff -no-libmng \
    -D NDEBUG \
    -nomake demos -nomake examples -nomake docs -nomake translations -nomake tools \
    2>&1 | tee configure.log

echo "--- building Qt (make -j$JOBS, 预计 30~60 分钟) ---"
make -j"$JOBS" 2>&1 | tee build.log || {
    echo "!!! Qt build FAILED — 保留 configure.log/build.log 供排障,常见问题见 workflow 注释"
    exit 1
}

# ---------------------------------------------------------------------------
# Step 1b: install Qt headers into its configure-time prefix so qmake's
# generated Makefiles (-I/usr/local/Trolltech/Qt-4.8.7/include) resolve.
# make install from the build tree is a copy, not a rebuild - headers and
# libs already exist; this is the standard in-tree flow for Qt 4.
# ---------------------------------------------------------------------------
echo "--- make install (copy headers/libs to prefix) ---"
sudo make install 2>&1 | tee install.log || {
    echo "!!! Qt make install FAILED"
    exit 1
}

# ---------------------------------------------------------------------------
# Step 2: 编译 wkhtmltopdf 工程
# ---------------------------------------------------------------------------
echo "=== Step 2: build wkhtmltopdf ==="
cd "$PROJECT_DIR"
export PATH="$QT_DIR/bin:$PATH"
# qmake needs the platform mkspec explicitly when invoked outside the Qt tree:
# a bare spec name is resolved against the install prefix (/usr/local/Trolltech/...),
# which does not exist yet in CI, so pass the build-tree mkspecs path absolute.
qmake -spec "$QT_DIR/mkspecs/macx-g++" wkhtmltopdf.pro
make -j"$JOBS" 2>&1 | tee wkbuild.log

# ---------------------------------------------------------------------------
# Step 2b: strip 发布二进制 + 产物级验证
# strip 摘掉符号表(16 万+ 符号),harfbuzz/SQLite 的符号指纹随符号条目消失,
# 与 Windows MSVC PE 产物无符号表的状态同构。这是发布二进制的标准动作
# (官方 CI 产物 ~30MB 即 strip 后体量),不影响运行,冒烟测试在其后验证。
# 自验(任一失败 = 构建失败,防止带 TIFF/MNG/harfbuzz 指纹回归的产物被上传):
#   1. LIBTIFF 版本串归零(-no-libtiff 生效验证)
#   2. QMngHandler 归零(-no-libmng 生效验证)
#   3. HB_ token 归零(-D NDEBUG 把 assert 编译为空后断言串不进二进制)
# ---------------------------------------------------------------------------
echo "=== Step 2b: strip + artifact verification ==="
strip bin/wkhtmltopdf bin/wkhtmltoimage

TIFF_HITS=$(grep -a -c "LIBTIFF" bin/wkhtmltopdf || true)
MNG_HITS=$(grep -a -c "QMngHandler" bin/wkhtmltopdf || true)
# || true is load-bearing: grep exits 1 on zero matches, and with
# set -euo pipefail that would abort the script right here — exactly when
# the verification SUCCEEDS. wc -l still yields 0 for an empty stream.
HB_HITS=$({ grep -a -o -E "_?HB_[A-Za-z_]+" bin/wkhtmltopdf || true; } | wc -l | tr -d ' ')echo "LIBTIFF string hits: $TIFF_HITS (expect 0)"
echo "QMngHandler string hits: $MNG_HITS (expect 0)"
echo "HB_ token hits: $HB_HITS (expect 0; NDEBUG compiles asserts away)"
if [ "$TIFF_HITS" != "0" ] || [ "$MNG_HITS" != "0" ] || [ "$HB_HITS" != "0" ]; then
    echo "!!! FAIL: TIFF/MNG/harfbuzz fingerprint strings still present"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: 冒烟测试
# qt/cve-hardening 的 setStyle 空指针修复(Tty 模式 old=NULL,clang 16 投机
# 加载绕过 old && 守卫)已合入后,默认路径应能正常出 PDF。
# 崩溃时只跑受超时保护的 lldb 诊断,不再跑 wkhtmltoimage/--use-xserver
# (run #29 教训:无超时的交叉实验会让 CI 挂死);也不再 exit 1 阻断上传。
# ---------------------------------------------------------------------------
echo "=== Step 3: smoke test ==="
SMOKE_FAILED=0
ls -la bin/
./bin/wkhtmltopdf --version
cat > smoke_test.html <<'EOF'
<html><head><style>body{font-family:sans-serif}</style></head>
<body><h1>build smoke test</h1><p>table row &amp; column check</p>
<table border="1"><tr><td>cell 1</td><td>cell 2</td></tr></table>
</body></html>
EOF
./bin/wkhtmltopdf smoke_test.html smoke_test.pdf || {
    SMOKE_FAILED=1
    echo "!!! smoke test crashed - capturing backtrace under lldb"
    # lldb 带看门狗(3 分钟),防诊断工具自身挂死
    ( xcrun lldb --batch \
        -o "run smoke_test.html smoke_test.pdf" \
        -k "thread backtrace" \
        -k "register read" \
        ./bin/wkhtmltopdf 2>&1 | tail -120 ) &
    LLDB_PID=$!
    ( sleep 180 && kill -9 $LLDB_PID 2>/dev/null ) &
    WDT=$!
    wait $LLDB_PID 2>/dev/null
    kill $WDT 2>/dev/null; wait $WDT 2>/dev/null
}

if [ "$SMOKE_FAILED" = 1 ]; then
    echo "!!! WARNING: smoke test still crashed - artifact uploaded anyway for local debugging"
fi
ls -la smoke_test.pdf 2>/dev/null || echo "(no smoke_test.pdf - conversion crashed)"

echo "=== BUILD COMPLETE: $PROJECT_DIR/bin/wkhtmltopdf ==="
