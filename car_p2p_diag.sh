#!/usr/bin/env bash
# ============================================================
# 车机 WLAN 直连 / Wi-Fi Direct (P2P) 诊断信息一键采集
#
# 运行环境: Termux (手机侧)
# 依赖:     pkg install android-tools
# 前提:     车机已开启无线 ADB，手机能 adb 连通
#
# 用法:
#   bash car_p2p_diag.sh                            # 默认连接 10.48.152.188:5555
#   bash car_p2p_diag.sh 192.168.1.23:5555          # 指定车机地址
#   bash car_p2p_diag.sh --no-wait                  # 跳过 30 秒人工复现等待
#   bash car_p2p_diag.sh --bugreport                # 额外抓完整 bugreport（慢，体积大）
#
# 结果目录: ~/p2pdiag_<时间戳>/   打包: ~/p2pdiag_<时间戳>.tar.gz
# ============================================================

set -u

TS=$(date +%Y%m%d_%H%M%S)
OUT="$HOME/p2pdiag_$TS"
mkdir -p "$OUT"
LOG="$OUT/_transcript.txt"
ADB_TIMEOUT=120
DO_WAIT=1
DO_BUGREPORT=0
DEFAULT_TARGET="10.48.152.188:5555"
TARGET=""

for arg in "$@"; do
  case "$arg" in
    --no-wait)    DO_WAIT=0 ;;
    --bugreport)  DO_BUGREPORT=1 ;;
    -*)           ;;
    *)            TARGET="$arg" ;;
  esac
done
TARGET="${TARGET:-$DEFAULT_TARGET}"

say() { echo "$*" | tee -a "$LOG"; }
c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m%s\033[0m\n' "$*"; }

HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

# ------------------------------------------------------------
# 采集函数: cap <名称> <adb 参数...>
# 每条命令单独一个文件，同时追加到总记录 _transcript.txt
# ------------------------------------------------------------
cap() {
  local name="$1"; shift
  local f="$OUT/${name}.txt"
  local rc=0
  {
    echo "### adb $*"
    echo "### time: $(date '+%F %T')"
    echo "----------------------------------------"
  } > "$f"

  if [ "$HAVE_TIMEOUT" = 1 ]; then
    timeout "$ADB_TIMEOUT" "${ADB[@]}" "$@" >> "$f" 2>&1; rc=$?
  else
    "${ADB[@]}" "$@" >> "$f" 2>&1; rc=$?
  fi

  echo "" >> "$f"
  echo "### exit=$rc" >> "$f"
  { echo; echo "======== adb $* ========"; cat "$f"; echo; } >> "$LOG"
  printf '  [+] %-24s exit=%-3s %s bytes\n' "$name" "$rc" "$(wc -c < "$f" | tr -d ' ')"
}

countdown() {
  local n="$1"
  while [ "$n" -gt 0 ]; do
    printf '\r  倒计时 %02d 秒 ...   ' "$n"
    sleep 1
    n=$((n - 1))
  done
  printf '\r  开始采集 ...            \n'
}

# ============================================================
say ""
say "########## 车机 WLAN 直连(P2P) 诊断采集 ##########"
say "输出目录: $OUT"
say ""

# ---------- 0. 环境检查 ----------
if ! command -v adb >/dev/null 2>&1; then
  c_err "没有找到 adb 命令。请先执行:  pkg install android-tools"
  exit 1
fi

adb start-server >/dev/null 2>&1

# ---------- 1. 设备选择（不阻塞：检测不到也继续跑）----------
state_of() { adb -s "$1" get-state 2>/dev/null | tr -d '\r' | head -n 1; }

say "adb version:"; adb version 2>&1 | tee -a "$LOG"
say ""
say "adb devices 原始输出:"
adb devices -l 2>&1 | tee -a "$LOG"
say ""

SERIAL=""

# 1) 目标地址是否为 device
if [ "$(state_of "$TARGET")" = "device" ]; then
  SERIAL="$TARGET"
  say "目标地址在线: $TARGET"
fi

# 2) 列表里任意 device 状态的设备
if [ -z "$SERIAL" ]; then
  SERIAL=$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1; exit}')
  [ -n "$SERIAL" ] && say "从 adb devices 中选中: $SERIAL"
fi

# 3) 列表里有记录但状态异常(offline/unauthorized)，也先拿来跑
if [ -z "$SERIAL" ]; then
  SERIAL=$(adb devices 2>/dev/null | awk 'NR>1 && NF>=2 {print $1; exit}')
  [ -n "$SERIAL" ] && c_warn "设备状态异常，仍然继续执行: $SERIAL"
fi

# 4) 列表完全为空 —— 按你的要求直接对目标地址硬跑，不再中断
if [ -z "$SERIAL" ]; then
  SERIAL="$TARGET"
  c_warn "adb devices 未列出设备，仍按 $SERIAL 继续执行（不再退出）"
fi

ADB=(adb -s "$SERIAL")

# 轻量探测：-s 不通但默认设备可用时，自动切换到默认设备
if [ "$HAVE_TIMEOUT" = 1 ]; then
  if ! timeout 10 "${ADB[@]}" shell echo __ok__ 2>/dev/null | grep -q __ok__; then
    if timeout 10 adb shell echo __ok__ 2>/dev/null | grep -q __ok__; then
      ADB=(adb)
      c_warn "-s $SERIAL 不通，但 adb 默认设备可用，改用默认设备"
    else
      c_warn "shell 探测失败，继续执行；命令报错会原样写入各输出文件"
    fi
  fi
fi

say "使用设备: ${ADB[*]}"
say ""

# ============================================================
# ---------- 2. 快速基础快照（先抓，避免被后续日志污染）----------
# ============================================================
say "[2/8] 采集设备基础信息 ..."
cap adb_devices      devices -l
cap props            shell getprop
cap features         shell pm list features
cap ps               shell ps -A
cap iplink           shell ip link
cap ipaddr           shell ip addr
cap lsmod            shell lsmod
cap modules_wifi     shell 'ls -la /vendor/etc/wifi /system/etc/wifi 2>&1'
cap conf_supplicant  shell 'cat /vendor/etc/wifi/wpa_supplicant.conf 2>&1'
cap conf_p2p         shell 'cat /vendor/etc/wifi/p2p_supplicant.conf 2>&1'
cap wifidir_misc     shell 'ls -laZ /data/misc/wifi /data/misc/wifi/sockets 2>&1'
cap wifidir_vendor   shell 'ls -laZ /data/vendor/wifi /data/vendor/wifi/wpa 2>&1'
say ""

# ============================================================
# ---------- 3. 清空日志，等待你复现问题 ----------
# ============================================================
say "[3/8] 清空 logcat 缓冲区 ..."
"${ADB[@]}" logcat -c >/dev/null 2>&1 || c_warn "logcat -c 失败（可忽略）"

if [ "$DO_WAIT" = 1 ]; then
  c_warn ""
  c_warn ">>> 请现在操作车机：退出「WLAN 直连」页面，然后重新进入，并停留观察 <<<"
  c_warn ">>> 30 秒后自动开始抓日志 <<<"
  c_warn ""
  countdown 30
else
  say "跳过人工复现等待 (--no-wait)"
fi

# ============================================================
# ---------- 4. 抓日志（放在 dumpsys 之前，保证日志干净）----------
# ============================================================
say "[4/8] 抓取 logcat ..."
cap logcat_all   logcat -b all -d -v threadtime
cap logcat_crash logcat -b crash -d -v threadtime
cap logcat_main  logcat -b main -d -v threadtime
say ""

# 本地过滤（不依赖车机 grep）
if [ -s "$OUT/logcat_all.txt" ]; then
  grep -iE 'WifiP2p|P2pStateMachine|WifiP2pManager|p2p|wpa_supplicant|WifiService|WifiStateMachine|wificond|hostapd|SupplicantStaIface|wifi_hal|WifiNative' \
    "$OUT/logcat_all.txt" > "$OUT/logcat_p2p.txt" 2>/dev/null || true

  grep -E '^[0-9]{2}-[0-9]{2} [0-9:.]+ +[0-9]+ +[0-9]+ [EF] ' \
    "$OUT/logcat_all.txt" > "$OUT/logcat_errors.txt" 2>/dev/null || true

  say "  -> logcat_p2p.txt 行数: $(wc -l < "$OUT/logcat_p2p.txt")"
  say "  -> logcat_errors.txt 行数: $(wc -l < "$OUT/logcat_errors.txt")"
else
  c_warn "logcat 为空，可能没有权限，继续采集其它信息"
fi
say ""

# ============================================================
# ---------- 5. 系统服务快照 ----------
# ============================================================
say "[5/8] 采集系统服务状态 ..."
cap dumpsys_wifi         shell dumpsys wifi
cap dumpsys_connectivity shell dumpsys connectivity
cap dumpsys_activity     shell dumpsys activity services
cap dumpsys_netd         shell dumpsys netd
cap settings_global      shell settings list global
cap cmd_wifi_status      shell cmd wifi status
cap cmd_wifi_scan        shell cmd wifi list-scan-results
cap service_list         shell 'service list | grep -i -E "wifi|p2p|connectivity"'
say ""

# ============================================================
# ---------- 6. 内核 / SELinux ----------
# ============================================================
say "[6/8] 采集内核与 SELinux 信息 ..."
cap getenforce  shell getenforce
cap selinux_den shell 'cat /sys/fs/selinux/enforce 2>&1'
cap dmesg       shell dmesg
cap dmesg_avc   shell 'dmesg 2>/dev/null | grep -i avc'
cap last_kmsg   shell 'cat /proc/last_kmsg 2>/dev/null | tail -n 300'
say ""

# ============================================================
# ---------- 7. root 附加信息（有则抓，无则跳过）----------
# ============================================================
say "[7/8] 检查 root 并抓取额外配置 ..."
ROOT=0
if [ "$HAVE_TIMEOUT" = 1 ]; then
  if timeout 12 "${ADB[@]}" shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
    ROOT=1
  fi
fi

if [ "$ROOT" = 1 ]; then
  c_ok "检测到 root，继续采集受保护目录"
  cap root_id        shell 'su -c id'
  cap root_wifi_dirs shell 'su -c "ls -laZ /data/misc/wifi /data/misc/wifi/sockets /data/vendor/wifi /data/vendor/wifi/wpa"'
  cap root_p2p_conf  shell 'su -c "cat /data/vendor/wifi/wpa/p2p_supplicant.conf"'
  cap root_p2p_conf2 shell 'su -c "cat /data/misc/wifi/p2p_supplicant.conf"'
  cap root_dmesg     shell 'su -c dmesg'
  cap root_nets      shell 'su -c "ls -la /sys/class/net"'
else
  c_warn "未获得 root（不影响主要判断）"
fi
say ""

# ============================================================
# ---------- 8. 生成摘要 ----------
# ============================================================
say "[8/8] 生成摘要 ..."
SUMMARY="$OUT/summary.txt"

{
  echo "############ WLAN 直连(P2P) 诊断摘要 ############"
  echo "生成时间 : $(date '+%F %T')"
  echo "设备序列 : $SERIAL"
  echo

  echo "===== 1. adb devices ====="
  head -n 10 "$OUT/adb_devices.txt" 2>/dev/null
  echo

  echo "===== 2. 版本 / 型号 ====="
  grep -E '^\[ro\.(build\.version\.release|build\.id|build\.version\.sdk|product\.model|product\.brand|product\.device)\]' "$OUT/props.txt" 2>/dev/null
  echo

  echo "===== 3. wifi / p2p / wlan 相关 prop ====="
  grep -iE '^\[[^]]*(wifi|p2p|wlan)[^]]*\]' "$OUT/props.txt" 2>/dev/null | head -n 80
  echo

  echo "===== 4. wifi 相关 feature ====="
  grep -iE 'wifi|p2p|direct' "$OUT/features.txt" 2>/dev/null
  echo

  echo "===== 5. 相关进程 ====="
  awk 'NR==1 || /wpa_supplicant|wificond|hostapd|wifi|p2p/' "$OUT/ps.txt" 2>/dev/null | head -n 40
  echo

  echo "===== 6. 网卡接口 ====="
  cat "$OUT/iplink.txt" 2>/dev/null | grep -E '^[0-9]+: ' | head -n 40
  echo

  echo "===== 7. wifi/p2p 服务是否存活 ====="
  grep -iE -A5 'ServiceRecord.*(WifiP2p|WifiService|Wifi)' "$OUT/dumpsys_activity.txt" 2>/dev/null | head -n 60
  grep -iE 'WifiP2pService|P2pStateMachine|restarting|crash' "$OUT/dumpsys_activity.txt" 2>/dev/null | head -n 30
  echo

  echo "===== 8. dumpsys wifi 中 p2p 相关内容 ====="
  grep -inE 'p2p' "$OUT/dumpsys_wifi.txt" 2>/dev/null | head -n 120
  echo

  echo "===== 9. SELinux 状态 ====="
  cat "$OUT/getenforce.txt" 2>/dev/null | tail -n 3
  echo

  echo "===== 10. avc denied（wifi/p2p 相关）====="
  grep -iE 'wifi|p2p|wpa|wlan' "$OUT/dmesg_avc.txt" 2>/dev/null | head -n 60
  echo

  echo "===== 11. logcat 关键行（前 200 行）====="
  head -n 200 "$OUT/logcat_p2p.txt" 2>/dev/null
  echo
  echo "----- logcat_p2p.txt 总行数: $(wc -l < "$OUT/logcat_p2p.txt" 2>/dev/null) -----"
  echo

  echo "===== 12. logcat E/F（前 120 行）====="
  head -n 120 "$OUT/logcat_errors.txt" 2>/dev/null

} > "$SUMMARY" 2>&1

sed -i 's/\r$//' "$SUMMARY" 2>/dev/null || true

say ""
say "==================== 摘要预览 ===================="
cat "$SUMMARY"
say "=================================================="

# ============================================================
# 可选: bugreport
# ============================================================
if [ "$DO_BUGREPORT" = 1 ]; then
  say ""
  say "抓取完整 bugreport（可能几分钟）..."
  "${ADB[@]}" bugreport "$OUT/bugreport" >/dev/null 2>&1 || c_warn "bugreport 失败"
fi

# ============================================================
# 打包（优先 zip，Android 文件管理器更好处理）
# ============================================================
BASE="$(basename "$OUT")"
if command -v zip >/dev/null 2>&1; then
  ARCHIVE="$HOME/${BASE}.zip"
  (cd "$HOME" && zip -qr "$ARCHIVE" "$BASE") || c_warn "zip 打包失败"
else
  ARCHIVE="$HOME/${BASE}.tar.gz"
  tar -czf "$ARCHIVE" -C "$HOME" "$BASE" 2>/dev/null || c_warn "打包失败，直接发目录即可"
fi

# 复制到手机下载目录（Termux 的 ~/storage/downloads 最稳）
DL_DIR=""
for d in "$HOME/storage/downloads" "/sdcard/Download" "/storage/emulated/0/Download" "/storage/emulated/0/downloads"; do
  if [ -d "$d" ] && [ -w "$d" ]; then
    if cp "$ARCHIVE" "$d/" 2>/dev/null; then
      DL_DIR="$d"
      break
    fi
  fi
done

say ""
c_ok "采集完成"
say "目录   : $OUT"
say "打包   : $ARCHIVE  ($(du -h "$ARCHIVE" 2>/dev/null | awk '{print $1}'))"
if [ -n "$DL_DIR" ]; then
  c_ok "已复制到: $DL_DIR/$(basename "$ARCHIVE")"
else
  c_warn "未能写入下载目录。请先执行 termux-setup-storage 并允许存储权限，再重跑；或手动执行："
  c_warn "  cp \"$ARCHIVE\" ~/storage/downloads/"
fi
say ""
say "整个压缩包直接发我即可（内含 summary.txt / dumpsys_wifi.txt / logcat_p2p.txt 等全部结果）。"
