#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="tkwarpsock5"
APP_DIR="/etc/${APP_NAME}"
LOG_FILE="/var/log/${APP_NAME}.log"
CONFIG_FILE="${APP_DIR}/config.env"
DOMAIN_FILE="${APP_DIR}/tiktok-domains.txt"
ROUTE_FILE="${APP_DIR}/v2node-route.json"
SYSTEMD_SERVICE="/etc/systemd/system/${APP_NAME}-wireproxy.service"
DEFAULT_PORT="40000"
PORT="${DEFAULT_PORT}"
ROUTE_ONLY="0"
UNINSTALL="0"
ADDED_DOMAINS=()
BACKEND="auto"

DEFAULT_DOMAINS=(
  "muscdn.com"
  "musical.ly"
  "sgpstatp.com"
  "snssdk.com"
  "tik-tokapi.com"
  "tiktok.com"
  "tiktokcdn.com"
  "tiktokv.com"
  "byteoversea.com"
  "ibytedtos.com"
  "ibyteimg.com"
  "ipstatp.com"
  "p16-tiktokcdn-com.akamaized.net"
)

usage() {
  cat <<'USAGE'
tkwarpsock5 - TikTok WARP SOCKS5 splitter helper for v2node

Usage:
  bash tkwarpsock5.sh [options]

Options:
  --port PORT             SOCKS5 listen port, default: 40000
  --add-domain DOMAIN     Add extra TikTok domain, can be repeated
  --route-only            Only regenerate /etc/tkwarpsock5/v2node-route.json
  --uninstall             Remove services/config created by this script
  -h, --help              Show help

Examples:
  bash tkwarpsock5.sh
  bash tkwarpsock5.sh --port 40001 --add-domain example.com
  bash tkwarpsock5.sh --route-only
USAGE
}

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run() {
  log "+ $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)
        [ "$#" -ge 2 ] || die "--port requires a value"
        PORT="$2"
        shift 2
        ;;
      --add-domain)
        [ "$#" -ge 2 ] || die "--add-domain requires a value"
        ADDED_DOMAINS+=("$2")
        shift 2
        ;;
      --route-only)
        ROUTE_ONLY="1"
        shift
        ;;
      --uninstall)
        UNINSTALL="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "please run as root"
}

validate_port() {
  case "$PORT" in
    ''|*[!0-9]*) die "port must be a number" ;;
  esac
  [ "$PORT" -ge 1000 ] && [ "$PORT" -le 65535 ] || die "port must be 1000-65535"
}

load_existing_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    PORT="${SOCKS_PORT:-$PORT}"
    BACKEND="${BACKEND:-$BACKEND}"
  fi
}

detect_os() {
  [ -r /etc/os-release ] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
}

install_packages() {
  detect_os
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update -y
    run apt-get install -y ca-certificates curl wget gnupg lsb-release jq iproute2
  elif have dnf; then
    run dnf install -y ca-certificates curl wget gnupg jq iproute iproute-tc
  elif have yum; then
    run yum install -y ca-certificates curl wget gnupg jq iproute
  else
    die "unsupported package manager; need apt-get, dnf or yum"
  fi
}

port_in_use() {
  local p="$1"
  ss -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${p}$"
}

pick_port() {
  validate_port
  if ! port_in_use "$PORT"; then
    return
  fi
  local p
  for p in $(seq 40001 40020); do
    if ! port_in_use "$p"; then
      log "port ${PORT} is in use, switch to ${p}"
      PORT="$p"
      return
    fi
  done
  die "no free port found in 40000-40020"
}

install_cloudflare_warp_apt() {
  local codename="$OS_CODENAME"
  case "$OS_ID:$codename" in
    debian:) codename="bookworm" ;;
    ubuntu:) codename="jammy" ;;
  esac
  install -m 0755 -d /usr/share/keyrings /etc/apt/sources.list.d
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg -o /tmp/cloudflare-warp-pubkey.gpg
  gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg /tmp/cloudflare-warp-pubkey.gpg
  chmod a+r /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$codename" > /etc/apt/sources.list.d/cloudflare-client.list
  if ! apt-get update -y; then
    case "$OS_ID" in
      debian) codename="bookworm" ;;
      ubuntu) codename="jammy" ;;
      *) return 1 ;;
    esac
    printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$codename" > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -y
  fi
  apt-get install -y cloudflare-warp
}

install_cloudflare_warp_rpm() {
  local repo_file="/etc/yum.repos.d/cloudflare-warp.repo"
  cat > "$repo_file" <<'EOF'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF
  if have dnf; then
    dnf install -y cloudflare-warp
  else
    yum install -y cloudflare-warp
  fi
}

install_cloudflare_warp() {
  if have warp-cli; then
    return 0
  fi
  log "install Cloudflare WARP client"
  if have apt-get; then
    install_cloudflare_warp_apt
  elif have dnf || have yum; then
    install_cloudflare_warp_rpm
  else
    return 1
  fi
}

configure_cloudflare_proxy() {
  have warp-cli || return 1
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
  sleep 2
  warp-cli --accept-tos registration new >/dev/null 2>&1 || true
  warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "$PORT" >/dev/null
  warp-cli --accept-tos mode proxy >/dev/null
  warp-cli --accept-tos connect >/dev/null
  sleep 5
  BACKEND="cloudflare-warp-proxy"
}

install_cloudflare_client_proxy() {
  log "try WARP Linux Client proxy mode"
  install_cloudflare_warp || return 1
  configure_cloudflare_proxy
}

install_wireproxy_binary() {
  if have wireproxy; then
    return 0
  fi
  local arch url tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7*) arch="arm" ;;
    *) die "unsupported wireproxy architecture: $arch" ;;
  esac
  tmp="/tmp/wireproxy-${arch}"
  url="https://github.com/pufferffish/wireproxy/releases/latest/download/wireproxy_linux_${arch}.tar.gz"
  mkdir -p /tmp/wireproxy-install
  curl -fsSL "$url" -o "$tmp.tar.gz"
  tar -xzf "$tmp.tar.gz" -C /tmp/wireproxy-install
  install -m 0755 "$(find /tmp/wireproxy-install -type f -name wireproxy | head -n 1)" /usr/local/bin/wireproxy
}

create_wgcf_profile() {
  if [ -s "${APP_DIR}/wgcf-profile.conf" ]; then
    return 0
  fi
  mkdir -p "$APP_DIR"
  local arch url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7*) arch="armv7" ;;
    *) die "unsupported wgcf architecture: $arch" ;;
  esac
  url="https://gitlab.com/rwkgyg/CFwarp/-/raw/main/wgcf_2.2.22_${arch}"
  curl -fsSL "$url" -o /usr/local/bin/wgcf
  chmod +x /usr/local/bin/wgcf
  (
    cd "$APP_DIR"
    yes | wgcf register
    wgcf generate
    mv wgcf-profile.conf wgcf-profile.conf.tmp
    sed 's#engage.cloudflareclient.com:2408#[2606:4700:d0::a29f:c001]:2408#g' wgcf-profile.conf.tmp > wgcf-profile.conf
    rm -f wgcf-profile.conf.tmp
  )
}

configure_wireproxy() {
  install_wireproxy_binary
  create_wgcf_profile
  local private_key address public_key endpoint
  private_key="$(awk -F' = ' '/^PrivateKey/{print $2; exit}' "${APP_DIR}/wgcf-profile.conf")"
  address="$(awk -F' = ' '/^Address = 172\./{print $2; exit}' "${APP_DIR}/wgcf-profile.conf")"
  public_key="$(awk -F' = ' '/^PublicKey/{print $2; exit}' "${APP_DIR}/wgcf-profile.conf")"
  endpoint="$(awk -F' = ' '/^Endpoint/{print $2; exit}' "${APP_DIR}/wgcf-profile.conf")"
  [ -n "$private_key" ] && [ -n "$address" ] && [ -n "$public_key" ] && [ -n "$endpoint" ] || return 1
  cat > "${APP_DIR}/wireproxy.conf" <<EOF
[Interface]
Address = ${address}
PrivateKey = ${private_key}
DNS = 1.1.1.1

[Peer]
PublicKey = ${public_key}
Endpoint = ${endpoint}
AllowedIPs = 0.0.0.0/0

[Socks5]
BindAddress = 127.0.0.1:${PORT}
EOF
  cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=tkwarpsock5 WireProxy SOCKS5 service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wireproxy -c ${APP_DIR}/wireproxy.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}-wireproxy.service"
  sleep 5
  BACKEND="wireproxy"
}

test_socks() {
  local trace
  trace="$(curl --socks5-hostname "127.0.0.1:${PORT}" -fsSL --max-time 20 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  if printf '%s\n' "$trace" | grep -q '^warp=on'; then
    printf '%s\n' "$trace" | grep -E '^(ip|colo|warp)=' | tee -a "$LOG_FILE"
    return 0
  fi
  if printf '%s\n' "$trace" | grep -q '^ip='; then
    printf '%s\n' "$trace" | grep -E '^(ip|colo|warp)=' | tee -a "$LOG_FILE"
    return 0
  fi
  return 1
}

write_domains() {
  mkdir -p "$APP_DIR"
  {
    printf '%s\n' "${DEFAULT_DOMAINS[@]}"
    if [ "${#ADDED_DOMAINS[@]}" -gt 0 ]; then
      printf '%s\n' "${ADDED_DOMAINS[@]}"
    fi
    if [ -f "$DOMAIN_FILE" ]; then
      sed '/^\s*$/d' "$DOMAIN_FILE"
    fi
  } | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort -u > "${DOMAIN_FILE}.tmp"
  mv "${DOMAIN_FILE}.tmp" "$DOMAIN_FILE"
}

json_escape() {
  jq -Rn --arg v "$1" '$v'
}

write_route_json() {
  write_domains
  local outbound_json encoded
  outbound_json="$(jq -cn --argjson port "$PORT" '{
    protocol: "socks",
    tag: "tiktok-warp",
    settings: {
      servers: [
        {
          address: "127.0.0.1",
          port: $port
        }
      ]
    }
  }')"
  encoded="$(json_escape "$outbound_json")"
  {
    printf '{\n'
    printf '  "action": "route",\n'
    printf '  "match": [\n'
    awk '{ printf "    \"domain:%s\"%s\n", $0, (NR==total ? "" : ",") }' total="$(wc -l < "$DOMAIN_FILE" | tr -d ' ')" "$DOMAIN_FILE"
    printf '  ],\n'
    printf '  "action_value": %s\n' "$encoded"
    printf '}\n'
  } > "$ROUTE_FILE"
}

write_config() {
  mkdir -p "$APP_DIR"
  cat > "$CONFIG_FILE" <<EOF
SOCKS_HOST=127.0.0.1
SOCKS_PORT=${PORT}
BACKEND=${BACKEND}
ROUTE_FILE=${ROUTE_FILE}
DOMAIN_FILE=${DOMAIN_FILE}
EOF
}

uninstall_all() {
  log "uninstall ${APP_NAME}"
  systemctl disable --now "${APP_NAME}-wireproxy.service" >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_SERVICE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if have warp-cli; then
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos mode warp >/dev/null 2>&1 || true
  fi
  rm -rf "$APP_DIR"
  log "uninstall finished"
}

print_summary() {
  cat <<EOF

tkwarpsock5 finished.

SOCKS5: 127.0.0.1:${PORT}
Backend: ${BACKEND}
Route: ${ROUTE_FILE}
Domains: ${DOMAIN_FILE}
Log: ${LOG_FILE}

Verify:
  curl --socks5-hostname 127.0.0.1:${PORT} https://www.cloudflare.com/cdn-cgi/trace

v2node:
  Copy ${ROUTE_FILE} into the route config of the target node in your panel,
  then restart v2node or wait for it to pull the latest node config.

EOF
}

main() {
  parse_args "$@"
  require_root
  load_existing_config
  validate_port

  if [ "$UNINSTALL" = "1" ]; then
    uninstall_all
    exit 0
  fi

  if [ "$ROUTE_ONLY" = "1" ]; then
    have jq || die "--route-only requires jq"
  else
    install_packages
    pick_port
  fi

  if [ "$ROUTE_ONLY" != "1" ]; then
    if install_cloudflare_client_proxy && test_socks; then
      log "Cloudflare WARP proxy mode is ready"
    else
      log "Cloudflare WARP proxy mode failed; try wireproxy fallback"
      configure_wireproxy
      test_socks || die "SOCKS5 WARP test failed"
    fi
  fi

  write_route_json
  write_config
  print_summary
}

main "$@"
