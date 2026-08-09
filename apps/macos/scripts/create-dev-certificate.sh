#!/bin/bash
# 開発ビルド用のコード署名証明書をログインキーチェーンに作る。
#
# ad-hoc 署名（CODE_SIGN_IDENTITY: "-"）はビルドごとに cdhash が変わるため、
# TCC がアプリを別物と見なして画面収録の許可が失効する。安定した署名 ID があれば
# Designated Requirement が証明書ベースになり、リビルドしても許可が維持される。
#
# Apple Development 証明書を用意したら、この証明書は不要になる。
# `project.yml` の CODE_SIGN_IDENTITY を差し替えるだけで移行できる。

set -euo pipefail

NAME="DoppelScreen Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "証明書「$NAME」は既に存在します。"
    security find-identity -v -p codesigning
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null

# Security.framework は空パスワードの PKCS#12 を読めず、OpenSSL 3 既定の
# AES-256-CBC + PBKDF2 も受け付けない。使い捨てのパスワードと -legacy で書き出す
PASSWORD="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout "pass:$PASSWORD"

# -T /usr/bin/codesign: codesign から鍵を使うたびに確認ダイアログが出ないようにする
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security

# コード署名用途の信頼設定を入れないと find-identity が有効な ID として扱わない
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "証明書「$NAME」を作成しました。"
security find-identity -v -p codesigning
echo
echo "初回のビルドでキーチェーンの確認ダイアログが 1 回だけ出ます。「常に許可」を押してください。"
echo "（非対話で抑えるには security set-key-partition-list が要りますが、"
echo "  ログインキーチェーンのパスワード入力が必要になるため、ここでは行いません）"
