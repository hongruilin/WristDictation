#!/bin/bash
# ============================================================
# 腕上听写 —— 未签名 IPA 重签脚本
#
# 作用：用你的 p12 / 描述文件，把未签名 IPA 签成可侧载安装的 IPA。
# 关键点：Watch App 是嵌套 bundle，必须先用它自己的描述文件单独签名，
#        再签外层 iOS App，否则安装报 "Watch app is invalid"。
#
# 用法：
#   ./Tools/sign_ipa.sh \
#     -a WristDictation-1.0-unsigned.ipa \
#     -i "Apple Development: your@mail.com (XXXXXXXXXX)" \
#     -m ios.mobileprovision \
#     -w watch.mobileprovision \
#     -o WristDictation-signed.ipa
#
# 用 p12 直接签（会临时建一个钥匙串，签完自动删）：
#   ./Tools/sign_ipa.sh -a xxx.ipa -k cert.p12 -p 'p12密码' \
#     -m ios.mobileprovision -w watch.mobileprovision -o out.ipa
#
# 看可用签名身份：
#   security find-identity -v -p codesigning
# ============================================================

set -euo pipefail

IPA=""; IDENTITY=""; P12=""; P12PASS=""
IOS_PROFILE=""; WATCH_PROFILE=""; OUT=""
BUNDLE_ID=""; TEAM_ID=""

die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '\033[36m• %s\033[0m\n' "$1"; }
ok() { printf '\033[32m✓ %s\033[0m\n' "$1"; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while getopts "a:i:k:p:m:w:o:b:t:h" opt; do
  case $opt in
    a) IPA="$OPTARG" ;;
    i) IDENTITY="$OPTARG" ;;
    k) P12="$OPTARG" ;;
    p) P12PASS="$OPTARG" ;;
    m) IOS_PROFILE="$OPTARG" ;;
    w) WATCH_PROFILE="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    b) BUNDLE_ID="$OPTARG" ;;
    t) TEAM_ID="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

[ -n "$IPA" ] || die "缺少 -a 指定 IPA"
[ -f "$IPA" ] || die "IPA 不存在：$IPA"
[ -n "$IOS_PROFILE" ] || die "缺少 -m 指定 iOS 描述文件"
[ -f "$IOS_PROFILE" ] || die "描述文件不存在：$IOS_PROFILE"
[ -n "$WATCH_PROFILE" ] && [ -f "$WATCH_PROFILE" ] || die "缺少 -w 指定 Watch 描述文件（见 SIGN_GUIDE.md，这一步不能省）"
[ -n "$OUT" ] || OUT="${IPA%.ipa}-signed.ipa"

WORK=$(mktemp -d /tmp/wdsign.XXXXXX)
TMPKC=""
ORIG_KC=""
cleanup() {
  # 还原钥匙串搜索列表，别留下副作用
  if [ -n "$ORIG_KC" ]; then
    security list-keychains -d user -s $ORIG_KC >/dev/null 2>&1 || true
  fi
  if [ -n "$TMPKC" ]; then
    security delete-keychain "$TMPKC" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- 1. 准备签名身份 ----------
if [ -n "$P12" ]; then
  [ -f "$P12" ] || die "p12 不存在：$P12"
  [ -n "$P12PASS" ] || die "使用 -k 时必须用 -p 提供 p12 密码"
  TMPKC="$WORK/sign.keychain-db"
  info "创建临时钥匙串并导入 p12"
  security create-keychain -p "wdsign" "$TMPKC" >/dev/null
  security set-keychain-settings -lut 3600 "$TMPKC" >/dev/null
  security unlock-keychain -p "wdsign" "$TMPKC" >/dev/null
  security import "$P12" -k "$TMPKC" -P "$P12PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null \
    || die "p12 导入失败（密码错误或文件损坏）"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "wdsign" "$TMPKC" >/dev/null 2>&1 || true
  IDENTITY=$(security find-identity -v -p codesigning "$TMPKC" | awk -F'"' '/Apple (Development|Distribution)/{print $2; exit}')
  [ -n "$IDENTITY" ] || die "临时钥匙串里没找到可用的签名身份"
  # codesign 只认搜索列表里的钥匙串，临时键要挂进去，签完还原
  ORIG_KC=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
  security list-keychains -d user -s "$TMPKC" $ORIG_KC >/dev/null
  SIGN_ARGS=(--keychain "$TMPKC")
else
  [ -n "$IDENTITY" ] || die "缺少 -i 签名身份，或用 -k/-p 提供 p12"
  SIGN_ARGS=()
fi
ok "签名身份：$IDENTITY"

# ---------- 2. 解包 ----------
info "解包 IPA"
unzip -q "$IPA" -d "$WORK" || die "解包失败"
APP=$(find "$WORK/Payload" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || die "IPA 里没有 Payload/*.app"
WATCH=$(find "$APP" -maxdepth 3 -type d -name "*.app" | head -1)
[ -n "$WATCH" ] || die "IPA 里没有嵌套的 Watch App"
[ -f "$APP/Info.plist" ] || die "缺少 Info.plist"
[ -f "$WATCH/Info.plist" ] || die "Watch App 缺少 Info.plist"
ok "iOS App：$(basename "$APP")"
ok "Watch App：$(basename "$WATCH")"

# ---------- 3. 读取描述文件 ----------
read_profile() {
  local src=$1 dst=$2
  security cms -D -i "$src" > "$dst" 2>/dev/null || die "无法解析描述文件：$src"
  plutil -extract Entitlements xml1 -o "${dst%.plist}.entitlements" "$dst" 2>/dev/null \
    || die "描述文件里没有 Entitlements：$src"
}
read_profile "$IOS_PROFILE" "$WORK/ios-profile.plist"
read_profile "$WATCH_PROFILE" "$WORK/watch-profile.plist"

# application-identifier 形如 TEAMID.com.foo.bar
IOS_APPID=$(plutil -extract Entitlements.application-identifier raw "$WORK/ios-profile.plist" 2>/dev/null || echo "")
WATCH_APPID=$(plutil -extract Entitlements.application-identifier raw "$WORK/watch-profile.plist" 2>/dev/null || echo "")
[ -n "$IOS_APPID" ] || die "iOS 描述文件缺少 application-identifier"
PROFILE_TEAM=${IOS_APPID%%.*}
PROFILE_BID=${IOS_APPID#*.}
[ -n "$TEAM_ID" ] || TEAM_ID="$PROFILE_TEAM"
ok "描述文件 Team：$TEAM_ID"
ok "描述文件 Bundle ID：$PROFILE_BID"

# ---------- 4. 对齐 Bundle ID ----------
# 未签名 IPA 里是占位 ID，必须改成描述文件允许的 ID，否则安装报签名不匹配。
if [ -z "$BUNDLE_ID" ]; then
  BUNDLE_ID="$PROFILE_BID"
fi
if [ -n "$WATCH_APPID" ]; then
  WATCH_BID=${WATCH_APPID#*.}
else
  WATCH_BID="${BUNDLE_ID}.watchkitapp"
fi

CUR_IOS=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")
CUR_WATCH=$(plutil -extract CFBundleIdentifier raw "$WATCH/Info.plist")
info "改写 Bundle ID：$CUR_IOS → $BUNDLE_ID"
info "改写 Watch ID ：$CUR_WATCH → $WATCH_BID"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Info.plist"
plutil -replace CFBundleIdentifier -string "$WATCH_BID" "$WATCH/Info.plist"
plutil -replace WKCompanionAppBundleIdentifier -string "$BUNDLE_ID" "$WATCH/Info.plist"

# 描述文件要求 bundle id 与 Entitlements 中的 application-identifier 严格一致
if [ "$BUNDLE_ID" != "$PROFILE_BID" ]; then
  die "Bundle ID（$BUNDLE_ID）与 iOS 描述文件（$PROFILE_BID）不一致，请用 -b 指定描述文件里的那个 ID"
fi
if [ -n "$WATCH_APPID" ] && [ "$WATCH_BID" != "${WATCH_APPID#*.}" ]; then
  die "Watch Bundle ID（$WATCH_BID）与 Watch 描述文件（${WATCH_APPID#*.}）不一致"
fi

# ---------- 5. 清理旧签名 ----------
find "$APP" -name "_CodeSignature" -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$APP" -name "embedded.mobileprovision" -delete 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

# ---------- 6. 先签 Watch（嵌套），再签外层 ----------
info "签名 Watch App"
cp "$WATCH_PROFILE" "$WATCH/embedded.mobileprovision"
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  --entitlements "$WORK/watch-profile.entitlements" \
  --timestamp=none --generate-entitlement-der "$WATCH" \
  || die "Watch App 签名失败"
ok "Watch App 已签名"

info "签名 iOS App"
cp "$IOS_PROFILE" "$APP/embedded.mobileprovision"
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  --entitlements "$WORK/ios-profile.entitlements" \
  --timestamp=none --generate-entitlement-der "$APP" \
  || die "iOS App 签名失败"
ok "iOS App 已签名"

# ---------- 7. 校验 ----------
info "校验签名"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -5 || die "签名校验失败"
ok "签名校验通过"

# ---------- 8. 重新打包 ----------
info "重新打包"
rm -f "$OUT"
( cd "$WORK" && zip -qry "$OUT" Payload ) || die "打包失败"
[ -f "$OUT" ] || die "打包产物不存在"

echo
ok "完成：$OUT"
ls -lh "$OUT" | awk '{print "  大小：" $5}'
shasum -a 256 "$OUT" | awk '{print "  SHA256：" $1}'
echo
echo "安装前建议再确认一次 Watch App 还在："
echo "  unzip -l \"$OUT\" | grep 'Watch/.*\\.app/'"
