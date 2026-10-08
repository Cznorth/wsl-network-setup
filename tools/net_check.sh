#!/usr/bin/env bash
# =============================================================================
# net_check.sh — 网络纯净度 / IP 泄露 / DNS 泄露 检测脚本
#
# 用法:
#   bash net_check.sh        # 完整检测
#   bash net_check.sh -q     # 快速模式(跳过外部情报库, 只看连通性/一致性)
#   bash net_check.sh -j     # 以 JSON 输出采集到的数据(便于自动化)
#   bash net_check.sh -h     # 帮助
#
# 可选环境变量(提升准确度):
#   IPINFO_TOKEN    ipinfo.io token  -> 解锁 privacy 字段(vpn/proxy/hosting/tor)
#   PROXYCHECK_KEY  proxycheck.io key-> 提高限额/更多情报
#   TIMEOUT         单请求超时秒数, 默认 8
#
# 依赖: curl(必需); jq 或 python3(强列推荐, 用于解析 JSON, 二者皆无则降级);
#       可选: getent/dig(DNS 检测更准)
#
# 检测项:
#   1. 出口 IP 一致性(多来源交叉验证, 发现分流/泄露)
#   2. IPv4 / IPv6 出口是否分离(IPv6 泄露)
#   3. IP 情报: 代理/VPN/机房/Tor 特征、 WhoIS 组织、 rDNS
#   4. DNS 泄露: 实际使用的递归解析器是谁、在哪个国家、与出口 IP 是否同源
#   5. 综合"纯净度"评分(住宅 IP 得分高, 机房/代理/泄露扣分)
# =============================================================================

TIMEOUT="${TIMEOUT:-8}"
QUICK=0; JSONONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quick) QUICK=1 ;;
    -j|--json) JSONONLY=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "未知参数: $1 (用 -h 查看帮助)"; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------- 终端颜色 ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1;36m'; C_G=$'\033[1;32m'
  C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_D=$'\033[2m'
else
  C_RST=''; C_B=''; C_G=''; C_Y=''; C_R=''; C_D=''
fi

hdr()  { [ "$JSONONLY" -eq 1 ] && return 0; printf '\n%s=== %s ===%s\n' "$C_B" "$*" "$C_RST"; }
ok()   { [ "$JSONONLY" -eq 1 ] && return 0; printf '  [%sOK%s] %s\n' "$C_G" "$C_RST" "$1"; }
warn() { [ "$JSONONLY" -eq 1 ] && return 0; printf '  [%s!!%s] %s\n' "$C_Y" "$C_RST" "$1"; }
bad()  { [ "$JSONONLY" -eq 1 ] && return 0; printf '  [%sXX%s] %s\n' "$C_R" "$C_RST" "$1"; }
info() { [ "$JSONONLY" -eq 1 ] && return 0; printf '  [%s--%s] %s\n' "$C_D" "$C_RST" "$1"; }
kv()   { [ "$JSONONLY" -eq 1 ] && return 0; printf '  %s%-16s%s %s\n' "$C_D" "$1:" "$C_RST" "$2"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------ HTTP / JSON -----
fetch() { # fetch <url> [curl extra args...]
  curl -sS --max-time "$TIMEOUT" --connect-timeout 5 "$@" 2>/dev/null
}

JQ=""; PY=""
have jq     && JQ="jq"
have python3 && PY="python3"

# jget <json> <key.path>  : 取 JSON 字段, 支持 a.b 形式; 布尔转 true/false
jget() {
  local json="$1" key="$2"
  [ -z "$json" ] && return 1
  if [ -n "$JQ" ]; then
    printf '%s' "$json" | $JQ -r --arg k "$key" '
      def walk($d): reduce ($k|split("."))[] as $p ($d;
        if . == null then null
        elif ($p|tonumber? // null) != null and type=="array" then .[($p|tonumber)]
        else .[$p] end);
      walk(.) | if . == null then "" elif type=="boolean" then tostring else tostring end' 2>/dev/null
  elif [ -n "$PY" ]; then
    printf '%s' "$json" | $PY -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
k = sys.argv[1]
for p in k.split("."):
    if isinstance(d, bool): d = None; break
    if isinstance(d, dict): d = d.get(p)
    elif isinstance(d, list) and p.isdigit() and int(p) < len(d): d = d[int(p)]
    else: d = None; break
if d is None: print("")
elif isinstance(d, bool): print("true" if d else "false")
else: print(d)' "$key" 2>/dev/null
  else
    printf '%s' "$json" | sed -n "s/.*\"${key//./\"][\"}\":\"\{0,1\}\([^\",}]*\).*/\1/p" | head -n1
  fi
}

is_ipv4()  { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
is_ipv6()  { printf '%s' "$1" | grep -Eq '^[0-9a-fA-F:]{2,}:' && printf '%s' "$1" | grep -q ':'; }

# ---------------------------------------------------------------- 评分器 ------
SCORE=100
pen() { SCORE=$(( SCORE - $1 )); [ "$SCORE" -lt 0 ] && SCORE=0; }

# ---------------------------------------------------------------- 环境信息 ----
if [ "$JSONONLY" -eq 0 ]; then
  hdr "本地环境"
  info "代理相关环境变量:"
  found_env=0
  for v in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
    [ -n "${!v:-}" ] && { kv "$v" "${!v}"; found_env=1; }
  done
  [ "$found_env" -eq 0 ] && info "  (无)"
  if have ip; then
    kv "本地 IPv4" "$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' ')"
    kv "本地 IPv6" "$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | tr '\n' ' ')"
    kv "默认路由" "$(ip route get 1.1.1.1 2>/dev/null | head -n1)"
  fi
  if [ -r /etc/resolv.conf ]; then
    kv "resolv.conf" "$(grep -E '^[[:space:]]*nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')"
  fi
  kv "当前时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
fi

# ============================================================ 1. 出口 IP =====
hdr "1. 出口 IP 一致性检测 (多来源交叉验证)"

PROVIDERS=(
  "ifconfig.me|https://ifconfig.me/ip"
  "ipify|https://api.ipify.org"
  "icanhazip|https://icanhazip.com"
  "amazonaws|https://checkip.amazonaws.com"
  "ipinfo.io|https://ipinfo.io/ip"
  "ip.sb|https://api-ipv4.ip.sb/ip"
  "myip.dnsomatic|https://myip.dnsomatic.com"
)

declare -A COUNT=() SRC_IP=()
ORDER=()
for p in "${PROVIDERS[@]}"; do
  name="${p%%|*}"; url="${p#*|}"
  ip="$(fetch -4 "$url" | tr -d '[:space:]')"
  if is_ipv4 "$ip"; then
    SRC_IP["$name"]="$ip"; COUNT["$ip"]=$(( ${COUNT["$ip"]:-0} + 1 )); ORDER+=("$name|$ip")
    [ "$JSONONLY" -eq 0 ] && kv "$name" "$ip"
  else
    [ "$JSONONLY" -eq 0 ] && info "$name: 无响应/超时"
  fi
done

UNIQ=()
for k in "${!COUNT[@]}"; do UNIQ+=("$k"); done
UNIQ_COUNT=${#UNIQ[@]}

# 取出现次数最多的作为主出口 IP
PRIMARY=""; best=-1
for k in "${!COUNT[@]}"; do
  if [ "${COUNT[$k]}" -gt "$best" ]; then best="${COUNT[$k]}"; PRIMARY="$k"; fi
done
# 保证 SRC_IP 顺序稳定
[ -z "$PRIMARY" ] && for e in "${ORDER[@]}"; do PRIMARY="${e#*|}"; done

if [ "$UNIQ_COUNT" -gt 1 ]; then
  warn "检测到 $UNIQ_COUNT 个不同出口 IP: ${UNIQ[*]} —— 存在分流/部分流量未走代理(IP 泄露风险)"
  pen 40
elif [ "$UNIQ_COUNT" -eq 1 ]; then
  ok "所有来源一致: ${PRIMARY} (无分流泄露)"
else
  bad "无法获取任何出口 IP (网络不通或请求被拦截)"
fi

# ------------------------------------------------- IPv6 出口 / IPv6 泄露 -----
IPV6=""; IPV6_UP=0
ipv6addr="$(fetch -6 --max-time 5 https://api-ipv6.ip.sb/ip 2>/dev/null | tr -d '[:space:]')"
if is_ipv6 "$ipv6addr"; then IPV6="$ipv6addr"; IPV6_UP=1; fi
if [ "$JSONONLY" -eq 0 ]; then
  if [ "$IPV6_UP" -eq 1 ]; then
    kv "IPv6 出口" "$IPV6"
    if [ -n "$PRIMARY" ] && [ "$IPV6" != "$PRIMARY" ]; then
      warn "IPv4 与 IPv6 出口不同 —— 若未预期, 可能为 IPv6 流量绕过代理(IPv6 泄露)"
      pen 20
    fi
  else
    info "无明显 IPv6 出口(未启用/被禁), 无 IPv6 泄露风险"
  fi
fi

# ==================================================== 2. IP 情报 / 纯净度 =====
[ -n "$PRIMARY" ] && hdr "2. 出口 IP 情报与纯净度分析" || hdr "2. IP 情报 (跳过: 无出口 IP)"

IPINFO="$(fetch "https://ipinfo.io/json${IPINFO_TOKEN:+"?token=${IPINFO_TOKEN}"}")"
IPAPI="$(fetch "http://ip-api.com/json/${PRIMARY}?fields=query,country,countryCode,city,isp,org,as,proxy,hosting,mobile,reverse,status,message")"

if [ -n "$PRIMARY" ]; then
  if [ -n "$IPINFO" ]; then
    kv "国家/地区" "$(jget "$IPINFO" country)$( [ "$(jget "$IPINFO" city)" ] && printf ' / %s' "$(jget "$IPINFO" city)")"
    kv "组织" "$(jget "$IPINFO" org)"
    kv "主机名" "$(jget "$IPINFO" hostname)"
    [ -n "$IPINFO_TOKEN" ] && kv "ipinfo privacy" "vpn=$(jget "$IPINFO" privacy.vpn) proxy=$(jget "$IPINFO" privacy.proxy) tor=$(jget "$IPINFO" privacy.tor) hosting=$(jget "$IPINFO" privacy.hosting) relay=$(jget "$IPINFO" privacy.relay)"
  fi
  if [ -n "$IPAPI" ]; then
    kv "ISP" "$(jget "$IPAPI" isp)"
    kv "ASN" "$(jget "$IPAPI" as)"
    kv "rDNS" "$(jget "$IPAPI" reverse)"
    kv "ip-api 标记" "proxy=$(jget "$IPAPI" proxy) hosting=$(jget "$IPAPI" hosting) mobile=$(jget "$IPAPI" mobile)"
  fi
  EXIT_CC="$(jget "$IPAPI" countryCode)"
  EXIT_ORG="$(jget "$IPINFO" org) $(jget "$IPAPI" isp) $(jget "$IPAPI" org)"
fi

# 2a. 已知代理/VPN/机房 数据库
if [ -n "$PRIMARY" ] && [ "$QUICK" -eq 0 ]; then
  # proxycheck.io (无 key 也有基础查询额度) —— 返回结构为 {"status":"ok","<ip>":{...}}
  PC="$(fetch "https://proxycheck.io/v2/${PRIMARY}?vpn=1&risk=1&asn=1${PROXYCHECK_KEY:+"&key=${PROXYCHECK_KEY}"}")"
  if [ -n "$PC" ]; then
    if [ -n "$JQ" ]; then
      pc_proxy="$(printf '%s' "$PC" | $JQ -r --arg ip "$PRIMARY" '.[$ip].proxy // empty' 2>/dev/null)"
      pc_type="$(printf '%s' "$PC"  | $JQ -r --arg ip "$PRIMARY" '.[$ip].type // empty' 2>/dev/null)"
      pc_risk="$(printf '%s' "$PC"  | $JQ -r --arg ip "$PRIMARY" '.[$ip].risk // empty' 2>/dev/null)"
    elif [ -n "$PY" ]; then
      pc_proxy="$(printf '%s' "$PC" | $PY -c '
import sys, json
try: d = json.load(sys.stdin)[sys.argv[1]]
except Exception: sys.exit(1)
print("true" if d.get("proxy") is True else "false" if d.get("proxy") is False else d.get("proxy") or "")' "$PRIMARY" 2>/dev/null)"
      pc_type="$(printf '%s' "$PC" | $PY -c '
import sys, json
try: print(json.load(sys.stdin)[sys.argv[1]].get("type") or "")
except Exception: pass' "$PRIMARY" 2>/dev/null)"
      pc_risk="$(printf '%s' "$PC" | $PY -c '
import sys, json
try: print(json.load(sys.stdin)[sys.argv[1]].get("risk") or "")
except Exception: pass' "$PRIMARY" 2>/dev/null)"
    else
      pc_proxy="$(jget "$PC" proxy)"; pc_type=""; pc_risk=""
    fi
    kv "proxycheck" "proxy=${pc_proxy:-?} type=${pc_type:-?} risk=${pc_risk:-?}"
    case "$pc_proxy" in
      yes|true) warn "proxycheck 判定该 IP 为 代理/VPN 出口 —— 纯净度低"; pen 25 ;;
      no|false) ok "proxycheck 未标记为代理" ;;
    esac
  fi

  # Tor 出口节点列表
  TOR="$(fetch https://check.torproject.org/torbulkexitlist)"
  if [ -n "$TOR" ] && printf '%s\n' "$TOR" | grep -qFx "$PRIMARY"; then
    bad "该 IP 出现在 Tor 出口节点列表中"; pen 60
  fi

  # ipinfo privacy 字段(需要 token)
  p_privacy="no"
  for f in vpn proxy tor relay hosting; do
    v="$(jget "$IPINFO" privacy.$f)"
    [ "$v" = "true" ] && p_privacy="yes"
  done
  if [ "$p_privacy" = "yes" ]; then
    warn "ipinfo.io 标记该 IP 含 隐私服务特征(vpn/proxy/tor/hosting)"; pen 15
  fi

  # 2b. 数据中心 / IDC 关键词启发式(住宅 IP 通常得分更高)
  # 注意: 关键词表必须写成单行, 否则正则中出现空分支会匹配任意字符串
  DC_KW='Cloudflare|Amazon|AWS|Google LLC|Microsoft|Azure|DigitalOcean|Linode|Akamai|Vultr|Choopa|Hetzner|OVH|Contabo|M247|Leaseweb|Zenlayer|Datacenter|Data Center|DataCamp|Alibaba|Aliyun|Tencent|Huawei|UCloud|Baidu|ByteDance|Oracle|IBM SoftLayer|Hosting|Colocation|Colo|CDN|IDC|Server Farm|Datacamp'
  if [ -n "$EXIT_ORG" ] && printf '%s' "$EXIT_ORG" | grep -Eiq "$DC_KW"; then
    warn "组织信息含数据中心/云厂商关键词 -> 该出口很可能是 机房 IP(非住宅原生)"
    info "匹配组织: $(printf '%s' "$EXIT_ORG" | tr -s ' ' | cut -c1-80)"
    pen 15
  else
    ok "未匹配到明显机房/云厂商关键字(疑似住宅/原生 IP 特征)"
  fi
fi

# ======================================================== 3. DNS 泄露检测 =====
hdr "3. DNS 泄露检测 (递归解析器溯源)"

RESOLVER=""
if have dig; then
  RESOLVER="$(dig +short whoami.akamai.net 2>/dev/null | grep -E '^[0-9]+\.' | head -n1)"
fi
if [ -z "$RESOLVER" ] && have getent; then
  RESOLVER="$(getent ahostsv4 whoami.akamai.net 2>/dev/null | awk '{print $1}' | sort -u | head -n1)"
fi
if [ -z "$RESOLVER" ] && [ -n "$PY" ]; then
  RESOLVER="$($PY - <<'EOF' 2>/dev/null
import socket
try: print(socket.gethostbyname("whoami.akamai.net"))
except Exception: pass
EOF
)"
fi

if [ -n "$RESOLVER" ]; then
  kv "实际解析器" "$RESOLVER"
  RAPI="$(fetch "http://ip-api.com/json/${RESOLVER}?fields=query,country,countryCode,city,isp,org,as,proxy,hosting")"
  kv "解析器归属" "$(jget "$RAPI" country) / $(jget "$RAPI" isp) / $(jget "$RAPI" as)"
  R_CC="$(jget "$RAPI" countryCode)"

  # 服务端视角的 DNS 列表(ipleak.net), 更接近真实分流情况
  LEAK="$(fetch https://ipleak.net/json/)"
  if [ -n "$LEAK" ] && [ -n "$JQ" ]; then
    info "ipleak.net 观察到的 DNS 服务器:"
    printf '%s' "$LEAK" | $JQ -r '(.dns // [])[]' 2>/dev/null | while read -r d; do
      case "$d" in ''|*[!0-9.]*) continue ;; esac
      DAPI="$(fetch "http://ip-api.com/json/${d}?fields=country,isp")"
      info "   $d  ->  $(jget "$DAPI" country) / $(jget "$DAPI" isp)"
    done
  fi

  if [ -n "$PRIMARY" ] && [ "$RESOLVER" = "$PRIMARY" ]; then
    ok "DNS 查询经出口 IP 完成(解析器与出口同源), 无 DNS 泄露"
  elif [ -n "$EXIT_CC" ] && [ "$R_CC" = "$EXIT_CC" ]; then
    info "解析器与出口 IP 同国家(${EXIT_CC}), 一般可接受"
  elif [ "$R_CC" = "CN" ] && [ -n "$EXIT_CC" ] && [ "$EXIT_CC" != "CN" ]; then
    bad "DNS 解析器位于中国大陆($RESOLVER) 而出口 IP 位于 ${EXIT_CC} —— DNS 泄露给本地运营商/网关"
    info "后果: 国内 DNS 污染/劫持可能导致 分流、真实网站暴露、SNI 干扰"
    pen 25
  else
    warn "解析器(${R_CC:-?}) 与出口 IP(${EXIT_CC:-?}) 归属不同, 存在 DNS 泄露可能"
    pen 10
  fi
else
  info "无法探测实际递归解析器(网络受限?), 降级查看 /etc/resolv.conf"
  if [ -r /etc/resolv.conf ]; then
    grep -E '^[[:space:]]*nameserver' /etc/resolv.conf | awk '{print $2}' | while read -r ns; do
      info "  nameserver: $ns"
      case "$ns" in
        127.*|::1|127.0.0.53) info "    (本地存根, 如 systemd-resolved/dnsmasq)" ;;
      esac
    done
  fi
fi

# ================================================================ WebRTC ======
hdr "4. WebRTC 泄露提示"
info "WebRTC 泄露只能由浏览器触发, 命令行无法检测。请在浏览器访问:"
info "  https://browserleaks.com/webrtc   (查看是否暴露本地/真实公网 IP)"
info "  https://ipleak.net/               (综合检测: WebRTC/DNS/时区/字体等)"
info "建议: 浏览器禁用或限制 WebRTC(如 uBlock Origin 的 'Prevent WebRTC IP leak')"

# ================================================================ 汇总输出 ====
if [ "$JSONONLY" -eq 1 ]; then
  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
  printf '{\n'
  printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "exit_ip": "%s",\n' "$PRIMARY"
  printf '  "exit_ip_all": [%s],\n' "$(printf '%s\n' "${!COUNT[@]}" | sed 's/.*/"&"/' | paste -sd, -)"
  printf '  "ip_consistent": %s,\n' "$([ "$UNIQ_COUNT" -le 1 ] && echo true || echo false)"
  printf '  "ipv6_exit": "%s",\n' "$IPV6"
  printf '  "country": "%s",\n' "$(esc "$(jget "$IPAPI" country)")"
  printf '  "isp": "%s",\n' "$(esc "$(jget "$IPAPI" isp)")"
  printf '  "dns_resolver": "%s",\n' "$RESOLVER"
  printf '  "purity_score": %s\n' "$SCORE"
  printf '}\n'
  exit 0
fi

hdr "=== 综合结论 ==="
if [ "$UNIQ_COUNT" -gt 1 ]; then bad "IP 泄露: 多个出口 IP 不一致"; fi
if [ -n "$RESOLVER" ] && [ "$R_CC" = "CN" ] && [ -n "$EXIT_CC" ] && [ "$EXIT_CC" != "CN" ]; then
  bad "DNS 泄露: 解析器位于本地网络"
fi
if [ "$SCORE" -ge 90 ]; then ok "纯净度评分: ${SCORE}/100 —— 优秀(疑似住宅/原生, 无明显泄露)"; fi
if [ "$SCORE" -ge 70 ] && [ "$SCORE" -lt 90 ]; then warn "纯净度评分: ${SCORE}/100 —— 良好(存在机房/轻微泄露特征)"; fi
if [ "$SCORE" -ge 50 ] && [ "$SCORE" -lt 70 ]; then warn "纯净度评分: ${SCORE}/100 —— 一般(机房 IP 或存在泄露)"; fi
if [ "$SCORE" -lt 50 ]; then bad "纯净度评分: ${SCORE}/100 —— 差(泄露/代理特征明显)"; fi

info "提示: 评分基于公开情报的启发式判断, 仅供参考; 机房 IP 天然低分。"
info "如需更高纯净度: 使用住宅/原生 IP, 全局 TUN 模式(避免 DNS 泄漏), 关闭 IPv6 或接管 IPv6 出口。"
exit 0
