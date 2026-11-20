#!/bin/bash
# WhalePet 打包脚本 — 保证素材完整
set -euo pipefail

SRC="/tmp/whale_pet_live2d"
APP="$HOME/Desktop/WhalePet.app"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
export CLANG_MODULE_CACHE_PATH=/tmp/whalepet-clang-cache

echo "=== 1. 编译 ==="
mkdir -p "$CLANG_MODULE_CACHE_PATH"
/usr/bin/swiftc -sdk "$SDK" -O "$SRC/shell.swift" -o /tmp/WhalePet_bin 2>&1 | tee /tmp/build_out.txt
ERR=$(grep -cE ' error' /tmp/build_out.txt || true)
echo "ERRORS=$ERR"
if [ "$ERR" != "0" ]; then echo "编译失败"; exit 1; fi

echo "=== 2. 停旧进程 ==="
pkill -f "MacOS/WhalePet" 2>/dev/null || true
pkill -f "whalepet_tts.py" 2>/dev/null || true
sleep 1

echo "=== 3. 重建 app 包 ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp /tmp/WhalePet_bin "$APP/Contents/MacOS/WhalePet"
chmod +x "$APP/Contents/MacOS/WhalePet"

# Info.plist
cat > "$APP/Contents/Info.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WhalePet</string>
  <key>CFBundleIdentifier</key><string>com.dafeiyu.whalepet</string>
  <key>CFBundleName</key><string>WhalePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLISTEOF

echo "=== 4. 复制资源（全部，逐项校验）==="
# HTML + python helper
cp "$SRC/index.html" "$APP/Contents/Resources/"
cp "$SRC/whalepet_tts.py" "$APP/Contents/Resources/" 2>/dev/null || true

# vendor 引擎（必须 3 个）
mkdir -p "$APP/Contents/Resources/vendor"
cp -R "$SRC/vendor/." "$APP/Contents/Resources/vendor/"

# 模型全套
mkdir -p "$APP/Contents/Resources/model/c_0120.2048"
cp -R "$SRC/model/." "$APP/Contents/Resources/model/"

echo "=== 5. 完整性校验 ==="
FAIL=0
check() { if [ ! -s "$1" ]; then echo "  ❌ 缺失: $1"; FAIL=1; else echo "  ✓ $(basename "$1") $(stat -f%z "$1")字节"; fi; }
for f in "$APP/Contents/Resources/index.html" \
         "$APP/Contents/Resources/vendor/pixi.min.js" \
         "$APP/Contents/Resources/vendor/cubism4.min.js" \
         "$APP/Contents/Resources/vendor/live2dcubismcore.min.js" \
         "$APP/Contents/Resources/model/c_0120.model3.json" \
         "$APP/Contents/Resources/model/c_0120.moc3" \
         "$APP/Contents/Resources/model/c_0120.physics3.json" \
         "$APP/Contents/Resources/model/c_0120.2048/texture_00.png" \
         "$APP/Contents/Resources/model/c_0120.2048/texture_01.png"; do
  check "$f"
done
if [ "$FAIL" != "0" ]; then echo "资源不完整，中止"; exit 1; fi

echo "=== 6. ad-hoc 签名 ==="
codesign --force --deep --sign - "$APP" 2>&1 | tail -2

echo "=== 7. 启动 ==="
open "$APP"
sleep 4
echo "=== 8. 验证 ==="
pgrep -f "MacOS/WhalePet" | head -1 | xargs -I{} echo "  进程 PID: {}"
curl -s -m 5 -o /dev/null -w "  本地server: HTTP %{http_code}\n" "http://127.0.0.1:8977/index.html"
echo "=== 打包完成 ==="
