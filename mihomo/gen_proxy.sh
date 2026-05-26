#!/usr/bin/env bash
set -euo pipefail

BASE_PORT="${BASE_PORT:-42001}"
LISTEN="${LISTEN:-0.0.0.0}"
DEST="${DEST:-www.cloudflare.com:443}"
SERVER_NAME="${SERVER_NAME:-www.cloudflare.com}"
LOG_LEVEL="${LOG_LEVEL:-info}"
OUTDIR="${OUTDIR:-./out}"
CONFIG_DIR="${CONFIG_DIR:-/etc/mihomo}"
LISTENER_CACHE="${LISTENER_CACHE:-${OUTDIR}/generated-listeners.yaml}"
MIHOMO_BIN="${MIHOMO_BIN:-}"
SERVICE_NAME="${SERVICE_NAME:-mihomo}"
NODE_BASE_NAME="${NODE_BASE_NAME:-[Node] Default}"
PRINT_QRCODE="${PRINT_QRCODE:-}"

SS_PORT=$BASE_PORT
TROJAN_PORT=$((BASE_PORT + 1))
VLESS_PORT=$((BASE_PORT + 2))
VMESS_PORT=$((BASE_PORT + 3))

AUTO_INSTALL=0
WRITE_SYSTEM_CONFIG=0

COLOR_RESET='\033[0m'
COLOR_RED='\033[31m'
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_BLUE='\033[34m'
COLOR_MAGENTA='\033[35m'
COLOR_CYAN='\033[36m'
COLOR_BOLD='\033[1m'

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
err()   { echo -e "${COLOR_RED}[ERR ]${COLOR_RESET} $*" >&2; }
step()  { echo -e "${COLOR_MAGENTA}${COLOR_BOLD}==>${COLOR_RESET} $*"; }

command_begin() {
  echo
}

command_end() {
  echo
}

run_command() {
  local name="$1"
  local status
  shift

  command_begin "$name"
  set +e
  ( set -e; "$@" )
  status="$?"
  set -e
  command_end "$name"
  return "$status"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 运行"
    exit 1
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local default_index=1
  local answer

  if [ "$default" != "y" ]; then
    default_index=2
  fi

  answer="$(ask_option "$prompt" "$default_index" "是" "否")"
  [ "$answer" = "是" ]
}

ask_input() {
  local prompt="$1"
  local default="${2:-}"
  local answer

  if [ -n "$default" ]; then
    read -r -p "$prompt [默认: $default]: " answer || true
    answer="${answer:-$default}"
  else
    read -r -p "$prompt: " answer || true
  fi

  printf '%s\n' "$answer"
}

show_help() {
  cat <<EOF_HELP
用法:
  $0 [命令]

命令:
  help, -h, --help      显示本帮助
  status                查看服务和缓存节点状态
  add                   新增 mihomo listener/proxy
  delete                从缓存删除 proxy 并重新生成配置
  qrcode                为全部缓存节点生成二维码
  deploy                将当前缓存部署到 config
  无参数                进入 CLI 功能菜单

常用环境变量:
  BASE_PORT=42001       默认起始端口
  LISTEN=0.0.0.0        listener 监听地址
  DEST=www.cloudflare.com:443
  SERVER_NAME=www.cloudflare.com
  OUTDIR=./out          输出目录
  CONFIG_DIR=/etc/mihomo
  LISTENER_CACHE=./out/generated-listeners.yaml
  MIHOMO_BIN=/path/mihomo
  SERVICE_NAME=mihomo
  NODE_BASE_NAME='[Node] Default'
  PRINT_QRCODE=1        打印控制台二维码

示例:
  sudo $0
  sudo $0 add
  sudo $0 delete
  sudo $0 deploy
  sudo $0 qrcode
  sudo BASE_PORT=45000 NODE_BASE_NAME='[Node] HK' $0
  sudo CONFIG_DIR=/etc/mihomo SERVICE_NAME=mihomo $0 add
EOF_HELP
}

ask_option() {
  local prompt="$1"
  local default_index="$2"
  shift 2
  local options=("$@")
  local answer
  local i

  while true; do
    printf '%s\n' "$prompt" >&2
    for i in "${!options[@]}"; do
      printf '  %s) %s\n' "$((i + 1))" "${options[$i]}" >&2
    done
    if ! read -r -p "请输入选项编号 [默认: ${default_index}]: " answer; then
      if [ ! -t 0 ]; then
        return 1
      fi
      printf '%s\n' "${options[$((default_index - 1))]}"
      return 0
    fi
    answer="${answer:-$default_index}"

    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
      printf '%s\n' "${options[$((answer - 1))]}"
      return 0
    fi

    for i in "${!options[@]}"; do
      if [ "$answer" = "${options[$i]}" ]; then
        printf '%s\n' "${options[$i]}"
        return 0
      fi
    done

    warn "请输入有效选项编号" >&2
  done
}

ask_multi_options() {
  local prompt="$1"
  local default_value="$2"
  shift 2
  local options=("$@")
  local answer
  local token
  local normalized
  local selected=()
  local option
  local i
  local found

  while true; do
    printf '%s\n' "$prompt" >&2
    for i in "${!options[@]}"; do
      printf '  %s) %s\n' "$((i + 1))" "${options[$i]}" >&2
    done
    if ! read -r -p "请输入选项编号，可用逗号或空格多选 [默认: ${default_value}]: " answer; then
      answer="$default_value"
    fi
    answer="${answer:-$default_value}"
    normalized="$(printf '%s' "$answer" | tr ',/' '  ')"
    selected=()

    for token in $normalized; do
      found=0
      if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "${#options[@]}" ]; then
        option="${options[$((token - 1))]}"
        found=1
      else
        token="$(printf '%s' "$token" | tr 'A-Z' 'a-z')"
        for option in "${options[@]}"; do
          if [ "$token" = "$option" ]; then
            found=1
            break
          fi
        done
      fi

      if [ "$found" = "0" ]; then
        selected=()
        warn "无效选项: $token" >&2
        break
      fi

      if [ "$option" = "all" ]; then
        selected=(ss trojan vless vmess anytls)
        break
      fi

      if ! has_type "$option" "${selected[@]}"; then
        selected+=("$option")
      fi
    done

    if [ "${#selected[@]}" -gt 0 ]; then
      printf '%s\n' "${selected[@]}"
      return 0
    fi
  done
}

ask_listener_action() {
  local action

  action="$(ask_option "请选择操作:" 1 "新增 listener" "覆盖配置")"
  case "$action" in
    "新增 listener") printf '%s\n' "add" ;;
    "覆盖配置") printf '%s\n' "overwrite" ;;
  esac
}

ask_proxy_types() {
  ask_multi_options "请选择 proxy type:" "all" all ss trojan vless vmess anytls
}

ask_proxy_prefix() {
  local default_prefix="$1"
  local action
  local prefix

  action="$(ask_option "请选择节点前缀:" 1 "使用默认前缀: ${default_prefix}" "输入新前缀")"
  if [ "$action" = "输入新前缀" ]; then
    prefix="$(ask_text "请输入节点前缀" "$default_prefix")"
  else
    prefix="$default_prefix"
  fi

  printf '%s\n' "$prefix"
}

ask_confirm() {
  local prompt="$1"
  local default_index="${2:-1}"
  local answer

  answer="$(ask_option "$prompt" "$default_index" "执行" "取消")"
  [ "$answer" = "执行" ]
}

ask_text() {
  ask_input "$@"
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

detect_max_port() {
  local cfg="$1"
  local max_port=0
  local port

  if [ ! -f "$cfg" ]; then
    printf '%s\n' "$((BASE_PORT - 1))"
    return 0
  fi

  while read -r port; do
    if [ "$port" -gt "$max_port" ]; then
      max_port="$port"
    fi
  done < <(sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$cfg")

  if [ "$max_port" -eq 0 ]; then
    max_port="$((BASE_PORT - 1))"
  fi

  printf '%s\n' "$max_port"
}

ask_start_port() {
  local default_port="$1"
  local mode
  local answer

  mode="$(ask_option "请选择起始端口:" 1 "使用默认端口: ${default_port}" "输入自定义端口")"
  if [ "$mode" = "使用默认端口: ${default_port}" ]; then
    printf '%s\n' "$default_port"
    return 0
  fi

  while true; do
    answer="$(ask_text "请输入起始端口" "$default_port")"
    if is_valid_port "$answer"; then
      printf '%s\n' "$answer"
      return 0
    fi
    warn "端口必须是 1-65535 的数字"
  done
}

install_deps() {
  step "安装依赖"

  if have_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl openssl sed grep tar gzip ca-certificates qrencode coreutils
  elif have_cmd dnf; then
    dnf install -y curl openssl sed grep coreutils tar gzip ca-certificates qrencode
  elif have_cmd yum; then
    yum install -y curl openssl sed grep coreutils tar gzip ca-certificates qrencode
  elif have_cmd apk; then
    apk add --no-cache curl openssl sed grep coreutils tar gzip ca-certificates qrencode
  else
    err "不支持的系统，请自行安装: curl openssl sed grep tar gzip ca-certificates qrencode coreutils"
    exit 1
  fi

  ok "依赖安装完成"
}

ensure_dependencies() {
  local missing=()
  local c

  for c in curl openssl sed grep tar gzip install; do
    if ! have_cmd "$c"; then
      missing+=("$c")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    warn "缺少依赖: ${missing[*]}"
    if ask_yes_no "是否自动安装缺失依赖？" "y"; then
      install_deps
    else
      err "依赖不足，无法继续"
      exit 1
    fi
  else
    ok "系统基础依赖已满足"
  fi

  if ! have_cmd qrencode; then
    warn "未安装 qrencode，二维码输出功能不可用"
    if ask_yes_no "是否安装可选依赖 qrencode？" "y"; then
      install_deps
      if have_cmd qrencode; then
        ok "qrencode 安装完成"
      else
        warn "未检测到 qrencode，将继续跳过二维码输出"
      fi
    else
      warn "已跳过安装 qrencode，将跳过二维码输出"
    fi
  fi
}

resolve_mihomo_bin() {
  if [ -n "${MIHOMO_BIN:-}" ] && [ -x "$MIHOMO_BIN" ]; then
    ok "使用指定 mihomo: $MIHOMO_BIN"
    return 0
  fi

  if have_cmd mihomo; then
    MIHOMO_BIN="$(command -v mihomo)"
    ok "检测到系统已有 mihomo: $MIHOMO_BIN"
    return 0
  fi

  return 1
}

detect_arch_asset() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64)
      ASSET_RE='mihomo-linux-amd64.*\.gz'
      ;;
    aarch64|arm64)
      ASSET_RE='mihomo-linux-arm64.*\.gz'
      ;;
    *)
      err "不支持的架构: $arch"
      exit 1
      ;;
  esac
}

install_mihomo() {
  local api json url tmpdir gzfile binfile

  if resolve_mihomo_bin; then
    warn "mihomo 已存在，跳过安装"
    return 0
  fi

  detect_arch_asset
  api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

  step "下载安装 mihomo"

  json="$(curl -fsSL "$api")"
  url="$(printf '%s\n' "$json" \
    | tr ',' '\n' \
    | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | grep -E "$ASSET_RE" \
    | grep -v -E '\.deb$|\.rpm$|sha256sum|version\.txt' \
    | head -n1)"

  if [ -z "$url" ]; then
    err "找不到 mihomo 下载链接"
    exit 1
  fi

  tmpdir="$(mktemp -d)"
  gzfile="$tmpdir/mihomo.gz"
  binfile="$tmpdir/mihomo"

  curl -LfsS "$url" -o "$gzfile"
  gzip -dc "$gzfile" > "$binfile"
  install -m 0755 "$binfile" "/usr/local/bin/mihomo"
  rm -rf "$tmpdir"

  MIHOMO_BIN="/usr/local/bin/mihomo"
  ok "mihomo 安装完成: $MIHOMO_BIN"
}

extract_ipv4() {
  grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1
}

detect_public_ip() {
  local ip
  local u

  for u in \
    "https://4.ipw.cn" \
    "https://test.ipw.cn" \
    "https://ip.3322.net" \
    "https://ddns.oray.com/checkip" \
    "https://myip.ipip.net" \
    "https://api.ipify.org" \
    "https://checkip.amazonaws.com" \
    "https://ipv4.icanhazip.com"
  do
    ip="$(curl -4fsSL --max-time 8 "$u" 2>/dev/null | tr -d '\r' | extract_ipv4 || true)"
    if printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
      printf '%s\n' "$ip"
      return 0
    fi
  done

  return 1
}

gen_uuid() {
  if have_cmd uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
  elif [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
  fi
}

gen_ss_password() {
  openssl rand -base64 32 | tr -d '\n'
}

gen_short_id() {
  openssl rand -hex 4 | tr -d '\n'
}

b64_url_nopad() {
  printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

rawurlencode() {
  local s="$1"
  local out=""
  local i c hex

  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      ' ') out+='%20' ;;
      *)
        printf -v hex '%02X' "'$c"
        out+="%${hex}"
        ;;
    esac
  done

  printf '%s' "$out"
}

get_reality_keypair() {
  local out pub priv

  step "生成 REALITY 密钥对"
  out="$("$MIHOMO_BIN" generate reality-keypair 2>&1)"

  pub="$(printf '%s\n' "$out" | sed -n 's/.*Public[[:space:]]*Key:[[:space:]]*//p' | head -n1 | tr -d '\r')"
  priv="$(printf '%s\n' "$out" | sed -n 's/.*Private[[:space:]]*Key:[[:space:]]*//p' | head -n1 | tr -d '\r')"

  if [ -z "$pub" ] || [ -z "$priv" ]; then
    err "解析 reality keypair 失败"
    printf '%s\n' "$out" >&2
    exit 1
  fi

  REALITY_PUBLIC_KEY="$pub"
  REALITY_PRIVATE_KEY="$priv"
  ok "REALITY 密钥生成完成"
}

init_proxy_names() {
  SS_NAME="${NODE_BASE_NAME} 0x1"
  TROJAN_NAME="${NODE_BASE_NAME} 0x2"
  VLESS_NAME="${NODE_BASE_NAME} 0x3"
  VMESS_NAME="${NODE_BASE_NAME} 0x4"
}

write_server_config() {
  mkdir -p "$OUTDIR"

  cat > "$OUTDIR/server.yaml" <<EOF_SERVER
mode: direct
log-level: ${LOG_LEVEL}
ipv6: true

listeners:
  - name: ss-in
    type: shadowsocks
    listen: ${LISTEN}
    port: ${SS_PORT}
    cipher: 2022-blake3-aes-256-gcm
    password: ${SS_PASSWORD}
    udp: true

  - name: trojan-in-1
    type: trojan
    listen: ${LISTEN}
    port: ${TROJAN_PORT}
    users:
      - username: user1
        password: ${TROJAN_PASSWORD}
    reality-config:
      dest: ${DEST}
      private-key: ${REALITY_PRIVATE_KEY}
      short-id:
        - ${SHORT_ID}
      server-names:
        - ${SERVER_NAME}

  - name: vless-in-1
    type: vless
    listen: ${LISTEN}
    port: ${VLESS_PORT}
    users:
      - username: user1
        uuid: ${VLESS_UUID}
        flow: xtls-rprx-vision
    reality-config:
      dest: ${DEST}
      private-key: ${REALITY_PRIVATE_KEY}
      short-id:
        - ${SHORT_ID}
      server-names:
        - ${SERVER_NAME}

  - name: vmess-in-1
    type: vmess
    listen: ${LISTEN}
    port: ${VMESS_PORT}
    users:
      - username: user1
        uuid: ${VMESS_UUID}
        alterId: 0
    reality-config:
      dest: ${DEST}
      private-key: ${REALITY_PRIVATE_KEY}
      short-id:
        - ${SHORT_ID}
      server-names:
        - ${SERVER_NAME}
EOF_SERVER
}

write_client_config() {
  mkdir -p "$OUTDIR"

  cat > "$OUTDIR/client.yaml" <<EOF_CLIENT
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: true

proxies:
  - name: "${SS_NAME}"
    type: ss
    server: ${SERVER}
    port: ${SS_PORT}
    cipher: 2022-blake3-aes-256-gcm
    password: "${SS_PASSWORD}"
    udp: true

  - name: "${TROJAN_NAME}"
    type: trojan
    server: ${SERVER}
    port: ${TROJAN_PORT}
    password: "${TROJAN_PASSWORD}"
    udp: true
    sni: ${SERVER_NAME}
    client-fingerprint: chrome
    skip-cert-verify: true
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    network: tcp

  - name: "${VLESS_NAME}"
    type: vless
    server: ${SERVER}
    port: ${VLESS_PORT}
    udp: true
    uuid: ${VLESS_UUID}
    flow: xtls-rprx-vision
    packet-encoding: xudp
    tls: true
    servername: ${SERVER_NAME}
    client-fingerprint: chrome
    skip-cert-verify: true
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    encryption: ""
    network: tcp

  - name: "${VMESS_NAME}"
    type: vmess
    server: ${SERVER}
    port: ${VMESS_PORT}
    udp: true
    uuid: ${VMESS_UUID}
    alterId: 0
    cipher: auto
    packet-encoding: packetaddr
    global-padding: false
    authenticated-length: false
    tls: true
    servername: ${SERVER_NAME}
    client-fingerprint: chrome
    skip-cert-verify: true
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    network: tcp

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "${VLESS_NAME}"
      - "${TROJAN_NAME}"
      - "${VMESS_NAME}"
      - "${SS_NAME}"
      - DIRECT

rules:
  - MATCH,PROXY
EOF_CLIENT
}

write_share_links() {
  local ss_userinfo_b64
  local ss_tag trojan_tag vless_tag

  ss_tag="$(rawurlencode "$SS_NAME")"
  trojan_tag="$(rawurlencode "$TROJAN_NAME")"
  vless_tag="$(rawurlencode "$VLESS_NAME")"

  ss_userinfo_b64="$(b64_url_nopad "2022-blake3-aes-256-gcm:${SS_PASSWORD}")"
  SS_LINK="ss://${ss_userinfo_b64}@${SERVER}:${SS_PORT}#${ss_tag}"

  TROJAN_LINK="trojan://${TROJAN_PASSWORD}@${SERVER}:${TROJAN_PORT}?security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${trojan_tag}"

  VLESS_LINK="vless://${VLESS_UUID}@${SERVER}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${vless_tag}"

  VMESS_LINK="vmess://$(printf '%s' "$(cat <<JSON
{
  \"v\":\"2\",
  \"ps\":\"${VMESS_NAME}\",
  \"add\":\"${SERVER}\",
  \"port\":\"${VMESS_PORT}\",
  \"id\":\"${VMESS_UUID}\",
  \"aid\":\"0\",
  \"scy\":\"auto\",
  \"net\":\"tcp\",
  \"type\":\"none\",
  \"host\":\"\",
  \"path\":\"\",
  \"tls\":\"tls\",
  \"sni\":\"${SERVER_NAME}\",
  \"fp\":\"chrome\",
  \"pbk\":\"${REALITY_PUBLIC_KEY}\",
  \"sid\":\"${SHORT_ID}\",
  \"security\":\"reality\"
}
JSON
)" | openssl base64 -A)"

  cat > "$OUTDIR/share-links.txt" <<EOF_LINKS
${SS_LINK}
${TROJAN_LINK}
${VLESS_LINK}
${VMESS_LINK}
EOF_LINKS
}

write_qrcodes_png() {
  if ! have_cmd qrencode; then
    return 0
  fi

  mkdir -p "$OUTDIR/qrcodes"
  step "生成 PNG 二维码"

  qrencode -o "$OUTDIR/qrcodes/ss.png" "$SS_LINK"
  qrencode -o "$OUTDIR/qrcodes/trojan.png" "$TROJAN_LINK"
  qrencode -o "$OUTDIR/qrcodes/vless.png" "$VLESS_LINK"
  qrencode -o "$OUTDIR/qrcodes/vmess.png" "$VMESS_LINK"

  ok "PNG 二维码生成完成"
}

print_one_qrcode() {
  local title="$1"
  local content="$2"

  echo
  echo -e "${COLOR_CYAN}${COLOR_BOLD}[${title}]${COLOR_RESET}"
  if qrencode -t ANSIUTF8 "$content" >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$content"
  else
    qrencode -t UTF8 "$content"
  fi
  echo
}

print_qrcodes_terminal() {
  if ! have_cmd qrencode; then
    warn "未安装 qrencode，无法打印控制台二维码"
    return 0
  fi

  step "在控制台打印二维码"
  print_one_qrcode "$SS_NAME" "$SS_LINK"
  print_one_qrcode "$TROJAN_NAME" "$TROJAN_LINK"
  print_one_qrcode "$VLESS_NAME" "$VLESS_LINK"
  print_one_qrcode "$VMESS_NAME" "$VMESS_LINK"
  ok "控制台二维码打印完成"
}

backup_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    local backup
    backup="${file}.bak.$(date +%F-%H%M%S)"
    cp -a "$file" "$backup"
    ok "已备份现有配置: $backup"
  fi
}

write_systemd_service() {
  step "写入 systemd service"

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF_SERVICE
[Unit]
Description=mihomo Daemon
After=network.target NetworkManager.service systemd-networkd.service iwd.service

[Service]
Type=simple
WorkingDirectory=${CONFIG_DIR}
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=${MIHOMO_BIN} -f ${CONFIG_DIR}/config.yaml
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  ok "systemd service 已创建并 enable"
}

validate_config() {
  local cfg="$1"
  step "校验配置: $cfg"
  "$MIHOMO_BIN" -t -f "$cfg"
  ok "配置校验通过"
}

deploy_system_config() {
  local tmp_cfg
  tmp_cfg="$(mktemp)"

  cp -f "$OUTDIR/server.yaml" "$tmp_cfg"
  validate_config "$tmp_cfg"

  mkdir -p "$CONFIG_DIR"
  backup_if_exists "$CONFIG_DIR/config.yaml"
  cp -f "$tmp_cfg" "$CONFIG_DIR/config.yaml"
  rm -f "$tmp_cfg"

  systemctl restart "${SERVICE_NAME}"
  ok "已写入 ${CONFIG_DIR}/config.yaml 并重启 ${SERVICE_NAME}"
}

show_links_summary() {
  cat <<EOF_SUMMARY

分享链接:

[${SS_NAME}]
${SS_LINK}

[${TROJAN_NAME}]
${TROJAN_LINK}

[${VLESS_NAME}]
${VLESS_LINK}

[${VMESS_NAME}]
${VMESS_LINK}

EOF_SUMMARY
}

has_type() {
  local needle="$1"
  local item

  shift
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done

  return 1
}

append_yaml_block() {
  local file="$1"
  local block="$2"

  if grep -q '^listeners:' "$file"; then
    printf '\n%s\n' "$block" >> "$file"
  else
    printf '\nlisteners:\n%s\n' "$block" >> "$file"
  fi
}

extract_listeners_from_config() {
  local cfg="$1"

  if [ ! -f "$cfg" ]; then
    return 0
  fi

  awk '
    found && /^[^[:space:]][^:]*:/ { exit }
    found { print }
    /^listeners:[[:space:]]*$/ { found = 1 }
  ' "$cfg"
}

prepare_listener_cache() {
  local action="$1"
  local cfg="$2"
  local cache="$3"

  mkdir -p "$(dirname "$cache")"

  if [ "$action" = "overwrite" ]; then
    : > "$cache"
    return 0
  fi

  if [ -f "$cache" ]; then
    return 0
  fi

  extract_listeners_from_config "$cfg" > "$cache"
}

append_listener_cache() {
  local cache="$1"
  local type="$2"
  local port="$3"
  local name="$4"
  local password="$5"
  local uuid="$6"
  local public_key="$7"
  local private_key="$8"
  local short_id="$9"
  local cert_file="${10:-}"
  local key_file="${11:-}"

  {
    printf '\n- name: "%s"\n' "$name"
    printf '  type: %s\n' "$type"
    printf '  port: %s\n' "$port"
    if [ -n "$password" ]; then
      printf '  password: "%s"\n' "$password"
    fi
    if [ -n "$uuid" ]; then
      printf '  uuid: %s\n' "$uuid"
    fi
    if [ -n "$public_key" ]; then
      printf '  reality-public-key: %s\n' "$public_key"
    fi
    if [ -n "$private_key" ]; then
      printf '  reality-private-key: %s\n' "$private_key"
    fi
    if [ -n "$short_id" ]; then
      printf '  reality-short-id: %s\n' "$short_id"
    fi
    if [ -n "$cert_file" ]; then
      printf '  certificate: %s\n' "$cert_file"
    fi
    if [ -n "$key_file" ]; then
      printf '  private-key: %s\n' "$key_file"
    fi
  } >> "$cache"
}

detect_max_port_from_files() {
  local max_port=0
  local file
  local port

  for file in "$@"; do
    if [ ! -f "$file" ]; then
      continue
    fi

    while read -r port; do
      if [ "$port" -gt "$max_port" ]; then
        max_port="$port"
      fi
    done < <(sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file")
  done

  if [ "$max_port" -eq 0 ]; then
    max_port="$((BASE_PORT - 1))"
  fi

  printf '%s\n' "$max_port"
}

render_listener_config() {
  local cache="$1"
  local output="$2"
  local tmpdir
  local entry
  local type port password uuid private_key short_id cert_file key_file

  if [ ! -s "$cache" ]; then
    cat > "$output" <<EOF_CFG
mode: direct
log-level: ${LOG_LEVEL}
ipv6: true

listeners: []
EOF_CFG
    return 0
  fi

  cat > "$output" <<EOF_CFG
mode: direct
log-level: ${LOG_LEVEL}
ipv6: true

listeners:
EOF_CFG

  tmpdir="$(mktemp -d)"
  split_cache_entries "$cache" "$tmpdir"
  for entry in "$tmpdir"/entry-*; do
    [ -f "$entry" ] || continue
    type="$(get_cache_value "proxy-type" "$entry")"
    port="$(get_cache_value "proxy-port" "$entry")"
    password="$(get_yaml_value "password" "$entry")"
    uuid="$(get_yaml_value "uuid" "$entry")"
    private_key="$(get_yaml_value "reality-private-key" "$entry")"
    short_id="$(get_cache_value "reality-short-id" "$entry")"
    cert_file="$(get_yaml_value "certificate" "$entry")"
    key_file="$(get_yaml_value "private-key" "$entry")"

    case "$type" in
      ss|trojan|vless|vmess|anytls) ;;
      *)
        cat "$entry" >> "$output"
        continue
        ;;
    esac

    if [ -z "$port" ]; then
      cat "$entry" >> "$output"
      continue
    fi

    REALITY_PRIVATE_KEY="$private_key"
    SHORT_ID="$short_id"
    ANYTLS_CERT_FILE="$cert_file"
    ANYTLS_KEY_FILE="$key_file"
    build_listener_block "$type" "$port" "$password" "$uuid" >> "$output"
  done
  rm -rf "$tmpdir"
}

normalize_listeners() {
  sed '/^[[:space:]]*$/d' | sed 's/[[:space:]]*$//'
}

listeners_equal() {
  local cache="$1"
  local cfg="$2"
  local tmp_cache_cfg
  local tmp_cache_listeners
  local tmp_cfg_listeners

  tmp_cache_cfg="$(mktemp)"
  tmp_cache_listeners="$(mktemp)"
  tmp_cfg_listeners="$(mktemp)"

  render_listener_config "$cache" "$tmp_cache_cfg"
  extract_listeners_from_config "$tmp_cache_cfg" | normalize_listeners > "$tmp_cache_listeners"
  extract_listeners_from_config "$cfg" | normalize_listeners > "$tmp_cfg_listeners"

  if cmp -s "$tmp_cache_listeners" "$tmp_cfg_listeners"; then
    rm -f "$tmp_cache_cfg" "$tmp_cache_listeners" "$tmp_cfg_listeners"
    return 0
  fi

  rm -f "$tmp_cache_cfg" "$tmp_cache_listeners" "$tmp_cfg_listeners"
  return 1
}

sync_cache_from_config() {
  local cfg="$1"
  local cache="$2"

  mkdir -p "$(dirname "$cache")"
  normalize_cache_from_config "$cfg" "$cache"
  ok "已按现有 config 同步 listener 缓存: $cache"
  rebuild_client_artifacts "$cache"
}

overwrite_config_from_cache() {
  local cache="$1"
  local cfg="$2"
  local tmp_cfg

  tmp_cfg="$(mktemp)"
  render_listener_config "$cache" "$tmp_cfg"
  if [ -n "${MIHOMO_BIN:-}" ] || resolve_mihomo_bin; then
    validate_config "$tmp_cfg"
  else
    warn "未检测到 mihomo，跳过配置校验"
  fi

  mkdir -p "$(dirname "$cfg")"
  backup_if_exists "$cfg"
  cp -f "$tmp_cfg" "$cfg"
  rm -f "$tmp_cfg"
  ok "已用 listener 缓存覆盖 config: $cfg"
  rebuild_client_artifacts "$cache"
}

startup_cache_check() {
  local cfg="${CONFIG_DIR}/config.yaml"
  local cache="${LISTENER_CACHE}"
  local choice

  if [ ! -f "$cfg" ] && [ ! -f "$cache" ]; then
    return 0
  fi

  if [ -f "$cfg" ] && [ ! -f "$cache" ]; then
    warn "未找到 listener 缓存: $cache"
    choice="$(ask_option "请选择处理方式:" 1 "以现有 config 为准，生成缓存" "跳过")"
    case "$choice" in
      "以现有 config 为准，生成缓存")
        sync_cache_from_config "$cfg" "$cache"
        ;;
    esac
    return 0
  fi

  if [ ! -f "$cfg" ] && [ -f "$cache" ]; then
    warn "未找到 config: $cfg"
    choice="$(ask_option "请选择处理方式:" 1 "用缓存生成 config" "跳过")"
    case "$choice" in
      "用缓存生成 config")
        overwrite_config_from_cache "$cache" "$cfg"
        ;;
    esac
    return 0
  fi

  if listeners_equal "$cache" "$cfg"; then
    return 0
  fi

  warn "listener 缓存和现有 config 不一致"
  choice="$(ask_option "请选择以哪一份为准:" 1 "以现有 config 为准，覆盖缓存" "以缓存为准，覆盖 config")"
  case "$choice" in
    "以现有 config 为准，覆盖缓存")
      sync_cache_from_config "$cfg" "$cache"
      ;;
    "以缓存为准，覆盖 config")
      overwrite_config_from_cache "$cache" "$cfg"
      ;;
  esac
}

get_cache_value() {
  local key="$1"
  local file="$2"
  local yaml_key="$key"
  local value

  case "$key" in
    proxy-type) yaml_key="type" ;;
    proxy-name) yaml_key="name" ;;
    proxy-port) yaml_key="port" ;;
  esac

  value="$(get_yaml_value "$yaml_key" "$file")"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi

  sed -n "s/^# ${key}: //p" "$file" | head -n1
}

get_yaml_value() {
  local key="$1"
  local file="$2"

  sed -n \
    -e "s/^[[:space:]]*-[[:space:]]*${key}:[[:space:]]*//p" \
    -e "s/^[[:space:]]*${key}:[[:space:]]*//p" \
    "$file" | head -n1 | sed 's/^"//;s/"$//'
}

get_yaml_list_first() {
  local key="$1"
  local file="$2"

  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*$" {
      found = 1
      next
    }
    found && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
    found && /^[^[:space:]-]/ {
      exit
    }
  ' "$file" | head -n1
}

derive_reality_public_key() {
  local private_key="$1"
  local out
  local pub

  if [ -z "$private_key" ]; then
    return 0
  fi

  if ! resolve_mihomo_bin >/dev/null 2>&1; then
    return 0
  fi

  out="$("$MIHOMO_BIN" generate reality-keypair "$private_key" 2>/dev/null || true)"
  pub="$(printf '%s\n' "$out" | sed -n 's/.*Public[[:space:]]*Key:[[:space:]]*//p' | head -n1 | tr -d '\r')"
  printf '%s\n' "$pub"
}

split_cache_entries() {
  local cache="$1"
  local dir="$2"

  mkdir -p "$dir"
  awk -v dir="$dir" '
    /^[[:space:]]*-[[:space:]]*name:/ {
      n++
      file = sprintf("%s/entry-%04d", dir, n)
    }
    /^# proxy-entry-begin/ {
      n++
      file = sprintf("%s/entry-%04d", dir, n)
    }
    n > 0 {
      print > file
    }
  ' "$cache"
}

list_cache_entries() {
  local cache="${1:-$LISTENER_CACHE}"
  local tmpdir
  local entry
  local idx=1
  local type name port

  if [ ! -s "$cache" ]; then
    warn "listener 缓存为空或不存在: $cache" >&2
    return 0
  fi

  tmpdir="$(mktemp -d)"
  split_cache_entries "$cache" "$tmpdir"

  for entry in "$tmpdir"/entry-*; do
    [ -f "$entry" ] || continue
    type="$(get_cache_value "proxy-type" "$entry")"
    if [ "$type" = "shadowsocks" ]; then
      type="ss"
    fi
    name="$(get_cache_value "proxy-name" "$entry")"
    port="$(get_cache_value "proxy-port" "$entry")"
    printf '%s|%s|%s|%s|%s\n' "$idx" "$type" "$name" "$port" "$entry"
    idx="$((idx + 1))"
  done

  rm -rf "$tmpdir"
}

list_listener_yaml_entries() {
  local file="$1"
  local idx=1

  if [ ! -s "$file" ]; then
    return 0
  fi

  awk '
    function flush() {
      if (name != "" || type != "" || port != "") {
        print type "|" name "|" port
      }
    }
    /^[[:space:]]*-[[:space:]]*name:/ {
      flush()
      name = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", name)
      gsub(/^"|"$/, "", name)
      type = ""
      port = ""
      next
    }
    /^[[:space:]]*type:/ {
      type = $0
      sub(/^[[:space:]]*type:[[:space:]]*/, "", type)
      next
    }
    /^[[:space:]]*port:/ {
      port = $0
      sub(/^[[:space:]]*port:[[:space:]]*/, "", port)
      next
    }
    END {
      flush()
    }
  ' "$file" | while IFS='|' read -r type name port; do
    [ -n "$name$type$port" ] || continue
    printf '%s|%s|%s|%s\n' "$idx" "$type" "$name" "$port"
    idx="$((idx + 1))"
  done
}

normalize_cache_from_config() {
  local cfg="$1"
  local cache="$2"
  local tmp_listeners
  local tmpdir
  local entry
  local idx=1
  local type name port password uuid public_key private_key short_id cert_file key_file

  tmp_listeners="$(mktemp)"
  tmpdir="$(mktemp -d)"
  extract_listeners_from_config "$cfg" > "$tmp_listeners"
  split_cache_entries "$tmp_listeners" "$tmpdir"
  : > "$cache"

  for entry in "$tmpdir"/entry-*; do
    [ -f "$entry" ] || continue
    type="$(listener_type_to_proxy_type "$(get_cache_value "proxy-type" "$entry")")"
    name="$(get_cache_value "proxy-name" "$entry")"
    port="$(get_cache_value "proxy-port" "$entry")"
    password="$(get_yaml_value "password" "$entry")"
    if [ -z "$password" ]; then
      password="$(get_yaml_value "user1" "$entry")"
    fi
    uuid="$(get_yaml_value "uuid" "$entry")"
    public_key="$(get_yaml_value "reality-public-key" "$entry")"
    private_key=""
    short_id=""
    cert_file=""
    key_file=""

    case "$type" in
      trojan|vless|vmess)
        private_key="$(get_yaml_value "private-key" "$entry")"
        short_id="$(get_yaml_list_first "short-id" "$entry")"
        if [ -z "$public_key" ]; then
          public_key="$(derive_reality_public_key "$private_key")"
        fi
        ;;
      anytls)
        cert_file="$(get_yaml_value "certificate" "$entry")"
        key_file="$(get_yaml_value "private-key" "$entry")"
        ;;
    esac

    if [ -z "$name" ]; then
      name="${NODE_BASE_NAME} $(node_suffix "$idx")"
    fi

    append_listener_cache "$cache" "$type" "$port" "$name" "$password" "$uuid" "$public_key" "$private_key" "$short_id" "$cert_file" "$key_file"
    idx="$((idx + 1))"
  done

  rm -f "$tmp_listeners"
  rm -rf "$tmpdir"
}

detect_cache_prefix() {
  local cache="${1:-$LISTENER_CACHE}"
  local name

  if [ -f "$cache" ]; then
    name="$(sed -n -e 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*//p' -e 's/^# proxy-name: //p' "$cache" | head -n1 | sed 's/^"//;s/"$//')"
    if [ -n "$name" ]; then
      if [[ "$name" == *" 0x"* ]]; then
        printf '%s\n' "${name% 0x*}"
      else
        printf '%s\n' "${name% * *}"
      fi
      return 0
    fi
  fi

  printf '%s\n' "$NODE_BASE_NAME"
}

cache_entry_count() {
  local cache="$1"

  if [ ! -f "$cache" ]; then
    printf '%s\n' 0
    return 0
  fi

  awk '/^[[:space:]]*-[[:space:]]*name:/ || /^# proxy-entry-begin/ { n++ } END { print n + 0 }' "$cache"
}

node_suffix() {
  local index="$1"

  printf '0x%x\n' "$index"
}

write_all_client_from_cache() {
  local cache="$1"
  local client_file="$2"
  local links_file="$3"
  local tmpdir
  local entry
  local type name port password uuid public_key private_key short_id
  local names=()

  mkdir -p "$(dirname "$client_file")"
  cat > "$client_file" <<EOF_CLIENT_HEAD
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: true

proxies:
EOF_CLIENT_HEAD
  : > "$links_file"

  tmpdir="$(mktemp -d)"
  split_cache_entries "$cache" "$tmpdir"

  for entry in "$tmpdir"/entry-*; do
    [ -f "$entry" ] || continue
    type="$(get_cache_value "proxy-type" "$entry")"
    type="$(listener_type_to_proxy_type "$type")"
    name="$(get_cache_value "proxy-name" "$entry")"
    port="$(get_cache_value "proxy-port" "$entry")"
    public_key="$(get_cache_value "reality-public-key" "$entry")"
    private_key="$(get_yaml_value "reality-private-key" "$entry")"
    short_id="$(get_cache_value "reality-short-id" "$entry")"
    if [ -z "$public_key" ]; then
      public_key="$(derive_reality_public_key "$private_key")"
    fi
    password=""
    uuid=""

    case "$type" in
      ss)
        password="$(get_yaml_value "password" "$entry")"
        ;;
      trojan|anytls)
        password="$(get_yaml_value "password" "$entry")"
        if [ -z "$password" ]; then
          password="$(get_yaml_value "user1" "$entry")"
        fi
        ;;
      vless|vmess)
        uuid="$(get_yaml_value "uuid" "$entry")"
        ;;
      *)
        warn "跳过无法识别的缓存节点: $entry"
        continue
        ;;
    esac

    if [ -z "$name" ] || [ -z "$port" ]; then
      warn "跳过缺少元数据的缓存节点: $entry"
      continue
    fi

    REALITY_PUBLIC_KEY="$public_key"
    SHORT_ID="$short_id"
    append_client_proxy "$client_file" "$type" "$port" "$name" "$password" "$uuid"
    build_share_link "$type" "$port" "$name" "$password" "$uuid" >> "$links_file"
    names+=("$name")
  done

  rm -rf "$tmpdir"
  write_listener_client_files "$client_file" "$links_file" "${names[@]}"
}

rebuild_client_artifacts() {
  local cache="$1"
  local client_file="${OUTDIR}/listener-client.yaml"
  local links_file="${OUTDIR}/listener-share-links.txt"

  if [ ! -s "$cache" ]; then
    warn "listener 缓存为空，跳过生成 client/share-links"
    return 0
  fi

  SERVER="$(detect_public_ip || true)"
  if [ -z "${SERVER:-}" ]; then
    warn "自动探测公网 IP 失败"
    if [ -t 0 ]; then
      SERVER="$(ask_text "请手动输入服务器公网 IP")"
    fi
    if [ -z "${SERVER:-}" ]; then
      warn "服务器地址为空，跳过生成 client/share-links"
      return 0
    fi
  fi

  write_all_client_from_cache "$cache" "$client_file" "$links_file"
}

cache_entry_link() {
  local entry="$1"
  local type name port password uuid public_key private_key short_id

  type="$(get_cache_value "proxy-type" "$entry")"
  if [ "$type" = "shadowsocks" ]; then
    type="ss"
  fi
  name="$(get_cache_value "proxy-name" "$entry")"
  port="$(get_cache_value "proxy-port" "$entry")"
  public_key="$(get_cache_value "reality-public-key" "$entry")"
  private_key="$(get_yaml_value "reality-private-key" "$entry")"
  short_id="$(get_cache_value "reality-short-id" "$entry")"
  if [ -z "$public_key" ]; then
    public_key="$(derive_reality_public_key "$private_key")"
  fi
  password=""
  uuid=""

  case "$type" in
    ss)
      password="$(get_yaml_value "password" "$entry")"
      ;;
    trojan|anytls)
      password="$(get_yaml_value "password" "$entry")"
      if [ -z "$password" ]; then
        password="$(get_yaml_value "user1" "$entry")"
      fi
      ;;
    vless|vmess)
      uuid="$(get_yaml_value "uuid" "$entry")"
      ;;
  esac

  REALITY_PUBLIC_KEY="$public_key"
  SHORT_ID="$short_id"
  build_share_link "$type" "$port" "$name" "$password" "$uuid"
}

generate_anytls_cert() {
  local port="$1"
  local cert_dir="$2"

  mkdir -p "$cert_dir"
  ANYTLS_CERT_FILE="${cert_dir}/anytls-${port}.crt"
  ANYTLS_KEY_FILE="${cert_dir}/anytls-${port}.key"

  if [ -f "$ANYTLS_CERT_FILE" ] && [ -f "$ANYTLS_KEY_FILE" ]; then
    return 0
  fi

  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=${SERVER_NAME}" \
    -keyout "$ANYTLS_KEY_FILE" \
    -out "$ANYTLS_CERT_FILE" >/dev/null 2>&1
  chmod 0600 "$ANYTLS_KEY_FILE"
}

build_listener_block() {
  local type="$1"
  local port="$2"
  local password="$3"
  local uuid="$4"

  case "$type" in
    ss)
      cat <<EOF_BLOCK
  - name: ss-in-${port}
    type: shadowsocks
    listen: ${LISTEN}
    port: ${port}
    cipher: 2022-blake3-aes-256-gcm
    password: ${password}
    udp: true
EOF_BLOCK
      ;;
    trojan)
      cat <<EOF_BLOCK
  - name: trojan-in-${port}
    type: trojan
    listen: ${LISTEN}
    port: ${port}
    users:
      - username: user1
        password: ${password}
    reality-config:
      dest: ${DEST}
      private-key: ${REALITY_PRIVATE_KEY}
      short-id:
        - ${SHORT_ID}
      server-names:
        - ${SERVER_NAME}
EOF_BLOCK
      ;;
    vless)
      cat <<EOF_BLOCK
  - name: vless-in-${port}
    type: vless
    listen: ${LISTEN}
    port: ${port}
    users:
      - username: user1
        uuid: ${uuid}
        flow: xtls-rprx-vision
    reality-config:
      dest: ${DEST}
      private-key: ${REALITY_PRIVATE_KEY}
      short-id:
        - ${SHORT_ID}
      server-names:
        - ${SERVER_NAME}
EOF_BLOCK
      ;;
    vmess)
      cat <<EOF_BLOCK
  - name: vmess-in-${port}
    type: vmess
    listen: ${LISTEN}
    port: ${port}
    users:
      - username: user1
        uuid: ${uuid}
        alterId: 0
    reality-config:
      dest: ${DEST}
      private-key: ${REALITY_PRIVATE_KEY}
      short-id:
        - ${SHORT_ID}
      server-names:
        - ${SERVER_NAME}
EOF_BLOCK
      ;;
    anytls)
      cat <<EOF_BLOCK
  - name: anytls-in-${port}
    type: anytls
    listen: ${LISTEN}
    port: ${port}
    users:
      user1: ${password}
    certificate: ${ANYTLS_CERT_FILE}
    private-key: ${ANYTLS_KEY_FILE}
    padding-scheme: ""
EOF_BLOCK
      ;;
  esac
}

listener_type_to_proxy_type() {
  local type="$1"

  case "$type" in
    shadowsocks) printf '%s\n' "ss" ;;
    *) printf '%s\n' "$type" ;;
  esac
}

append_client_proxy() {
  local file="$1"
  local type="$2"
  local port="$3"
  local name="$4"
  local password="$5"
  local uuid="$6"

  case "$type" in
    ss)
      cat >> "$file" <<EOF_PROXY
  - name: "${name}"
    type: ss
    server: ${SERVER}
    port: ${port}
    cipher: 2022-blake3-aes-256-gcm
    password: "${password}"
    udp: true

EOF_PROXY
      ;;
    trojan)
      cat >> "$file" <<EOF_PROXY
  - name: "${name}"
    type: trojan
    server: ${SERVER}
    port: ${port}
    password: "${password}"
    udp: true
    sni: ${SERVER_NAME}
    client-fingerprint: chrome
    skip-cert-verify: true
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    network: tcp

EOF_PROXY
      ;;
    vless)
      cat >> "$file" <<EOF_PROXY
  - name: "${name}"
    type: vless
    server: ${SERVER}
    port: ${port}
    udp: true
    uuid: ${uuid}
    flow: xtls-rprx-vision
    packet-encoding: xudp
    tls: true
    servername: ${SERVER_NAME}
    client-fingerprint: chrome
    skip-cert-verify: true
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    encryption: ""
    network: tcp

EOF_PROXY
      ;;
    vmess)
      cat >> "$file" <<EOF_PROXY
  - name: "${name}"
    type: vmess
    server: ${SERVER}
    port: ${port}
    udp: true
    uuid: ${uuid}
    alterId: 0
    cipher: auto
    packet-encoding: packetaddr
    global-padding: false
    authenticated-length: false
    tls: true
    servername: ${SERVER_NAME}
    client-fingerprint: chrome
    skip-cert-verify: true
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    network: tcp

EOF_PROXY
      ;;
    anytls)
      cat >> "$file" <<EOF_PROXY
  - name: "${name}"
    type: anytls
    server: ${SERVER}
    port: ${port}
    password: "${password}"
    client-fingerprint: chrome
    udp: true
    idle-session-check-interval: 30
    idle-session-timeout: 30
    min-idle-session: 0
    sni: ${SERVER_NAME}
    alpn:
      - h2
      - http/1.1
    skip-cert-verify: true

EOF_PROXY
      ;;
  esac
}

build_share_link() {
  local type="$1"
  local port="$2"
  local name="$3"
  local password="$4"
  local uuid="$5"
  local tag
  local ss_userinfo_b64

  tag="$(rawurlencode "$name")"
  case "$type" in
    ss)
      ss_userinfo_b64="$(b64_url_nopad "2022-blake3-aes-256-gcm:${password}")"
      printf 'ss://%s@%s:%s#%s\n' "$ss_userinfo_b64" "$SERVER" "$port" "$tag"
      ;;
    trojan)
      printf 'trojan://%s@%s:%s?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' "$password" "$SERVER" "$port" "$SERVER_NAME" "$REALITY_PUBLIC_KEY" "$SHORT_ID" "$tag"
      ;;
    vless)
      printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' "$uuid" "$SERVER" "$port" "$SERVER_NAME" "$REALITY_PUBLIC_KEY" "$SHORT_ID" "$tag"
      ;;
    vmess)
      printf 'vmess://%s\n' "$(printf '%s' "$(cat <<JSON
{
  \"v\":\"2\",
  \"ps\":\"${name}\",
  \"add\":\"${SERVER}\",
  \"port\":\"${port}\",
  \"id\":\"${uuid}\",
  \"aid\":\"0\",
  \"scy\":\"auto\",
  \"net\":\"tcp\",
  \"type\":\"none\",
  \"host\":\"\",
  \"path\":\"\",
  \"tls\":\"tls\",
  \"sni\":\"${SERVER_NAME}\",
  \"fp\":\"chrome\",
  \"pbk\":\"${REALITY_PUBLIC_KEY}\",
  \"sid\":\"${SHORT_ID}\",
  \"security\":\"reality\"
}
JSON
)" | openssl base64 -A)"
      ;;
    anytls)
      printf 'anytls://%s@%s:%s/?sni=%s&insecure=1#%s\n' "$password" "$SERVER" "$port" "$SERVER_NAME" "$tag"
      ;;
  esac
}

write_listener_client_files() {
  local client_file="$1"
  local links_file="$2"
  shift 2
  local names=("$@")
  local name

  cat >> "$client_file" <<EOF_CLIENT_TAIL
proxy-groups:
  - name: PROXY
    type: select
    proxies:
EOF_CLIENT_TAIL

  for name in "${names[@]}"; do
    printf '      - "%s"\n' "$name" >> "$client_file"
  done

  cat >> "$client_file" <<EOF_CLIENT_TAIL
      - DIRECT

rules:
  - MATCH,PROXY
EOF_CLIENT_TAIL

  ok "新增 listener 客户端配置: $client_file"
  ok "新增 listener 分享链接: $links_file"
}

listener_setup() {
  local cfg="${CONFIG_DIR}/config.yaml"
  local cache="${LISTENER_CACHE}"
  local action
  local max_port
  local start_port
  local port
  local type
  local block
  local tmp_cfg
  local tmp_cache
  local password
  local uuid
  local name
  local client_file
  local links_file
  local cert_dir
  local start_status
  local prefix
  local default_prefix
  local next_node_index
  local selected_types=()
  local listener_names=()

  case "$SERVER_NAME" in
    *:*)
      err "SERVER_NAME 不能带端口"
      exit 1
      ;;
  esac

  need_root
  ensure_dependencies

  if ! resolve_mihomo_bin; then
    warn "未检测到可用的 mihomo"
    if ask_yes_no "是否由本脚本自动安装 mihomo？" "y"; then
      install_mihomo
    else
      err "未检测到可执行的 mihomo"
      exit 1
    fi
  fi

  mapfile -t selected_types < <(ask_proxy_types)

  if have_cmd systemctl && systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    warn "${SERVICE_NAME} 服务正在运行"
    action="$(ask_listener_action)"
  elif [ -f "$cfg" ]; then
    warn "检测到已有配置: $cfg"
    action="$(ask_listener_action)"
  else
    action="overwrite"
  fi

  tmp_cache="$(mktemp)"
  if [ "$action" = "overwrite" ]; then
    : > "$tmp_cache"
  elif [ -f "$cache" ]; then
    cp -f "$cache" "$tmp_cache"
  else
    extract_listeners_from_config "$cfg" > "$tmp_cache"
  fi

  info "listener 缓存: $cache"
  default_prefix="$(detect_cache_prefix "$tmp_cache")"
  prefix="$(ask_proxy_prefix "$default_prefix")"

  max_port="$(detect_max_port_from_files "$cfg" "$tmp_cache")"
  start_port="$(ask_start_port "$((max_port + 1))")"
  if [ "$((start_port + ${#selected_types[@]} - 1))" -gt 65535 ]; then
    err "端口范围超过 65535"
    exit 1
  fi

  SERVER="$(detect_public_ip || true)"
  if [ -z "${SERVER:-}" ]; then
    warn "自动探测公网 IP 失败"
    SERVER="$(ask_input "请手动输入服务器公网 IP")"
    if [ -z "$SERVER" ]; then
      err "服务器公网 IP 不能为空"
      exit 1
    fi
  else
    ok "公网 IP: $SERVER"
  fi

  cat <<EOF_SUMMARY

即将执行 add:
  操作模式: ${action}
  proxy type: ${selected_types[*]}
  节点前缀: ${prefix}
  起始端口: ${start_port}
  服务端地址: ${SERVER}
  服务端配置: ${cfg}
  listener 缓存: ${cache}
  客户端配置: ${OUTDIR}/listener-client.yaml
  分享链接: ${OUTDIR}/listener-share-links.txt

EOF_SUMMARY

  if ! ask_confirm "确认执行以上操作？" 1; then
    rm -f "$tmp_cache"
    warn "已取消"
    return 0
  fi

  if has_type trojan "${selected_types[@]}" || has_type vless "${selected_types[@]}" || has_type vmess "${selected_types[@]}"; then
    SHORT_ID="$(gen_short_id)"
    get_reality_keypair
  fi

  mkdir -p "$OUTDIR"
  client_file="$OUTDIR/listener-client.yaml"
  links_file="$OUTDIR/listener-share-links.txt"

  tmp_cfg="$(mktemp)"

  port="$start_port"
  next_node_index="$(( $(cache_entry_count "$tmp_cache") + 1 ))"
  for type in "${selected_types[@]}"; do
    password="$(gen_uuid)"
    uuid="$(gen_uuid)"
    name="${prefix} $(node_suffix "$next_node_index")"

    if [ "$type" = "ss" ]; then
      password="$(gen_ss_password)"
    fi

    if [ "$type" = "anytls" ]; then
      cert_dir="${CONFIG_DIR}/certs"
      generate_anytls_cert "$port" "$cert_dir"
    fi

    append_listener_cache "$tmp_cache" "$type" "$port" "$name" "$password" "$uuid" "${REALITY_PUBLIC_KEY:-}" "${REALITY_PRIVATE_KEY:-}" "${SHORT_ID:-}" "${ANYTLS_CERT_FILE:-}" "${ANYTLS_KEY_FILE:-}"
    listener_names+=("$name")
    port="$((port + 1))"
    next_node_index="$((next_node_index + 1))"
  done

  render_listener_config "$tmp_cache" "$tmp_cfg"
  validate_config "$tmp_cfg"
  write_all_client_from_cache "$tmp_cache" "$client_file" "$links_file"

  mkdir -p "$CONFIG_DIR"
  mkdir -p "$(dirname "$cache")"
  backup_if_exists "$cfg"
  cp -f "$tmp_cfg" "$cfg"
  cp -f "$tmp_cache" "$cache"
  rm -f "$tmp_cfg" "$tmp_cache"

  if have_cmd systemctl; then
    if [ ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
      write_systemd_service
    fi
    systemctl restart "${SERVICE_NAME}"
    start_status="已写入 ${cfg} 并重启 ${SERVICE_NAME}"
  else
    start_status="已写入 ${cfg}，但未检测到 systemctl，请手动启动 mihomo"
    warn "$start_status"
  fi

  cat <<EOF_DONE

完成

操作:
  ${action}

服务端配置:
  ${cfg}

客户端配置:
  ${client_file}

分享链接:
  ${links_file}

listener 缓存:
  ${cache}

端口:
EOF_DONE

  port="$start_port"
  for type in "${selected_types[@]}"; do
    printf '  %-7s %s\n' "$type" "$port"
    port="$((port + 1))"
  done

  cat <<EOF_DONE

systemd:
  状态: ${start_status}

EOF_DONE
}

restart_service_if_possible() {
  local start_status

  if have_cmd systemctl; then
    if [ ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
      write_systemd_service
    fi
    systemctl restart "${SERVICE_NAME}"
    start_status="已重启 ${SERVICE_NAME}"
  else
    start_status="未检测到 systemctl，请手动启动 mihomo"
    warn "$start_status"
  fi

  printf '%s\n' "$start_status"
}

status_setup() {
  local cache="${LISTENER_CACHE}"
  local cfg="${CONFIG_DIR}/config.yaml"
  local tmp_listeners
  local count=0
  local service_status="unknown"

  if have_cmd systemctl; then
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
      service_status="running"
    else
      service_status="stopped"
    fi
  else
    service_status="no-systemctl"
  fi

  printf '%-18s | %s\n' "ITEM" "VALUE"
  printf '%-18s-+-%s\n' "------------------" "----------------------------------------"
  printf '%-18s | %s\n' "service" "${SERVICE_NAME} (${service_status})"
  printf '%-18s | %s\n' "config" "$cfg"
  printf '%-18s | %s\n' "cache" "$cache"
  printf '%-18s | %s\n' "client" "${OUTDIR}/listener-client.yaml"
  printf '%-18s | %s\n' "share-links" "${OUTDIR}/listener-share-links.txt"

  echo
  printf '%-4s | %-8s | %-6s | %s\n' "NO" "TYPE" "PORT" "NAME"
  printf '%-4s-+-%-8s-+-%-6s-+-%s\n' "----" "--------" "------" "----------------------------------------"
  if [ -s "$cache" ]; then
    while IFS='|' read -r idx type name port _; do
      [ -n "${idx:-}" ] || continue
      count="$((count + 1))"
      printf '%-4s | %-8s | %-6s | %s\n' "$idx" "$type" "$port" "$name"
    done < <(list_cache_entries "$cache")

    if [ "$count" -eq 0 ]; then
      while IFS='|' read -r idx type name port; do
        [ -n "${idx:-}" ] || continue
        count="$((count + 1))"
        printf '%-4s | %-8s | %-6s | %s\n' "$idx" "$type" "$port" "$name"
      done < <(list_listener_yaml_entries "$cache")
    fi
  elif [ -f "$cfg" ]; then
    tmp_listeners="$(mktemp)"
    extract_listeners_from_config "$cfg" > "$tmp_listeners"
    while IFS='|' read -r idx type name port; do
      [ -n "${idx:-}" ] || continue
      count="$((count + 1))"
      printf '%-4s | %-8s | %-6s | %s\n' "$idx" "$type" "$port" "$name"
    done < <(list_listener_yaml_entries "$tmp_listeners")
    rm -f "$tmp_listeners"
  fi

  if [ "$count" -eq 0 ]; then
    printf '%-4s | %-8s | %-6s | %s\n' "-" "-" "-" "(无)"
  fi
}

delete_proxy_setup() {
  local cfg="${CONFIG_DIR}/config.yaml"
  local cache="${LISTENER_CACHE}"
  local tmpdir
  local tmp_cache
  local tmp_cfg
  local entry
  local idx=1
  local selected
  local selected_idx
  local type name port
  local labels=()
  local files=()
  local client_file="${OUTDIR}/listener-client.yaml"
  local links_file="${OUTDIR}/listener-share-links.txt"
  local start_status

  need_root

  if [ ! -s "$cache" ]; then
    warn "listener 缓存为空或不存在: $cache"
    return 0
  fi

  if ! resolve_mihomo_bin; then
    err "未检测到可执行的 mihomo，无法校验配置"
    exit 1
  fi

  tmpdir="$(mktemp -d)"
  split_cache_entries "$cache" "$tmpdir"
  for entry in "$tmpdir"/entry-*; do
    [ -f "$entry" ] || continue
    type="$(get_cache_value "proxy-type" "$entry")"
    name="$(get_cache_value "proxy-name" "$entry")"
    port="$(get_cache_value "proxy-port" "$entry")"
    labels+=("${type} ${port} ${name}")
    files+=("$entry")
    idx="$((idx + 1))"
  done

  if [ "${#labels[@]}" -eq 0 ]; then
    rm -rf "$tmpdir"
    warn "缓存中没有可删除的标准节点"
    return 0
  fi

  selected="$(ask_option "请选择要删除的 proxy:" 1 "${labels[@]}")"
  selected_idx=1
  for idx in "${!labels[@]}"; do
    if [ "$selected" = "${labels[$idx]}" ]; then
      selected_idx="$((idx + 1))"
      break
    fi
  done
  entry="${files[$((selected_idx - 1))]}"
  type="$(get_cache_value "proxy-type" "$entry")"
  name="$(get_cache_value "proxy-name" "$entry")"
  port="$(get_cache_value "proxy-port" "$entry")"

  SERVER="$(detect_public_ip || true)"
  if [ -z "${SERVER:-}" ]; then
    SERVER="$(ask_text "请手动输入服务器公网 IP")"
  fi

  cat <<EOF_SUMMARY

即将执行 delete:
  删除节点: ${name}
  proxy type: ${type}
  端口: ${port}
  服务端地址: ${SERVER}
  服务端配置: ${cfg}
  listener 缓存: ${cache}
  客户端配置: ${client_file}
  分享链接: ${links_file}

EOF_SUMMARY

  if ! ask_confirm "确认执行以上操作？" 2; then
    rm -rf "$tmpdir"
    warn "已取消"
    return 0
  fi

  tmp_cache="$(mktemp)"
  idx=1
  for entry in "$tmpdir"/entry-*; do
    [ -f "$entry" ] || continue
    if [ "$idx" -ne "$selected_idx" ]; then
      cat "$entry" >> "$tmp_cache"
      printf '\n' >> "$tmp_cache"
    fi
    idx="$((idx + 1))"
  done

  tmp_cfg="$(mktemp)"
  render_listener_config "$tmp_cache" "$tmp_cfg"
  validate_config "$tmp_cfg"
  write_all_client_from_cache "$tmp_cache" "$client_file" "$links_file"

  mkdir -p "$CONFIG_DIR"
  backup_if_exists "$cfg"
  cp -f "$tmp_cfg" "$cfg"
  cp -f "$tmp_cache" "$cache"
  rm -f "$tmp_cfg" "$tmp_cache"
  rm -rf "$tmpdir"

  start_status="$(restart_service_if_possible)"

  cat <<EOF_DONE

完成

已删除:
  ${name}

systemd:
  状态: ${start_status}

EOF_DONE
}

qrcode_setup() {
  local cache="${LISTENER_CACHE}"
  local client_file="${OUTDIR}/listener-client.yaml"
  local links_file="${OUTDIR}/listener-share-links.txt"
  local qrcode_dir="${OUTDIR}/qrcodes"
  local mode
  local tmpdir
  local entry
  local idx=1
  local type name port link file safe_name

  if [ ! -s "$cache" ]; then
    warn "listener 缓存为空或不存在: $cache"
    return 0
  fi

  if ! have_cmd qrencode; then
    warn "未安装 qrencode，二维码功能不可用"
    return 0
  fi

  SERVER="$(detect_public_ip || true)"
  if [ -z "${SERVER:-}" ]; then
    SERVER="$(ask_text "请手动输入服务器公网 IP")"
  fi

  mode="$(ask_option "请选择二维码输出方式:" 1 "PNG 文件" "控制台打印" "PNG 文件 + 控制台打印")"

  cat <<EOF_SUMMARY

即将执行 qrcode:
  输出方式: ${mode}
  服务端地址: ${SERVER}
  listener 缓存: ${cache}
  客户端配置: ${client_file}
  分享链接: ${links_file}
  二维码目录: ${qrcode_dir}

EOF_SUMMARY

  if ! ask_confirm "确认执行以上操作？" 1; then
    warn "已取消"
    return 0
  fi

  write_all_client_from_cache "$cache" "$client_file" "$links_file"
  mkdir -p "$qrcode_dir"

  tmpdir="$(mktemp -d)"
  split_cache_entries "$cache" "$tmpdir"
  for entry in "$tmpdir"/entry-*; do
    [ -f "$entry" ] || continue
    type="$(get_cache_value "proxy-type" "$entry")"
    name="$(get_cache_value "proxy-name" "$entry")"
    port="$(get_cache_value "proxy-port" "$entry")"
    link="$(cache_entry_link "$entry")"
    safe_name="$(printf '%s' "$name" | sed 's/[^A-Za-z0-9._-]/_/g')"
    file="${qrcode_dir}/${idx}-${type}-${port}-${safe_name}.png"

    case "$mode" in
      "PNG 文件"|"PNG 文件 + 控制台打印")
        qrencode -o "$file" "$link"
        ;;
    esac

    case "$mode" in
      "控制台打印"|"PNG 文件 + 控制台打印")
        print_one_qrcode "$name" "$link"
        ;;
    esac

    idx="$((idx + 1))"
  done
  rm -rf "$tmpdir"

  ok "二维码处理完成: $qrcode_dir"
}

deploy_setup() {
  local cache="${LISTENER_CACHE}"
  local cfg="${CONFIG_DIR}/config.yaml"
  local client_file="${OUTDIR}/listener-client.yaml"
  local links_file="${OUTDIR}/listener-share-links.txt"
  local start_status

  need_root

  if [ ! -s "$cache" ]; then
    warn "listener 缓存为空或不存在: $cache"
    return 0
  fi

  cat <<EOF_SUMMARY

即将执行 deploy:
  listener 缓存: ${cache}
  服务端配置: ${cfg}
  客户端配置: ${client_file}
  分享链接: ${links_file}

说明:
  将用当前缓存重新生成并覆盖 config，覆盖前会备份现有 config。

EOF_SUMMARY

  if ! ask_confirm "确认执行以上操作？" 2; then
    warn "已取消"
    return 0
  fi

  overwrite_config_from_cache "$cache" "$cfg"
  start_status="$(restart_service_if_possible)"

  cat <<EOF_DONE

完成

服务端配置:
  ${cfg}

listener 缓存:
  ${cache}

客户端配置:
  ${client_file}

分享链接:
  ${links_file}

systemd:
  状态: ${start_status}

EOF_DONE
}

cli_main() {
  local choice

  while true; do
    choice="$(ask_option "请选择功能模块:" 1 "status" "add" "delete" "deploy" "qrcode" "exit")"
    case "$choice" in
      status)
        run_command "status" status_setup
        ;;
      add)
        run_command "add" listener_setup
        ;;
      delete)
        run_command "delete" delete_proxy_setup
        ;;
      deploy)
        run_command "deploy" deploy_setup
        ;;
      qrcode)
        run_command "qrcode" qrcode_setup
        ;;
      exit)
        return 0
        ;;
    esac
    if [ ! -t 0 ]; then
      return 0
    fi
  done
}

interactive_setup() {
  step "Mihomo 部署向导"

  if resolve_mihomo_bin; then
    AUTO_INSTALL=0
  else
    warn "未检测到可用的 mihomo"
    if ask_yes_no "是否由本脚本自动安装 mihomo？" "y"; then
      AUTO_INSTALL=1
    else
      AUTO_INSTALL=0
    fi
  fi

  NODE_BASE_NAME="$(ask_input "请输入节点基础名称" "$NODE_BASE_NAME")"

  if ask_yes_no "是否写入 ${CONFIG_DIR}/config.yaml 并启动 mihomo？" "n"; then
    WRITE_SYSTEM_CONFIG=1
  else
    WRITE_SYSTEM_CONFIG=0
  fi

  if [ -z "${PRINT_QRCODE:-}" ]; then
    if ask_yes_no "是否在控制台打印二维码？" "y"; then
      PRINT_QRCODE=1
    else
      PRINT_QRCODE=0
    fi
  fi
}

main() {
  local start_status

  case "${1:-}" in
    help|-h|--help)
      show_help
      exit 0
      ;;
    status)
      shift
      run_command "status" status_setup "$@"
      exit 0
      ;;
    add)
      shift
      run_command "startup-check" startup_cache_check
      run_command "add" listener_setup "$@"
      exit 0
      ;;
    delete)
      shift
      run_command "startup-check" startup_cache_check
      run_command "delete" delete_proxy_setup "$@"
      exit 0
      ;;
    qrcode)
      shift
      run_command "startup-check" startup_cache_check
      run_command "qrcode" qrcode_setup "$@"
      exit 0
      ;;
    deploy)
      shift
      run_command "startup-check" startup_cache_check
      run_command "deploy" deploy_setup "$@"
      exit 0
      ;;
    legacy-deploy)
      shift
      ;;
    "")
      run_command "startup-check" startup_cache_check
      cli_main
      exit 0
      ;;
    legacy)
      ;;
    *)
      err "未知命令: $1"
      show_help
      exit 1
      ;;
  esac

  case "$SERVER_NAME" in
    *:*)
      err "SERVER_NAME 不能带端口"
      exit 1
      ;;
  esac

  need_root
  interactive_setup
  ensure_dependencies
  init_proxy_names

  if [ "$AUTO_INSTALL" = "1" ]; then
    install_mihomo
  else
    if ! resolve_mihomo_bin; then
      err "未检测到可执行的 mihomo，且未选择自动安装"
      exit 1
    fi
  fi

  step "检测公网 IP"
  SERVER="$(detect_public_ip || true)"
  if [ -z "${SERVER:-}" ]; then
    warn "自动探测公网 IP 失败"
    SERVER="$(ask_input "请手动输入服务器公网 IP")"
    if [ -z "$SERVER" ]; then
      err "服务器公网 IP 不能为空"
      exit 1
    fi
  else
    ok "公网 IP: $SERVER"
  fi

  SS_PASSWORD="$(gen_ss_password)"
  TROJAN_PASSWORD="$(gen_uuid)"
  VLESS_UUID="$(gen_uuid)"
  VMESS_UUID="$(gen_uuid)"
  SHORT_ID="$(gen_short_id)"

  get_reality_keypair

  step "生成配置与分享信息"
  mkdir -p "$OUTDIR"
  write_server_config
  write_client_config
  write_share_links
  write_qrcodes_png
  ok "配置输出完成"

  if [ "${PRINT_QRCODE:-0}" = "1" ]; then
    print_qrcodes_terminal
  fi

  write_systemd_service

  if [ "$WRITE_SYSTEM_CONFIG" = "1" ]; then
    deploy_system_config
    start_status="已写入系统配置并启动"
  else
    start_status="未写入系统配置，未启动 mihomo，仅创建 service"
    warn "$start_status"
  fi

  show_links_summary

  cat <<EOF_DONE

完成

服务器:
  ${SERVER}

mihomo:
  ${MIHOMO_BIN}

服务端配置(输出目录):
  ${OUTDIR}/server.yaml

客户端配置:
  ${OUTDIR}/client.yaml

分享链接:
  ${OUTDIR}/share-links.txt

二维码目录:
  ${OUTDIR}/qrcodes

节点名称:
  ${SS_NAME}
  ${TROJAN_NAME}
  ${VLESS_NAME}
  ${VMESS_NAME}

端口:
  SS      ${SS_PORT}
  Trojan  ${TROJAN_PORT}
  VLESS   ${VLESS_PORT}
  VMess   ${VMESS_PORT}

REALITY:
  publicKey  ${REALITY_PUBLIC_KEY}
  shortId    ${SHORT_ID}

systemd:
  /etc/systemd/system/${SERVICE_NAME}.service
  状态: ${start_status}

常用命令:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -o cat -f

EOF_DONE
}

main "$@"
