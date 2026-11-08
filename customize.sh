#!/bin/bash
# 在 `make defconfig` 之前、于源码根目录（wrt/）执行。
# 路线 B 由 build-hg5585f-ct.yml 直接调用；路线 A 由 Scripts/HG5585F-CT-defaults.sh 调用。
#
# 做四件事：
#   1. 默认 IP / 主机名 / SSID
#   2. 默认时区 UTC+8（Asia/Shanghai）与国内 NTP 服务器
#   3. 生成 files/etc/apk/repositories.d/distfeeds.list（北大镜像，精确 6 条）
#   4. 可选：注入 apk 软件源公钥
# 所有默认值都能用同名环境变量覆盖；脚本只做"存在才改"的安全替换。

set -euo pipefail

# ---- 定位源码根目录 ----
if [ ! -f package/base-files/files/bin/config_generate ]; then
  for d in wrt "${GITHUB_WORKSPACE:-}/wrt" "${GITHUB_WORKSPACE:-}"; do
    [ -n "$d" ] || continue
    if [ -f "$d/package/base-files/files/bin/config_generate" ]; then
      cd "$d"
      break
    fi
  done
fi
if [ ! -f package/base-files/files/bin/config_generate ]; then
  echo "WARN: 未找到 OpenWrt 源码根目录，跳过默认设置改写（不影响编译）" >&2
  exit 0
fi

# ---- 可覆盖的默认值 ----
WRT_IP="${WRT_IP:-192.168.1.1}"
WRT_NAME="${WRT_NAME:-HG5585F-CT}"
WRT_SSID="${WRT_SSID:-HG5585F-CT}"
WRT_WORD="${WRT_WORD:-12345678}"

# POSIX TZ 字符串：<+08>-8 = UTC+8 且无夏令时；LuCI 里对应 Asia/Shanghai
WRT_TZ="${WRT_TZ:-<+08>-8}"
WRT_ZONENAME="${WRT_ZONENAME:-Asia/Shanghai}"
WRT_NTP="${WRT_NTP:-1}"                       # 0 = 保留源码自带的境外 NTP
WRT_REPO_BASE="${WRT_REPO_BASE:-https://mirrors.pku.edu.cn/immortalwrt/snapshots}"
WRT_TARGET_SUBTARGET="${WRT_TARGET_SUBTARGET:-airoha/an7581}"
WRT_ARCH_PACKAGES="${WRT_ARCH_PACKAGES:-aarch64_cortex-a53}"
WRT_APK_FEEDS="${WRT_APK_FEEDS:-base luci packages routing telephony}"

CFG="package/base-files/files/bin/config_generate"
WIFI_UC="package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

# ---- 1. IP / 主机名 / SSID ----
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG"
sed -i "s|set system\.@system\[-1\]\.hostname='[^']*'|set system.@system[-1].hostname='$WRT_NAME'|" "$CFG"
echo "customize: default IP=$WRT_IP hostname=$WRT_NAME"

if [ -f "$WIFI_UC" ]; then
  sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g; s/key '.*'/key '$WRT_WORD'/g" "$WIFI_UC"
  echo "customize: default SSID=$WRT_SSID"
else
  echo "customize: $WIFI_UC not found, skip SSID" >&2
fi

# ---- 2. 时区 + 国内 NTP ----
# config_generate 出厂默认是 timezone='GMT0' / zonename='UTC'，
# 且 NTP 指向 time.apple.com / google / cloudflare / pool.ntp.org。
sed -i "s|timezone='[^']*'|timezone='$WRT_TZ'|" "$CFG"
sed -i "s|zonename='[^']*'|zonename='$WRT_ZONENAME'|" "$CFG"
echo "customize: timezone=$WRT_TZ zonename=$WRT_ZONENAME"

if [ "$WRT_NTP" = "1" ]; then
  sed -i \
    -e "s|time\.apple\.com|ntp.aliyun.com|g" \
    -e "s|time1\.google\.com|time1.cloud.tencent.com|g" \
    -e "s|time\.cloudflare\.com|ntp.ntsc.ac.cn|g" \
    -e "s|pool\.ntp\.org|cn.pool.ntp.org|g" "$CFG"
  echo "customize: NTP -> ntp.aliyun.com / time1.cloud.tencent.com / ntp.ntsc.ac.cn / cn.pool.ntp.org"
fi

# ---- 3. 国内 apk 软件源 ----
# VERSION_REPO 只决定编译期自动生成的 distfeeds.list 域名；这里用 files/ 覆盖成
# 精确的 6 条，去掉镜像上并不存在的 pon_drivers / pon_userspace / video 源。
mkdir -p files/etc/apk/repositories.d
{
  echo "# 国内软件源（北大镜像），由 customize.sh 生成。"
  echo "# 该文件会覆盖编译期自动生成的 distfeeds.list；自定义源请写进 customfeeds.list。"
  echo "$WRT_REPO_BASE/targets/$WRT_TARGET_SUBTARGET/packages/packages.adb"
  for feed in $WRT_APK_FEEDS; do
    echo "$WRT_REPO_BASE/packages/$WRT_ARCH_PACKAGES/$feed/packages.adb"
  done
} > files/etc/apk/repositories.d/distfeeds.list
echo "customize: wrote files/etc/apk/repositories.d/distfeeds.list"
cat files/etc/apk/repositories.d/distfeeds.list | sed 's/^/    /'

# ---- 4. 可选：apk 软件源公钥 ----
# 自编译固件默认只信任本地 build key，从官方镜像装包可能报 UNTRUSTED signature。
# 把公钥 URL 传进来即可随固件注入；留空则不影响编译。
if [ -n "${APK_REPO_KEY_URL:-}" ]; then
  mkdir -p files/etc/apk/keys
  if curl -fsSL --max-time 60 "$APK_REPO_KEY_URL" \
      -o files/etc/apk/keys/immortalwrt-official.pem; then
    echo "customize: apk repo key injected"
  else
    echo "WARN: apk 公钥下载失败，跳过（不影响编译）" >&2
    rm -f files/etc/apk/keys/immortalwrt-official.pem
  fi
fi

# ---- 追加自定义配置行（可选） ----
if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -f "$GITHUB_WORKSPACE/Config-EXTRA.txt" ]; then
  echo "customize: appending Config-EXTRA.txt"
  cat "$GITHUB_WORKSPACE/Config-EXTRA.txt" >> .config
fi

# 提示：不要在这里注入 root 密码或 PON 身份。
# PON SN / MAC / LOID 在 factory UBI 卷里，属于设备数据，不进固件。
