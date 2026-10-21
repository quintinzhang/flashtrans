#!/bin/bash
# 构建 FlashTrans.app 并安装到本机（ad-hoc 签名，仅本机使用）
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build (release)"
swift build -c release

APP="build/FlashTrans.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FlashTrans "$APP/Contents/MacOS/FlashTrans"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FlashTrans</string>
    <key>CFBundleDisplayName</key><string>闪译 FlashTrans</string>
    <key>CFBundleExecutable</key><string>FlashTrans</string>
    <key>CFBundleIdentifier</key><string>com.zq.flashtrans</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>本机自用</string>
</dict>
</plist>
PLIST

echo "==> 签名"
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | grep -o '"FlashTrans Dev"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
    echo "    使用固定开发证书：${IDENTITY}（重装不丢辅助功能授权）"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "    未找到 FlashTrans Dev 证书（可先跑 scripts/setup-dev-cert.sh），回退 ad-hoc 签名"
    codesign --force --sign - "$APP"
fi

# 退出可能正在运行的实例（bundle 方式与裸进程都处理）
osascript -e 'tell application "FlashTrans" to quit' >/dev/null 2>&1 || true
sleep 0.5
pkill -x FlashTrans >/dev/null 2>&1 || true

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
fi
echo "==> 安装到 $DEST"
rm -rf "$DEST/FlashTrans.app"
cp -R "$APP" "$DEST/FlashTrans.app"
xattr -dr com.apple.quarantine "$DEST/FlashTrans.app" 2>/dev/null || true

if [ -d "$HOME/.local/bin" ] || [ -f "$HOME/.local/bin/zcc" ]; then
    mkdir -p "$HOME/.local/bin"
    cp cli/glmtrans "$HOME/.local/bin/glmtrans"
    chmod +x "$HOME/.local/bin/glmtrans"
    echo "==> CLI 已安装：~/.local/bin/glmtrans"
fi

echo ""
echo "✅ 完成：$DEST/FlashTrans.app"
echo "   首次使用：1) 打开 app  2) 系统设置 → 隐私与安全性 → 辅助功能 勾选 FlashTrans"
echo "            3) 菜单栏 FlashTrans 图标 → 设置… 填入智谱 API Key  4) 选中文字按 ⌥D"
