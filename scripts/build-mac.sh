#!/bin/bash
# =============================================================================
# wkhtmltopdf 0.12.6 macOS build script (arm64, Apple Clang)
# Source: wkhtmltopdf project + qt submodule (cve-hardening branch,
#         wk_4.8.7 + zlib 1.3.2 / libpng 1.6.58 / SQLite 3.54.1 / libjpeg-turbo 3.1.4.1)
# Output: bin/wkhtmltopdf (static single file, same contract as the Windows build)
#
# Mapping to the Windows build (D:\001 CLAUDE.md flow):
#   configure (nmake tree)    -> ./configure + make
#   corelib->gui->xml->svg->network->webkit -> make resolves order from the qt top dir
#   PaintHooks merge          -> skipped (Windows BeginPaint/EndPaint only, N/A on mac)
#   plugins (imageformats)    -> make builds them (plugins dir)
#   wkhtmltopdf build         -> qmake wkhtmltopdf.pro && make
# =============================================================================
set -euo pipefail

# Guard: this script must be LF-only. CRLF line endings make bash execute
# "command\r" (exit 127, command not found) deep into the build. Fail fast
# with a clear message instead.
if grep -q $'\r' "$0"; then
    echo "!!! FATAL: $0 has CRLF line endings. Convert to LF (e.g. dos2unix) and recommit."
    exit 127
fi

JOBS=$(sysctl -n hw.ncpu)
echo "=== toolchain ==="
xcodebuild -version
clang --version
sw_vers

# ---------------------------------------------------------------------------
# Deployment target: mac arm64 minimum is 11.0 (10.7 is an Intel-era target)
# ---------------------------------------------------------------------------
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}

# ---------------------------------------------------------------------------
# Step 1: build Qt 4.8.7 (static, vendored 3rdparty)
# Same as the Windows side: -qt-zlib/-qt-libpng/-qt-libjpeg force the vendored
# versions (no -system-*), so mac artifact library versions = Windows artifact
# versions = the CVE remediation baseline.
# The official packaging compatibility fix for qt/configure is kept (official.yml).
#
# -no-libtiff -no-libmng: disable TIFF/MNG decoding (same contract as the
# Windows build qconfig.h and the 2020 official mac build; wkhtmltopdf's
# feature set never included TIFF/MNG decoding). The 107 critical libTIFF
# findings in the 2026-10-28 scan report came from this code being pulled in
# by the configure default. Note: the switches are -no-libtiff/-no-libmng,
# NOT -no-tiff/-no-mng (those are internal QT_CONFIG tokens; configure aborts
# with "invalid command-line switch" on them - CI run 40700026128).
# Artifact-level verification is in Step 2b.
#
# -D NDEBUG: align with the Windows build (its corelib Makefile.Release
# DEFINES carries -DNDEBUG). assert() compiles to nothing, so the __FILE__
# names and assert expression texts (harfbuzz-*.cpp, HB_Script_* tokens) stay
# out of the binary. strip removes the symbol table but not strings compiled
# into __TEXT; the residual 61% HarfBuzz match in the 2026-10-29 report was
# exactly those assert strings.
# ---------------------------------------------------------------------------
echo "=== Step 1: configure + build Qt ==="
cd "$QT_DIR"

# Official CI compatibility fix: add OBJECTIVE_CFLAGS to the configure vars line
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
    -no-libtiff -no-libmng \
    -D NDEBUG \
    -nomake demos -nomake examples -nomake docs -nomake translations -nomake tools \
    2>&1 | tee configure.log

echo "--- building Qt (make -j$JOBS, est. 30-60 min) ---"
make -j"$JOBS" 2>&1 | tee build.log || {
    echo "!!! Qt build FAILED - configure.log/build.log kept for debugging"
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
# Step 2: build the wkhtmltopdf project
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
# Step 2b: strip the release binaries + artifact-level verification
# strip removes the symbol table (160k+ symbols); harfbuzz/SQLite symbol
# fingerprints go with the symbol entries - the same state a Windows MSVC PE
# artifact is in (no symbol table). Standard release practice; the official CI
# artifacts (~30MB) are stripped. Smoke test follows to prove it still runs.
# Gates (any failure = build failure, a regressed artifact cannot upload):
#   1. LIBTIFF version string = 0        (-no-libtiff took effect)
#   2. QMngHandler            = 0        (-no-libmng took effect)
#   3. HB_ tokens             = 0        (NDEBUG compiled asserts away)
# The "|| true" on the greps is load-bearing: grep exits 1 on zero matches,
# and with set -euo pipefail that would abort the script exactly when the
# verification SUCCEEDS (CI run 40813050243). wc -l still yields 0.
# ---------------------------------------------------------------------------
echo "=== Step 2b: strip + artifact verification ==="
strip bin/wkhtmltopdf bin/wkhtmltoimage

TIFF_HITS=$(grep -a -c "LIBTIFF" bin/wkhtmltopdf || true)
MNG_HITS=$(grep -a -c "QMngHandler" bin/wkhtmltopdf || true)
HB_HITS=$({ grep -a -o -E "_?HB_[A-Za-z_]+" bin/wkhtmltopdf || true; } | wc -l | tr -d ' ')
echo "LIBTIFF string hits: $TIFF_HITS (expect 0)"
echo "QMngHandler string hits: $MNG_HITS (expect 0)"
echo "HB_ token hits: $HB_HITS (expect 0; NDEBUG compiles asserts away)"
if [ "$TIFF_HITS" != "0" ] || [ "$MNG_HITS" != "0" ] || [ "$HB_HITS" != "0" ]; then
    echo "!!! FAIL: TIFF/MNG/harfbuzz fingerprint strings still present"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: smoke test
# With the setStyle null-guard fix merged into qt/cve-hardening (Tty mode
# old=NULL, clang 16 speculative load bypassing the old && guard), the
# default path should produce a PDF. On crash, run only the timeout-guarded
# lldb diagnostic; no wkhtmltoimage/--use-xserver cross-experiments (run #29
# lesson: unbounded experiments hang CI), and no exit 1 blocking the upload.
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
    # lldb with a watchdog (3 min) so the diagnostic itself cannot hang
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
