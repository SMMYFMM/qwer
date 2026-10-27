#!/usr/bin/env bash
# ============================================================
# 车机 WLAN 直连 / Wi-Fi Direct (P2P) 诊断信息一键采集
#
# 运行环境: Termux (手机侧)
# 依赖:     pkg install android-tools
# 前提:     车机已开启无线 ADB，手机能 adb 连通
#
# 用法:
#   bash car_p2p_diag.sh              # 常规采集
#   bash car_p2p_diag.sh --no-wait    # 跳过 30 秒人工复现等待
#   bash car_p2p_diag.sh --bugreport  # 额外抓完整 bugreport（慢，体积大）
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

for arg in "$@"; do
  case "$arg" in
    --no-wait)    DO_WAIT=0 ;;
    --bugreport)  DO_BUGREPORT=1 ;;
  esac
done

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

# ---------- 1. 设备连接 ----------
SERIAL=""
mapfile -t ONLINE < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')

if [ "${#ONLINE[@]}" -eq 0 ]; then
  c_warn "当前没有已连接的设备。"
  read -r -p "请输入车机 adb 地址 (形如 192.168.1.23:5555): " TARGET || true
  if [ -n "${TARGET:-}" ]; then
    adb connect "$TARGET" >/dev/null 2>&1 || true
    sleep 2
    mapfile -t ONLINE < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
  fi
fi

if [ "${#ONLINE[@]}" -eq 0 ]; then
  c_err "仍然没有设备。请确认车机已开启无线调试、密码/端口正确、手机与车机在同一网段。"
  c_err "也可以手动执行:  adb connect <车机IP>:<端口>  后再重跑本脚本。"
  exit 1
fi

SERIAL="${ONLINE[0]}"
if [ "${#ONLINE[@]}" -gt 1 ]; then
  c_warn "检测到多台设备，默认使用第一台: $SERIAL"
fi
ADB=(adb -s "$SERIAL")
say "使用设备: $SERIAL"
c_ok "已连接: $SERIAL"
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
# 打包
# ============================================================
TARBALL="$HOME/$(basename "$OUT").tar.gz"
tar -czf "$TARBALL" -C "$HOME" "$(basename "$OUT")" 2>/dev/null || c_warn "打包失败，直接发目录即可"

if [ -d /sdcard/Download ] && [ -w /sdcard/Download ]; then
  cp "$TARBALL" /sdcard/Download/ 2>/dev/null && c_ok "已复制到 /sdcard/Download/"
fi

say ""
c_ok "采集完成"
say "目录   : $OUT"
say "打包   : $TARBALL  ($(du -h "$TARBALL" 2>/dev/null | awk '{print $1}'))"
say ""
say "请优先发送这三个文件："
say "  1) summary.txt        （摘要，最长 300 行）"
say "  2) dumpsys_wifi.txt   （P2P 状态机完整信息）"
say "  3) logcat_p2p.txt     （P2P 相关日志）"
say "空间允许的话把整个 tar.gz 一起发给我更稳。"
