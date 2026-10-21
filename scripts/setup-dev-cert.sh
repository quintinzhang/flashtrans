#!/bin/bash
# 一次性：生成本地代码签名证书并导入登录钥匙串。
# 作用：FlashTrans 每次重装用同一身份签名，「辅助功能」授权不再失效（ad-hoc 签名每次都变，TCC 不认）。
# 首次 codesign 使用时系统可能弹一次「codesign 想使用密钥」，点「始终允许」即可。
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="FlashTrans Dev"
# 注意：自签证书不受系统信任，find-identity 必须去掉 -v 才能列出（CSSMERR_TP_NOT_TRUSTED 不影响 codesign）
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "证书已存在：$IDENTITY（无需重复导入）"
    exit 0
fi

CERT_DIR="build/dev-cert"
mkdir -p "$CERT_DIR"
echo "==> 生成自签代码签名证书（10 年有效期，仅本机使用）"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/flashtrans-dev.key" \
    -out "$CERT_DIR/flashtrans-dev.crt" \
    -days 3650 \
    -subj "/CN=$IDENTITY/O=FlashTrans Local" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" 2>/dev/null

openssl pkcs12 -export -legacy \
    -out "$CERT_DIR/flashtrans-dev.p12" \
    -inkey "$CERT_DIR/flashtrans-dev.key" \
    -in "$CERT_DIR/flashtrans-dev.crt" \
    -passout pass:flashtrans-local 2>/dev/null

echo "==> 导入登录钥匙串（授权 /usr/bin/codesign 使用）"
security import "$CERT_DIR/flashtrans-dev.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "flashtrans-local" -T /usr/bin/codesign

rm -f "$CERT_DIR/flashtrans-dev.key" "$CERT_DIR/flashtrans-dev.p12" # 私钥留在钥匙串里即可

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "✅ 完成。以后 make-app.sh 会自动用「$IDENTITY」签名。"
else
    echo "❌ 导入后未找到 identity，请手动检查：security find-identity -p codesigning"
    exit 1
fi
