#!/usr/bin/env bash
# Install or update mihomo on Linux and configure it as a boot service.
# Usage:
#   sudo bash install-mihomo.sh [CONFIG_YAML_URL]
#   sudo MIHOMO_CONFIG_URL='https://example.com/config.yaml' bash install-mihomo.sh
set -Eeuo pipefail

REPO="MetaCubeX/mihomo"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
BIN_PATH="/usr/local/bin/mihomo"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_NAME="mihomo"
CONFIG_URL="${1:-${MIHOMO_CONFIG_URL:-}}"
TMP_DIR=""
INIT_SYSTEM=""
ASSET_ARCH=""
ASSET_URL=""
VERSION=""

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请以 root 运行：sudo bash $0 [配置文件URL]"
}

install_dependencies() {
  local need=()
  command -v curl >/dev/null 2>&1 || need+=(curl)
  command -v gzip >/dev/null 2>&1 || need+=(gzip)
  command -v install >/dev/null 2>&1 || need+=(coreutils)
  ((${#need[@]} == 0)) && return 0

  log "安装依赖：${need[*]} ca-certificates"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl gzip ca-certificates coreutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl gzip ca-certificates coreutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl gzip ca-certificates coreutils
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl gzip ca-certificates coreutils
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl gzip ca-certificates coreutils
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl gzip ca-certificates coreutils
  else
    die "缺少 curl/gzip/install，且无法识别包管理器，请先手动安装依赖。"
  fi
}

detect_init() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    INIT_SYSTEM="systemd"
  elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  else
    die "未检测到正在运行的 systemd 或 OpenRC；请手动建立服务。"
  fi
  log "服务管理器：${INIT_SYSTEM}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ASSET_ARCH="amd64" ;;
    i386|i486|i586|i686) ASSET_ARCH="386" ;;
    aarch64|arm64) ASSET_ARCH="arm64" ;;
    armv7l|armv7) ASSET_ARCH="armv7" ;;
    riscv64) ASSET_ARCH="riscv64" ;;
    loongarch64|loong64) ASSET_ARCH="loong64" ;;
    s390x) ASSET_ARCH="s390x" ;;
    mips|mipsel|mips64|mips64el) ASSET_ARCH="mips" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
  log "CPU 架构：$(uname -m) -> ${ASSET_ARCH}"
}

resolve_release_asset() {
  local json urls
  json="${TMP_DIR}/release.json"
  curl -fsSL --retry 3 --connect-timeout 10 "${API_URL}" -o "${json}" \
    || die "无法读取 GitHub 最新稳定版信息。"

  VERSION="$(sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "${json}" | head -n1)"
  [[ -n "${VERSION}" ]] || die "无法解析 mihomo 版本号。"

  urls="$(grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' "${json}" \
    | sed -E 's/^.*"(https:[^"]+)"$/\1/')"

  if [[ "${ASSET_ARCH}" == "amd64" ]]; then
    ASSET_URL="$(printf '%s\n' "${urls}" | grep -E '/mihomo-linux-amd64-compatible-[^/]+\.gz$' | head -n1 || true)"
  fi
  if [[ -z "${ASSET_URL}" ]]; then
    ASSET_URL="$(printf '%s\n' "${urls}" | grep -E "/mihomo-linux-${ASSET_ARCH}-[^/]+\\.gz$" | head -n1 || true)"
  fi
  [[ -n "${ASSET_URL}" ]] || die "版本 ${VERSION} 中找不到 linux/${ASSET_ARCH} 的 .gz 二进制资产。"
  log "将安装版本：${VERSION}"
}

install_binary() {
  local archive binary
  archive="${TMP_DIR}/mihomo.gz"
  binary="${TMP_DIR}/mihomo"
  log "下载 mihomo 二进制文件"
  curl -fL --retry 3 --connect-timeout 10 "${ASSET_URL}" -o "${archive}" \
    || die "下载 mihomo 失败。"
  gzip -dc "${archive}" > "${binary}" || die "解压 mihomo 失败。"
  chmod 0755 "${binary}"
  install -Dm0755 "${binary}" "${BIN_PATH}"
  "${BIN_PATH}" -v 2>/dev/null || true
}

install_config() {
  local backup=""
  install -d -m0755 "${CONFIG_DIR}"
  if [[ -f "${CONFIG_FILE}" ]]; then
    backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  if [[ -n "${CONFIG_URL}" ]]; then
    [[ -n "${backup}" ]] && cp -a "${CONFIG_FILE}" "${backup}"
    log "下载配置文件到 ${CONFIG_FILE}"
    curl -fL --retry 3 --connect-timeout 10 --max-time 180 "${CONFIG_URL}" -o "${CONFIG_FILE}.tmp" \
      || die "配置文件下载失败；原配置未改变。"
    install -m0600 "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
    rm -f "${CONFIG_FILE}.tmp"
  elif [[ ! -f "${CONFIG_FILE}" ]]; then
    log "未提供配置 URL，创建可启动的 DIRECT 默认配置"
    cat > "${CONFIG_FILE}" <<'YAML'
mixed-port: 7890
log-level: info
ipv6: true
external-controller: 127.0.0.1:9090
external-ui: ui
external-ui-url: "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
YAML
    chmod 0600 "${CONFIG_FILE}"
    warn "当前默认配置不包含代理节点；随后请替换 ${CONFIG_FILE} 并重启服务。"
  else
    log "保留现有配置：${CONFIG_FILE}"
  fi

  if ! "${BIN_PATH}" -t -d "${CONFIG_DIR}"; then
    [[ -n "${backup}" && -f "${backup}" ]] && cp -a "${backup}" "${CONFIG_FILE}"
    die "mihomo 配置校验失败；已尽量恢复旧配置。"
  fi
}

install_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<'UNIT'
[Unit]
Description=Mihomo Proxy Service
Documentation=https://wiki.metacubex.one/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
}

install_openrc_service() {
  cat > "/etc/init.d/${SERVICE_NAME}" <<'RC'
#!/sbin/openrc-run
name="mihomo"
description="Mihomo Proxy Service"
command="/usr/local/bin/mihomo"
command_args="-d /etc/mihomo"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/mihomo.log"
error_log="/var/log/mihomo.err.log"

depend() {
  need net
  after firewall
}
RC
  chmod 0755 "/etc/init.d/${SERVICE_NAME}"
  rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true
  if rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
    rc-service "${SERVICE_NAME}" restart
  else
    rc-service "${SERVICE_NAME}" start
  fi
  rc-service "${SERVICE_NAME}" status || true
}

main() {
  require_root
  TMP_DIR="$(mktemp -d)"
  install_dependencies
  detect_init
  detect_arch
  resolve_release_asset
  install_binary
  install_config
  log "安装并启动 ${SERVICE_NAME} 服务"
  case "${INIT_SYSTEM}" in
    systemd) install_systemd_service ;;
    openrc) install_openrc_service ;;
  esac
  log "完成。二进制：${BIN_PATH}；配置：${CONFIG_FILE}"
  if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
    printf '查看日志：journalctl -u %s -f\n' "${SERVICE_NAME}"
  else
    printf '查看日志：tail -f /var/log/mihomo.log /var/log/mihomo.err.log\n'
  fi
}

main "$@"
