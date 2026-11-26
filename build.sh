#!/bin/bash
# 编译、打包、签名 WeChat-Push.app
# 签名标识与证书保持不变，重新构建不会使已有的系统权限失效

set -euo pipefail

cd "$(dirname "$0")"

APP="$HOME/Applications/WeChat-Push.app"
BINARY="$APP/Contents/MacOS/WeChat-Push"
# 沿用旧标识：改掉会让辅助功能、完全磁盘访问两项系统授权失效
BUNDLE_ID="com.wwj.wechat2push"

# 默认用本机第一个 Apple Development 证书。没有证书时退回临时签名，
# 临时签名每次重新构建都会变，系统会要求重新授权辅助功能。
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')}"

SOURCES=(
    main.swift
    FeishuBot.swift
    ReplyRouter.swift
    WeChatSender.swift
)

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "配置"
if [ ! -f "$APP/Contents/Info.plist" ]; then
    cp Info.plist "$APP/Contents/Info.plist"
fi

echo "图标"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "编译"
swiftc -O \
    -o "$BINARY" \
    "${SOURCES[@]}" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework IOKit \
    -lsqlite3

echo "签名"
if [ -n "$SIGN_ID" ]; then
    codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo "校验"
codesign --verify --verbose=2 "$APP"

echo "完成：$APP"
