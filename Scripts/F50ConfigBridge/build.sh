#!/bin/sh
# 用 Android D8 构建固定路径助手；只把 dex 打包入 App，不依赖用户设备安装 Java 开发环境。
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sdk=${ANDROID_SDK_ROOT:-"$HOME/Library/Android/sdk"}
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
javac --release 8 -classpath "$sdk/platforms/android-36.1/android.jar" -d "$build_dir" "$source_dir"/*.java
"$sdk/build-tools/36.1.0/d8" --min-api 26 --lib "$sdk/platforms/android-36.1/android.jar" --output "$build_dir" "$build_dir"/*.class
if test "${1:-}" = --check; then
    cmp "$build_dir/classes.dex" "$source_dir/../../FlowDeck/Resources/F50ConfigBridge.dex"
else
    cp "$build_dir/classes.dex" "$source_dir/../../FlowDeck/Resources/F50ConfigBridge.dex"
fi
shasum -a 256 "$source_dir/../../FlowDeck/Resources/F50ConfigBridge.dex"
