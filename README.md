# HG5585F-CT
PonWRT HG5585F-CT for selfuse
云编译固件仅供自用，除包含vlmcsd+tailscale外无其他添加，参考教程如下
# HG5585F-CT 云编译固件搭建指南

日期：2026-11-08（当日追加第七节：新增软件包 / UTC+8 默认设置 / 国内 apk 软件源）
目标设备：**FiberHome HG5585F CT**（Airoha AN7581 / EN7581，SPI-NAND + UBI）
调研对象：`VIKINGYFY/OpenWRT-CI`、`pbs05/ponwrt`、`pbs05/openwrt-pon-drivers`、`pbs05/openwrt-pon-userspace`
设备现状：这台机器已在运行 ImmortalWRT SNAPSHOT `airoha/an7581`、内核 6.18.55、管理地址 `192.168.1.1`（root/admin），PPPoE 移动 CGNAT；因此本指南按 **sysupgrade 升级自编译固件** 场景写，不需要从原厂重刷。

---

## 一、四个仓库到底各干什么

我逐个核对了文件树、workflow、feeds 与设备定义，关系如下：

```
   pbs05/openwrt-pon-drivers  ──┐
     kmod-airoha-pon-frontend    │  src-git 方式被当作 feed 引用
     kmod-airoha-paged-bosa      │
     kmod-airoha-xpon            │
                                 ├──?  pbs05/ponwrt  （编译源码基座）
   pbs05/openwrt-pon-userspace ──┤      基于 ImmortalWrt，含 target/linux/airoha/
     airoha-pond (Rust)          │      HG5585F-CT DTS / image Makefile /
     airoha-ponctl (Rust)        │      configs/an7581.config / release.yml
     luci-app-pon / luci-app-iptv│      feeds.conf.default 里已写好两个 PON feed
                                 │
   VIKINGYFY/OpenWRT-CI ─────────┴──?  GitHub Actions 编排模板
     WRT-CORE.yml（通用编译核心）        默认源码 VIKINGYFY/immortalwrt@owrt，
     Config/*.txt、Scripts/*.sh          该分支已合入 pbs05 的 airoha 改动
```

| 仓库 | 角色 | 是否要手动 clone |
|---|---|---|
| `pbs05/ponwrt` | 源码本体（ImmortalWrt fork + AN7581 target） | 是（CI 自动 clone） |
| `pbs05/openwrt-pon-drivers` | 内核驱动 feed：`airoha-xpon`、光前端（EN7572 / GN28L95 / UX3363） | **否**，`feeds.conf.default` 自动拉 |
| `pbs05/openwrt-pon-userspace` | 用户态 feed：`airoha-pond`(OMCI/OAM)、`airoha-ponctl`、`luci-app-pon`、`luci-app-iptv` | **否**，同上 |
| `VIKINGYFY/OpenWRT-CI` | 云编译模板：依赖安装、feeds、配置合并、编译、缓存、发 Release | 只需 fork |

关键证据：

- `pbs05/ponwrt/feeds.conf.default` 末两行就是 `src-git pon_drivers ...` 和 `src-git pon_userspace ...`。
- `VIKINGYFY/immortalwrt@owrt` 的 `feeds.conf.default` 与之**完全相同**，且 `target/linux/airoha/dts/an7581-fiberhome-hg5585f-ct.dts` 与 pbs05 版逐字节一致 —— 所以 VIKINGYFY 的 CI 默认源码就能编这台机器。
- `Config/AIROHA-AN7581.txt` 只有 `CONFIG_TARGET_airoha=y` / `an7581=y` / `ALL_PROFILES=y`。
- **`Config/GENERAL.txt` 第 19–20 行是 `CONFIG_FEED_pon_drivers=n` 和 `CONFIG_FEED_pon_userspace=n`** —— 这是全套资源里最大的坑，见第四节。

### 设备适配点（已在源码里核实，无需自己写 DTS）

| 项目 | 值 |
|---|---|
| Target / Subtarget | `airoha` / `an7581`，架构 `aarch64_cortex-a53` |
| Profile | `fiberhome_hg5585f-ct`（`target/linux/airoha/image/an7581.mk`） |
| DTS | `an7581-fiberhome-hg5585f-ct.dts` → `...-ct-common.dtsi` → `...-common.dtsi` |
| CT 特有 | GPY211C 2.5G PHY → `kmod-phy-maxlinear`；CU 版没有 |
| 固件形态 | `IMAGES := sysupgrade.itb`（FIT）、`KERNEL_IN_UBI := 1`、`UBOOTENV_IN_UBI := 1`；另有 initramfs `-recovery.itb` |
| 默认包 | `kmod-airoha-paged-bosa kmod-airoha-xpon airoha-ponctl airoha-pond kmod-mt7915e kmod-mt7916-firmware wpad-openssl fitblk nand-utils ubi-utils` |
| 校准/身份数据 | `factory` UBI 卷（1 MiB），`board.d/03_pon_data` 声明；**PON SN / MAC / WiFi 校准都在这里** |
| sysupgrade 前置 | `platform.sh` 的 `airoha_require_ubi_layout factory`：要求 `fip`/`ubootenv`/`ubootenv2`/`factory` 四个卷齐全，否则拒绝升级 |

从原厂首次刷入时还缺 3 个配套仓库（本次给的 4 个里不含）：`pbs05/an758x-stock2ubi`（备份原厂 + 建 UBI 布局）、`pbs05/uboot-an758x`（U-Boot + Web 恢复）、`pbs05/fiberhome-factory`（把烽火原厂 factory 转成 PonWrt 用的格式）。**你这台已经是 PonWrt 类固件，用不到它们。**

---

## 二、三条路线，怎么选

| 路线 | 做法 | 优点 | 缺点 | 适合 |
|---|---|---|---|---|
| **A. fork VIKINGYFY/OpenWRT-CI** | 改 4 处配置，复用 `WRT-CORE.yml` | 现成的默认 IP/SSID/主题定制、ccache、Release、每天自动编译 | `Packages.sh` 会塞一堆第三方插件；源码是 VIKINGYFY 合并版，PON 更新略滞后 | 想少折腾、想顺手加插件 |
| **B. 自包含 workflow（推荐）** | 新建空仓库，放我给的 `build-hg5585f-ct.yml`，直接编 `pbs05/ponwrt@master` | 源码最新、只编一台设备、无多余插件、完全可控 | 要自己维护 workflow | **追求稳定可复现 / 追最新 PON 驱动** |
| C. 直接 fork `pbs05/ponwrt` | 用它自带的 `.github/workflows/release.yml` | 零改动，与上游完全一致 | 一次编 AN7581+AN7583 全部机型，慢；产物是 `tar.zst` 包 | 只想验证能不能编出来 |

**推荐 B**，A 作为"想用 VIKINGYFY 那套主题/插件体系"时的备选。两套的可直接使用的文件都已经放在 `hg5585f-ct-cloudbuild/`。

---

## 三、路线 B：自包含 workflow（推荐）

### 3.1 建仓库

1. GitHub 新建**公开**仓库（公开仓库 Actions 免费；私有仓库有额度限制），例如 `hg5585f-ct-build`。
2. 把 `hg5585f-ct-cloudbuild/` 里的文件按下面结构放进去：

```
.github/workflows/build-hg5585f-ct.yml   <- build-hg5585f-ct.yml
Config-HG5585F-CT.txt                     <- 单设备 + PON + 6 个新增包 + 国内源
customize.sh                              <- 时区/NTP/主机名/IP/SSID + 生成 apk 源
files/etc/uci-defaults/99-hg5585f-ct      <- 首次开机兜底（时区/NTP/软件源）
```
`files/` 现在承载实际默认设置，别删；详见第七节。想额外放 SSH 公钥、apk 公钥等，也往这个目录里加。
（也可以在 fork 出来的 `pbs05/ponwrt` 里加 `.github/workflows/` 这一个文件 + 三个资产文件，效果一样。）

3. `Settings → Actions → General → Workflow permissions` 选 **Read and write**（发 Release 需要）；保存。

### 3.2 触发

`Actions → Build PonWrt HG5585F-CT → Run workflow`

- 第一次勾 **`test_only=true`**：只生成并上传 `Config-final.txt`，几分钟就能验配置，不浪费 3 小时编译。
- 确认配置里有 `CONFIG_TARGET_DEVICE_..._fiberhome_hg5585f-ct=y`、两个 `CONFIG_FEED_pon_*=y`、`kmod-airoha-xpon/airoha-pond/luci-app-pon=y`，以及第七节那 6 个新增包都是 `=y` 之后，再正常跑一次（`test_only=false`）。Configure 步骤会自动硬断言这 6 个包，缺一个直接失败。
- `create_release=true` 会额外发一个 Release；`source_ref` 可填某个 commit/tag 锁版本，便于复现。
- `apk_repo_key_url` 可选：填 apk 官方源公钥 URL，解决日后在线装包报 `UNTRUSTED signature`（见 7.3）。

### 3.3 配置是怎么拼出来的

workflow 里：

```sh
cp configs/an7581.config .config                 # pbs05 官方 AN7581 全量基线
cat Config-HG5585F-CT.txt >> .config            # 单设备 + PON + 6 个新增包 + 国内源
bash customize.sh                               # 改 config_generate（时区/NTP/IP/SSID）+ 生成 apk 源
make defconfig                                  # 归一化 + 断言（6 包 / PON feed / 源条数）
```

kconfig 是"后出现的值覆盖前出现的值"，所以覆盖片段必须追加在基础配置之后。`customize.sh` 还会在 `files/etc/apk/repositories.d/` 下生成 `distfeeds.list`，与仓库里静态的 `files/etc/uci-defaults/99-hg5585f-ct` 一起被 OpenWrt 覆盖进 rootfs。想预置 `/etc/config/*`、SSH 公钥、apk 公钥也放 `files/`。**但不要把 PON 身份、SN、MAC、校准数据放进固件。**

### 3.4 产物

`bin/targets/airoha/an7581/` 里含 `fiberhome_hg5585f-ct` 字样的文件，主要是：

- `...-squashfs-sysupgrade.itb` —— LuCI / `sysupgrade` 升级用
- `...-recovery.itb`（initramfs，`CONFIG_TARGET_ROOTFS_INITRAMFS=y` 生成）—— U-Boot Web 恢复用
- `Config-final.txt`、`source-commit.txt`、`sha256sums.txt`

下载 artifact 后先 `sha256sum -c sha256sums.txt`。

---

## 四、路线 A：fork VIKINGYFY/OpenWRT-CI

### 4.1 一键改法

```bash
git clone https://github.com/<你的账号>/OpenWRT-CI.git
cd OpenWRT-CI
bash /path/to/hg5585f-ct-cloudbuild/route-vikingyfy/patch-ci.sh
git add -A && git commit -m 'HG5585F-CT build' && git push
```

脚本做 4 件事（都可 `git diff` 复核，重复执行幂等）：

1. `Config/AIROHA-AN7581.txt` → 换成单设备版 `route-vikingyfy/AIROHA-AN7581.txt`（已含 6 个新增包、国内源、时区数据）
2. `Config/GENERAL.txt` → 把 `CONFIG_FEED_pon_drivers=n` / `CONFIG_FEED_pon_userspace=n` 改成 `=y`；**另外**把第 23 行 `CONFIG_TARGET_ROOTFS_INITRAMFS=n` 改成 `=y`，否则 GENERAL.txt 追加在后会把单设备配置里的 `=y` 覆盖掉，不生成 `-recovery.itb`
3. 新增 `.github/workflows/HG5585F-CT.yml`（只编 AN7581、IP 改回 `192.168.1.1`、去掉自动触发）
4. 把 `customize.sh` 复制成 `Scripts/HG5585F-CT-defaults.sh`，并在 `WRT-CORE.yml` 的 Custom Settings 步骤里挂接一行；该行只在 `WRT_CONFIG=AIROHA-AN7581` 时执行，不影响其它 workflow。可选：仓库 Variables 里加 `APK_REPO_KEY_URL`。

> 路线 A 本次**未做验证**（按你的要求只验证路线 B）；如果只走路线 B，第 4 节可以整节跳过。

### 4.2 触发与注意

`Actions → HG5585F-CT → Run workflow`，**第一次务必勾 `TEST`**：CI 会跳过编译，只发一个含 `Config-*.txt` 的 Release，拿来核对 PON feed 是否真的打开了。

- `WRT_PW: 无` 只是 Release 里的说明文字，**不会设置 root 密码**；要改密码请用 `files/` 注入 uci-defaults 或 `Config/PRIVATE.txt`。
- `Scripts/Packages.sh` 会 clone 一大堆主题 / passwall / nikki 等第三方包到 `package/`，对 Airoha 目标并非必需，首次编译若报错可先把该文件清空（保留 `#!/bin/bash` 即可）。
- 原 `AIROHA-ALL.yml` 会被 `Auto-Clean` 每天自动触发，建议在 Actions 页面 Disable，避免重复编译。
- 想换成 pbs05 最新源码：改 `HG5585F-CT.yml` 里 `SOURCE: [pbs05/ponwrt]`、`BRANCH: [master]`。但此时 `WRT-CORE.yml` 的配置拼法（只有几十行的 `.config`）与 pbs05 的 `configs/an7581.config` 不同，更建议直接走路线 B。

---

## 五、必踩的坑（按重要性排序）

1. **PON feed 被关**：`VIKINGYFY/OpenWRT-CI` 的 `Config/GENERAL.txt` 里 `CONFIG_FEED_pon_drivers=n`、`CONFIG_FEED_pon_userspace=n`。`WRT-CORE.yml` 是先 cat `Config/<target>.txt` 再 cat `GENERAL.txt`，后写覆盖前写 —— 不改这两行，编出来的固件没有 `kmod-airoha-xpon`、`airoha-pond`、LuCI PON 页面，PON 根本注册不了。同一个覆盖顺序还会让 `GENERAL.txt` 第 23 行的 `CONFIG_TARGET_ROOTFS_INITRAMFS=n` 盖掉单设备配置，丢掉 `-recovery.itb`。我在 `Config-HG5585F-CT.txt`、workflow 断言和 `patch-ci.sh` 里都做了兜底。
2. **`CONFIG_TARGET_ALL_PROFILES=y`**：会编 AN7581 全部十几个机型，耗时和磁盘成倍上升。只留 `fiberhome_hg5585f-ct` 即可。
3. **Rust 工具链**：`airoha-pond` / `airoha-ponctl` 的 Makefile 是 `PKG_BUILD_DEPENDS:=rust/host` + `rust-package.mk`。首次编译要先构建 host Rust，可能多花几十分钟。VIKINGYFY 的 CI 有 `.github/scripts/prepare-rust.sh`（复用 runner 预装 Rust，需连 `rust-prebuilt.mk` 一起拷）可以加速；pbs05 自带的 `release.yml` 没有这一步，能编但慢。
4. **CI 资源限制**：免费 runner 单次 job 上限 6 小时、根盘约 14 GB。workflow 已清理 dotnet/android 并把构建树放到 `/mnt`；`make -j$(nproc)` 若 OOM 会自动降级为 `make -j1 V=s`。
5. **CT ≠ CU**：CT 变体多 `kmod-phy-maxlinear`（GPY211C 2.5G PHY）。`SUPPORTED_DEVICES` 里 CT 与 CT-USB-SFP 互通，但你这台是 CT，别选 CU 或 USB-SFP 的 DTS。
6. **不要动 `factory` 卷**：`platform.sh` 的 `airoha_require_ubi_layout factory` 会检查 `fip`/`ubootenv`/`ubootenv2`/`factory`；缺卷会直接拒绝 sysupgrade，只能进 U-Boot Web recovery 修布局。PON SN/MAC/WiFi 校准全在 `factory`（1 MiB UBI 卷）里，丢了设备身份就没了。
7. **固件是 `sysupgrade.itb`（FIT），不是 factory.bin**；`fitblk`/`fit_check_sign` 参与升级，别拿错文件。
8. **源码版本**：`VIKINGYFY/immortalwrt@owrt` 已合入 airoha 支持，但同步有滞后；要最新 PON 驱动用 `pbs05/ponwrt@master`。
9. **你本机历史问题**：之前 `/etc/nftables.d/udp2raw-ttl.nft` 与 fw4 的 `mangle_postrouting` 链冲突导致整体无 NAT。自编译固件如果通过 `files/` 注入了自定义 nft 片段，升级后务必 `fw4 check`，别把旧问题带回来。
10. **Actions 的 Node.js 20 警告**：首次运行日志会出现 `checkout@v4` / `upload-artifact@v4` / `action-gh-release@v2` 被强制以 Node 24 运行的注解。它只是警告、不是编译失败，固件不受影响；已升级为 v5 / v6 / v3，详见第十节。

---

## 六、升级到这台设备（建议顺序）

1. 把 `preflight.sh` 传到设备跑一遍（只读检查 + 备份）：
   ```sh
   scp hg5585f-ct-cloudbuild/preflight.sh root@192.168.1.1:/tmp/
   ssh root@192.168.1.1 sh /tmp/preflight.sh
   ```
   它会列出 UBI 卷表、校验四个 sysupgrade 前置卷、备份 `factory` 卷裸镜像与 `sysupgrade -b` 配置包到 `/tmp/hg5585f-ct-preflight-*`，并顺手做一次 `fw4 check`。**把备份目录 scp 回电脑**。

   ?? 这台设备和联通 f7610uv3b 都是 `192.168.1.1`，操作前先按旧报告里的办法用 MAC（`70-D5-1E-35-56-50`）确认连的是烽火这台，别拨错机器。

2. 上传固件，先干跑校验再升级：
   ```sh
   scp ...-fiberhome_hg5585f-ct-squashfs-sysupgrade.itb root@192.168.1.1:/tmp/
   sysupgrade --test /tmp/*.itb          # 触发 fit_check_image / 布局检查
   sysupgrade -v /tmp/*.itb              # 默认保留配置
   ```
3. 起来后核对：`ubus call system board`、`wifi status`、`ip -4 addr show pppoe-wan`、`fw4 check`、`luci-app-pon` 里的 PON 状态、`factory` 卷 sha256 是否与备份一致。
4. 回退：保留上一版 `sysupgrade.itb` + `preflight` 的 factory 镜像 / 配置备份；PonWrt 的 `platform.sh` 走 FIT 升级，正常可再 sysupgrade 回上一版。真起不来就用 `-recovery.itb` 通过 U-Boot Web 恢复。

---

## 七、本轮新增：软件包 / 默认设置 / 国内软件源（路线 B 已验证）

### 7.1 六个软件包：不需要加第三方源

逐个核对了 `immortalwrt/packages` 与 `immortalwrt/luci` 的文件树，六个包**全部在 `pbs05/ponwrt` 已有的两个默认 feed 里**，`./scripts/feeds update -a` 就会拉到，无需 clone 任何第三方软件源：

| 包 | 所在 feed / 路径 | 备注 |
|---|---|---|
| `tailscale` | `immortalwrt/packages` → `net/tailscale` | Go 包，`DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +kmod-tun`；基础 `an7581.config` 已带 `ca-bundle` / `kmod-tun` |
| `luci-app-tailscale-community` | `immortalwrt/luci` → `applications/luci-app-tailscale-community` | `LUCI_DEPENDS:=+tailscale +ip-full +luci-base`；上游已用它替代旧的 `luci-app-tailscale` |
| `luci-i18n-tailscale-community-zh-cn` | 同上，`po/zh_Hans` 由 `luci.mk` 自动生成 | 已核实该 app 的 `po/` 下有 `zh_Hans` |
| `vlmcsd` | `immortalwrt/packages` → `net/vlmcsd` | KMS 模拟器，`DEPENDS:=+libpthread` |
| `luci-app-vlmcsd` | `immortalwrt/luci` → `applications/luci-app-vlmcsd` | `LUCI_DEPENDS:=+vlmcsd` |
| `luci-i18n-vlmcsd-zh-cn` | 同上，`po/zh_Hans` | 该 app 的 `po/` 只有 `zh_Hans` / `zh_Hant`，中文包一定生成 |

两个 `luci-i18n-*-zh-cn` 不是独立仓库，是 LuCI 构建系统按 `po/zh_Hans` 生成的语言包；基础配置里的 `CONFIG_LUCI_LANG_zh_Hans=y` 已保证这一点。

`Config-HG5585F-CT.txt` 里已写好 6 行 `CONFIG_PACKAGE_xxx=y`，`build-hg5585f-ct.yml` 的 Configure 阶段会**逐个硬断言**：`make defconfig` 后只要有一个被降级就报错退出，不会编出"看着成功但没装插件"的固件。另外补了 `zoneinfo-core` / `zoneinfo-asia`（时区数据）、`luci-i18n-base-zh-cn`（LuCI 基础中文）。

> 顺手修掉一个冲突：基础配置已选 `libustream-openssl`，所以**不能**再显式打开 `libustream-mbedtls`（两者 PROVIDES 相同）。HTTPS 下载能力由基础配置保证，无需重复指定。

### 7.2 默认设置：UTC+8 上海 + 国内 NTP

源码 `package/base-files/files/bin/config_generate` 的出厂默认是 `timezone='GMT0'` / `zonename='UTC'`，NTP 是 `time.apple.com` / `time1.google.com` / `time.cloudflare.com` / `pool.ntp.org`。改动后：

| 项 | 新默认值 |
|---|---|
| `system.@system[0].timezone` | `<+08>-8`（POSIX TZ，UTC+8、无夏令时） |
| `system.@system[0].zonename` | `Asia/Shanghai` |
| `system.ntp.server` | `ntp.aliyun.com` / `time1.cloud.tencent.com` / `ntp.ntsc.ac.cn` / `cn.pool.ntp.org` |
| 时区数据 | `zoneinfo-core` + `zoneinfo-asia`，提供 `/usr/share/zoneinfo/Asia/Shanghai` |
| LuCI 语言 | `CONFIG_LUCI_LANG_zh_Hans=y` + `luci-i18n-base-zh-cn` |
| IP / 主机名 / SSID | 仍由 `customize.sh` 顶部变量控制 |

**两层生效机制**（这是关键，只改一层在"保留配置升级"时不会生效）：

| 层 | 实现 | 生效时机 |
|---|---|---|
| 编译期出厂默认 | `customize.sh` 直接 sed `config_generate` | 全新生成 `/etc/config/system`（恢复出厂 / 不保留配置升级） |
| 首次开机兜底 | `files/etc/uci-defaults/99-hg5585f-ct` | **含 sysupgrade 保留配置的首次启动**；只改"仍是出厂默认值"的项，不覆盖用户自定义（把 `FORCE` 改成 `1` 可强制） |

### 7.3 国内软件源（北大镜像）

这台是 **apk** 版（`CONFIG_USE_APK=y`），所以索引是 `packages.adb`、配置文件是 `/etc/apk/repositories.d/distfeeds.list`，**不是** opkg 的 `/etc/opkg/distfeeds.conf`。你给的 6 条 URL 我已逐条实测 HTTP 200。

编译期由 `include/feeds.mk` 的 `FeedSourcesAppendAPK` 用 `%U`（`VERSION_REPO`）、`%S`（`airoha/an7581`）、`%A`（`aarch64_cortex-a53`）生成源。北大镜像的目录结构和官方一致，所以配置里加了：

```
CONFIG_VERSION_REPO="https://mirrors.pku.edu.cn/immortalwrt/snapshots"
```

但有两个坑，因此**没有只依赖它**：

1. `CONFIG_VERSION_REPO` 在这套源码里不是 kconfig 符号（不在 `config/*.in`），`make defconfig` 可能把它丢掉 —— workflow 里只做提示，不做硬断言。
2. 自动生成的列表会多出 `pon_drivers` / `pon_userspace` / `video` 三条，而镜像上**没有**这些目录，`apk update` 会报 404。

最终由 `customize.sh` 生成 `files/etc/apk/repositories.d/distfeeds.list` 覆盖成精确的 6 条，`99-hg5585f-ct` 在升级后也会再写一份兜底：

```
https://mirrors.pku.edu.cn/immortalwrt/snapshots/targets/airoha/an7581/packages/packages.adb
https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/base/packages.adb
https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/luci/packages.adb
https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/packages/packages.adb
https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/routing/packages.adb
https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/telephony/packages.adb
```

PON 相关包（`kmod-airoha-xpon`、`airoha-pond` 等）是 pbs05 自建 feed，镜像里没有 —— 但它们已经编进固件，日后不需要从镜像装；如需本地自建源，请写进 `/etc/apk/repositories.d/customfeeds.list`（这个文件是 conffile，会跨 sysupgrade 保留）。

**?? 签名注意事项**：`CONFIG_SIGNED_PACKAGES=y`，自编译固件的 `/etc/apk/keys/` 里只有本地 build key，而北大镜像里的包由 ImmortalWrt 官方 key 签名，日后 `apk update` / `apk add` 可能报 `UNTRUSTED signature`。三种处理方式，任选其一：

1. **推荐**：从现有设备导出官方公钥，放进仓库的 `files/etc/apk/keys/`，随固件一起打包：
   ```sh
   mkdir -p files/etc/apk/keys
   scp root@192.168.1.1:/etc/apk/keys/*.pem files/etc/apk/keys/
   ```
2. 在 workflow 的 `apk_repo_key_url` 输入框填公钥 URL，CI 会下载并注入为 `files/etc/apk/keys/immortalwrt-official.pem`。
3. 临时用 `apk add --allow-untrusted <包名>`（不推荐长期使用）。

固件里已内置的包不受影响，只有"日后在线装新包"才需要这个。

### 7.4 验证结果

- 6 个包在合并 `.config` 中均为 `=y`，workflow 断言模拟通过；无 `libustream` PROVIDES 冲突。
- `customize.sh` 用真实 `config_generate` 本地模拟执行：时区、主机名、4 条 NTP 全部正确替换，生成的 6 条 URL 与上面逐条一致。
- `99-hg5585f-ct` 用 mock `uci` 跑两种场景：出厂默认会被正确改写；用户自定义时区/主机名/NTP 时**不会被覆盖**；两种情况都写出正确的 6 条源。
- `build-hg5585f-ct.yml` YAML 严格解析通过，4 个 shell 脚本 `bash -n` 通过。
- **按你的要求只验证了路线 B**；路线 A 的资产顺手同步了同样的改动，但未做验证。

首次上 CI 仍建议勾 `test_only=true`，下载 `Config-final.txt` 确认 6 个包都是 `=y` 再正式编译。

---

## 八、进阶定制

- **加插件**：把 `CONFIG_PACKAGE_xxx=y` 写进 `Config-EXTRA.txt` 放仓库根目录，`customize.sh` 会自动追加；或在路线 A 的 `PACKAGE` 输入框里逐行写。
- **改默认 IP / SSID / 主机名 / 时区 / NTP / 镜像**：改 `customize.sh` 顶部的 `WRT_*` 变量（`WRT_TZ`、`WRT_ZONENAME`、`WRT_NTP`、`WRT_REPO_BASE`、`WRT_APK_FEEDS` 等），或在 workflow 里传同名 env。
- **预置配置 / SSH 公钥 / 启动脚本 / apk 公钥**：放 `files/etc/...`，会被覆盖进 rootfs。
- **锁定源码**：`source_ref` 填具体 commit，产物里的 `source-commit.txt` 便于追溯。
- **定时编译**：把 workflow 里注释掉的 `schedule` 打开（当前是每周一北京时间 05:00）。
- **加速**：路线 A 自带 ccache + `staging_dir` 缓存；路线 B 可仿 `WRT-CORE.yml` 加 `actions/cache` 缓存 `dl/` 与 `.ccache`。

---

## 九、文件清单

| 文件 | 用途 |
|---|---|
| `HG5585F-CT-云编译搭建指南.md` | 本文 |
| `hg5585f-ct-cloudbuild/build-hg5585f-ct.yml` | 路线 B：自包含 workflow（Actions 已锁定 Node 24 版本） |
| `hg5585f-ct-cloudbuild/Config-HG5585F-CT.txt` | 单设备 + PON feed/包 + 6 个新增包 + 国内源 + 时区数据 |
| `hg5585f-ct-cloudbuild/customize.sh` | 改 `config_generate`（时区/NTP/IP/主机名/SSID）+ 生成 6 条 apk 源 + 可选公钥注入 |
| `hg5585f-ct-cloudbuild/files/etc/uci-defaults/99-hg5585f-ct` | 首次开机兜底：时区/NTP/软件源，只改仍是出厂默认值的项 |
| `hg5585f-ct-cloudbuild/preflight.sh` | 设备端升级前只读自查 + 备份 |
| `hg5585f-ct-cloudbuild/route-vikingyfy/patch-ci.sh` | 路线 A：一键改造 fork 的 CI |
| `hg5585f-ct-cloudbuild/route-vikingyfy/AIROHA-AN7581.txt` | 路线 A：单设备 Config |
| `hg5585f-ct-cloudbuild/route-vikingyfy/HG5585F-CT.yml` | 路线 A：专用 workflow |
| `pon-ci-research/` | 本次调研下载的原始 README / workflow / config / DTS / Makefile 副本 |

### 调研依据（均为 2026-11-08 实时读取）

`pbs05/ponwrt` README_zh、feeds.conf.default、configs/an7581.config、configs/release.config、.github/workflows/release.yml、target/linux/airoha/image/an7581.mk、base-files/etc/board.d/03_pon_data、base-files/lib/upgrade/platform.sh、dts/an7581-fiberhome-hg5585f-ct*.dts；`VIKINGYFY/OpenWRT-CI` WRT-CORE.yml / AIROHA-ALL.yml / Config/AIROHA-AN7581.txt / Config/GENERAL.txt / Scripts/*.sh / prepare-rust.sh；`VIKINGYFY/immortalwrt@owrt` feeds.conf.default、an7581.mk、HG5585F-CT DTS；两个 PON 仓 README 与各 Makefile。

第七节追加核对（同为 2026-11-08 实时读取）：`immortalwrt/packages` 的 `net/tailscale/Makefile`、`net/vlmcsd/Makefile`、`utils/zoneinfo/Makefile`；`immortalwrt/luci` 的 `applications/luci-app-tailscale-community/Makefile`、`applications/luci-app-vlmcsd/Makefile` 及两者 `po/` 目录；`pbs05/ponwrt` 的 `include/feeds.mk`（`FeedSourcesAppendAPK`）、`include/version.mk`、`package/base-files/Makefile`、`package/base-files/files/bin/config_generate`、`package/base-files/files/etc/uci-defaults/15_migrate-time-zonename`、`package/system/apk/Makefile`；北大镜像 6 个 `packages.adb` 的 HTTP 状态。

---

## 十、首次运行提示：Node.js 20 弃用警告（已修复）

### 10.1 现象与定性

第一次跑 workflow 时，job `PonWrt / airoha-an7581 / HG5585F-CT` 的日志里会挂一条黄色注解：

> Node.js 20 is deprecated. The following actions target Node.js 20 but are being forced to run on Node.js 24: actions/checkout@v4, actions/upload-artifact@v4, softprops/action-gh-release@v2. For more information see: https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/

**这不是编译失败，也不影响固件内容。** 它说的是"这个 Action 自身跑在哪个 Node 运行时上"，与 OpenWrt 源码、编译产物、`node-version` 之类的设置无关。按 GitHub 官方 changelog 的时间线：2025-09-19 宣布弃用；2026-06-16 runner 默认改用 Node 24，声明 `runs.using: node20` 的 action 被强制放到 Node 24 上执行；2026-09-23 Node 20 二进制已从 runner 移除、临时 opt-out 变量失效。所以这次能跑通属于"被强制兼容执行"，但属于不受支持的组合，且每次运行都会重复这条注解。

### 10.2 版本映射（逐个读 `action.yml` 的 `runs.using` 实测，2026-11-08）

| Action | 原 pin | 原运行时 | 升级到 | 新运行时 |
|---|---|---|---|---|
| `actions/checkout` | `@v4` | node20 | **`@v5`** | node24 |
| `actions/upload-artifact` | `@v4` | node20 | **`@v6`** | node24 |
| `softprops/action-gh-release` | `@v2` | node20 | **`@v3`** | node24 |

?? 最容易踩的坑：**`actions/upload-artifact@v5` 仍然是 node20**（实测 `using: 'node20'`），最小可用是 `@v6`。`setup-node` / `cache` / `checkout` 等一批官方 action 是 `@v5` 切到 node24，照着"统一升一个主版本"的通用教程改会白改。另外 `softprops/action-gh-release` 的 v2 末版 v2.6.2 官方已声明不再维护，只有 v3 是 Node 24（v3.0.0 release notes 明确"moves the action runtime from Node 20 to Node 24"）。

选的是各仓库**最小的** Node 24 主版本，不越级到更新大版本（例如 checkout@v6 把凭据移出 `.git/config`、v7 默认拦截 fork PR checkout），避免顺带吃到无关的行为变更。workflow 用到的输入（upload-artifact 的 `name` / `path` / `if-no-files-found` / `retention-days`，release 的 `tag_name` / `name` / `files` / `body`）在新版 `action.yml` 中均保留，`with:` 无需改动；checkout 本来就没带 `with:`。

### 10.3 已经改了什么 / 你需要做什么

本地两份 workflow（仓库根目录模板 `build-hg5585f-ct.yml` + `.github/workflows/build-hg5585f-ct.yml` 副本）已同步更新这 4 处引用，文件头也写了版本锁定注释。**你在 GitHub 上已经建好的仓库不会自动跟着变**：把更新后的 workflow 覆盖推到自己的仓库，再 `Run workflow` 一次，注解就会消失。之前那次编译产出的 `.itb` 固件完全不受影响，可以直接用，不必为了这条警告重编。

如果暂时不想推代码，什么都不做也能继续跑（runner 会强制用 Node 24 执行），只是每次日志多一条注解。但**不要**去加 `ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION=true` 之类的 opt-out 变量——它在 2026-09-23 之后已经失效；`FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` 同理也不需要，现在本来就是 Node 24。

第十节核对依据：GitHub 官方 changelog `2025-09-19-deprecation-of-node-20-on-github-actions-runners`（含 2026-02-25 / 05-19 / 08-25 三次编辑说明）；`actions/checkout` v4/v5/v6、`actions/upload-artifact` v4/v5/v6、`softprops/action-gh-release` v2/v3 的 `action.yml` 与其 releases 页面。

