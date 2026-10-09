#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
trap 'rm -f /run/wg-easy-install.netrc' EXIT

# Полная подготовка Debian-сервера по схеме:
#   kornode             — vpn-b, certificate-only;
#   kornode-upstream    — vpn-a, kornode + P12-upstream к vpn-b;
#   wireguard-upstream  — vpn-a, kornode + P12-upstream + wg-easy/AmneziaWG.
#
# Все обычные параметры можно передать через окружение. Секреты, отсутствующие
# в окружении, скрипт запросит без отображения ввода.

readonly KORNODE_DIR=/etc/compose/kornode
readonly WIREGUARD_DIR=/etc/compose/wireguard
readonly KORNODE_IMAGE="${KORNODE_IMAGE:-ghcr.io/r4ven-me/kornode:raven}"
readonly WG_EASY_IMAGE="${WG_EASY_IMAGE:-ghcr.io/wg-easy/wg-easy:15.4.0}"

ROLE=""
FORCE=false
SKIP_DOCKER=false
NO_START=false
readonly TTY=/dev/tty
readonly SCRIPT_URL=https://raw.githubusercontent.com/r4ven-me/bash/main/kornode.sh
ORIGINAL_ARGS=("$@")

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./setup-kornode-servers.sh [options] ROLE
  sudo ./setup-kornode-servers.sh issue-p12 [CLIENT_ID]

ROLE:
  kornode             Kornode VPN server (certificate-only, no upstream)
  kornode-upstream    Kornode VPN server (password-only) with P12 upstream
  wireguard-upstream  Same as kornode-upstream plus wg-easy/AmneziaWG

Options:
  --force         Back up and overwrite existing stack configuration
  --skip-docker   Do not install Docker Engine/Compose; verify them only
  --no-start      Create configuration but do not pull/start containers
  -h, --help      Show this help

Required environment variables for every ROLE (prompted when interactive):
  SERVER_PUBLIC_IP       Public/listen IPv4 address
  KORNODE_DOMAIN         VPN domain name
  KORNODE_IPV4_NETWORK   Client network, e.g. 10.30.30.0/24

Required for *-upstream:
  VPN_B_DOMAIN           Upstream Kornode domain
  VPN_B_DNS_IP           Upstream DNS/check IP, e.g. 10.30.30.1
  VPN_B_P12_FILE         Path to vpn-a-upstream.p12
  VPN_B_P12_PASSWORD     P12 password (secret prompt if unset)
  VPN_B_CAMOUFLAGE_SECRET  Upstream Kornode camouflage secret (secret prompt)

Optional variables:
  KORNODE_PANEL_PORT=3003
  SYSTEM_DNS_IP=<first nameserver from /etc/resolv.conf>
  LETSENCRYPT_EMAIL=      Enable Let's Encrypt when non-empty
  WG_IPV4_CIDR=10.10.10.0/24
  WG_INIT_USERNAME=admin
  WG_INIT_PASSWORD=       Generated when unset
  WG_PANEL_PORT=3004
  WG_VPN_PORT=443

Certificate provisioning on a standalone Kornode server:
  sudo ./setup-kornode-servers.sh issue-p12 vpn-a-upstream

Examples:
  SERVER_PUBLIC_IP=203.0.113.10 KORNODE_DOMAIN=vpn-b.example.com \
    KORNODE_IPV4_NETWORK=10.30.30.0/24 \
    sudo -E ./setup-kornode-servers.sh kornode

  SERVER_PUBLIC_IP=203.0.113.20 KORNODE_DOMAIN=vpn-a.example.com \
    KORNODE_IPV4_NETWORK=10.20.20.0/24 VPN_B_DOMAIN=vpn-b.example.com \
    VPN_B_DNS_IP=10.30.30.1 VPN_B_P12_FILE=./vpn-a-upstream.p12 \
    sudo -E ./setup-kornode-servers.sh wireguard-upstream
EOF
}

while (($#)); do
  case "$1" in
    --force) FORCE=true ;;
    --skip-docker) SKIP_DOCKER=true ;;
    --no-start) NO_START=true ;;
    -h|--help) usage; exit 0 ;;
    kornode|kornode-upstream|wireguard-upstream|issue-p12)
      [[ -z "$ROLE" ]] || die "Only one role/command may be specified"
      ROLE=$1
      ;;
    *)
      if [[ "$ROLE" == issue-p12 && -z "${P12_CLIENT_ID:-}" ]]; then
        P12_CLIENT_ID=$1
      else
        die "Unknown argument: $1"
      fi
      ;;
  esac
  shift
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Root privileges are required, but sudo is not installed"
  printf '\nДля установки нужны права root. Введите пароль sudo.\n' >&2
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    exec sudo -E -- bash "${BASH_SOURCE[0]}" "${ORIGINAL_ARGS[@]}"
  fi
  exec sudo -E -- bash -c \
    'curl -fsSL "$1" | bash -s -- "${@:2}"' \
    bash "$SCRIPT_URL" "${ORIGINAL_ARGS[@]}"
fi

if [[ -z "$ROLE" ]]; then
  [[ -r "$TTY" && -w "$TTY" ]] || { usage >&2; die "ROLE is required without an interactive terminal"; }
  cat > "$TTY" <<'EOF'

Выберите тип сервера:
  1) kornode — standalone vpn-b, certificate-only
  2) kornode-upstream — kornode vpn-a с upstream через vpn-b
  3) wireguard-upstream — kornode vpn-a + wg-easy через vpn-b
EOF
  read -r -p 'Номер [1-3]: ' role_choice < "$TTY"
  case "$role_choice" in
    1) ROLE=kornode ;;
    2) ROLE=kornode-upstream ;;
    3) ROLE=wireguard-upstream ;;
    *) die "Invalid server type: $role_choice" ;;
  esac
fi

prompt_value() {
  local name=$1 prompt=$2 default=${3:-} value
  value=${!name:-}
  if [[ -z "$value" ]]; then
    [[ -r "$TTY" && -w "$TTY" ]] || die "$name is required without an interactive terminal"
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " value < "$TTY"
      value=${value:-$default}
    else
      read -r -p "$prompt: " value < "$TTY"
    fi
  fi
  [[ -n "$value" ]] || die "$name must not be empty"
  printf -v "$name" '%s' "$value"
  export "${name?}"
}

prompt_secret() {
  local name=$1 prompt=$2 value
  value=${!name:-}
  if [[ -z "$value" ]]; then
    [[ -r "$TTY" && -w "$TTY" ]] || die "$name is required without an interactive terminal"
    read -r -s -p "$prompt: " value < "$TTY"
    printf '\n' > "$TTY"
  fi
  [[ -n "$value" ]] || die "$name must not be empty"
  printf -v "$name" '%s' "$value"
}

backup_or_refuse() {
  local path=$1 backup
  [[ ! -e "$path" ]] && return 0
  $FORCE || die "$path already exists; use --force to back it up and overwrite"
  backup="${path}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$path" "$backup"
  log "Existing stack moved to backup: $backup"
}

validate_port() {
  local value=$1 name=$2
  [[ "$value" =~ ^[0-9]+$ ]] || die "Invalid $name"
  ((10#$value >= 1 && 10#$value <= 65535)) || die "Invalid $name"
}

validate_inputs() {
  python3 - "$SERVER_PUBLIC_IP" "$KORNODE_IPV4_NETWORK" "${WG_IPV4_CIDR:-}" "$SYSTEM_DNS_IP" <<'PY'
import ipaddress
import sys
ipaddress.IPv4Address(sys.argv[1])
ipaddress.IPv4Network(sys.argv[2], strict=True)
if sys.argv[3]:
    ipaddress.IPv4Network(sys.argv[3], strict=True)
ipaddress.IPv4Address(sys.argv[4])
PY
  [[ "$KORNODE_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid KORNODE_DOMAIN"
  validate_port "$KORNODE_PANEL_PORT" KORNODE_PANEL_PORT
  [[ -z "${LETSENCRYPT_EMAIL:-}" || "$LETSENCRYPT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] \
    || die "Invalid LETSENCRYPT_EMAIL"
  [[ "$VPN_SERVER_ADMIN_PASSWORD" != *$'\n'* && "$VPN_SERVER_ADMIN_PASSWORD" != *$'\r'* ]] \
    || die "VPN_SERVER_ADMIN_PASSWORD must not contain line breaks"
  [[ "$VPN_SERVER_CAMOUFLAGE_SECRET" != *$'\n'* && "$VPN_SERVER_CAMOUFLAGE_SECRET" != *$'\r'* ]] \
    || die "VPN_SERVER_CAMOUFLAGE_SECRET must not contain line breaks"

  if [[ "$ROLE" == *-upstream ]]; then
    [[ "$VPN_B_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid VPN_B_DOMAIN"
    python3 - "$VPN_B_DNS_IP" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
    [[ -r "$VPN_B_P12_FILE" ]] || die "Cannot read VPN_B_P12_FILE: $VPN_B_P12_FILE"
    [[ "$VPN_B_P12_FILE" != "$KORNODE_DIR"/* ]] \
      || die "Store VPN_B_P12_FILE outside $KORNODE_DIR so --force cannot move it"
    [[ "$VPN_B_P12_PASSWORD" != *$'\n'* && "$VPN_B_P12_PASSWORD" != *$'\r'* ]] \
      || die "VPN_B_P12_PASSWORD must not contain line breaks"
    [[ "$VPN_B_CAMOUFLAGE_SECRET" != *$'\n'* && "$VPN_B_CAMOUFLAGE_SECRET" != *$'\r'* ]] \
      || die "VPN_B_CAMOUFLAGE_SECRET must not contain line breaks"
  fi

  if [[ "$ROLE" == wireguard-upstream ]]; then
    validate_port "$WG_PANEL_PORT" WG_PANEL_PORT
    validate_port "$WG_VPN_PORT" WG_VPN_PORT
  fi
}

preflight_existing_stacks() {
  if [[ -e "$KORNODE_DIR" ]] && ! $FORCE; then
    die "$KORNODE_DIR already exists; use --force to back it up and replace it"
  fi
  if [[ "$ROLE" == wireguard-upstream && -e "$WIREGUARD_DIR" ]] && ! $FORCE; then
    die "$WIREGUARD_DIR already exists; use --force to back it up and replace it"
  fi
}

check_debian() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == debian ]] || die "This installer supports Debian only (found: ${ID:-unknown})"
}

install_base_packages() {
  log "Installing base packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gpg openssl iproute2 iptables python3
}

install_docker() {
  if $SKIP_DOCKER; then
    command -v docker >/dev/null || die "Docker is not installed"
    docker compose version >/dev/null || die "Docker Compose plugin is not installed"
    return
  fi
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    log "Docker Engine and Compose plugin already installed"
    systemctl enable --now docker
    return
  fi

  log "Installing Docker Engine from the official Debian repository"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod 0644 /etc/apt/keyrings/docker.gpg
  local arch codename
  arch=$(dpkg --print-architecture)
  codename=$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian %s stable\n' \
    "$arch" "$codename" > /etc/apt/sources.list.d/docker.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

prepare_kernel() {
  log "Preparing TUN, vhost-net and IPv4 forwarding"
  cat > /etc/modules-load.d/kornode.conf <<'EOF'
tun
vhost_net
EOF
  modprobe tun
  modprobe vhost_net || warn "vhost_net could not be loaded; accelerated TUN mapping will be omitted"
  [[ -c /dev/net/tun ]] || die "/dev/net/tun is unavailable"
  cat > /etc/sysctl.d/90-kornode-forwarding.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null
}

write_kornode_compose() {
  local vhost_device=""
  if [[ -c /dev/vhost-net ]]; then
    vhost_device='      - /dev/vhost-net:/dev/vhost-net'
  fi
  cat > "$KORNODE_DIR/compose.yaml" <<EOF
---
name: kornode
services:
  kornode:
    image: $KORNODE_IMAGE
    container_name: kornode
    restart: unless-stopped
    stop_grace_period: 30s
    hostname: kornode
    cap_add:
      - NET_ADMIN
      - NET_RAW
    network_mode: host
    env_file:
      - ./.env
    devices:
      - /dev/net/tun:/dev/net/tun
$vhost_device
    volumes:
      - ./config:/etc/kornode
      - ./data:/var/lib/kornode
      - ./logs:/var/log/kornode
EOF
}

write_kornode_config() {
  local password_auth certificate_auth client_policy dns_ip
  if [[ "$ROLE" == kornode ]]; then
    password_auth=false
    certificate_auth=true
    client_policy=off
  else
    password_auth=true
    certificate_auth=false
    client_policy=full
  fi
  dns_ip=$(python3 - "$KORNODE_IPV4_NETWORK" <<'PY'
import ipaddress, sys
print(next(ipaddress.IPv4Network(sys.argv[1]).hosts()))
PY
)

  cat > "$KORNODE_DIR/config/config.yaml" <<EOF
---
system:
  timezone: Europe/Moscow
  data_dir: /var/lib/kornode
  log_dir: /var/log/kornode
  generated_dir: /var/lib/kornode/generated
  secrets_dir: /var/lib/kornode/secrets
  log_level: info
  project_name: kornode
  log_rotation:
    enabled: true
    max_size_mb: 50
    max_age: 0
    max_age_unit: days
    keep_files: 3

server:
  enabled: true
  listen: $SERVER_PUBLIC_IP
  port: 443
  udp_enabled: false
  cn: $KORNODE_DOMAIN
  ipv4_network: $KORNODE_IPV4_NETWORK
  camouflage:
    enabled: true
    secret: \${SECRET:VPN_SERVER_CAMOUFLAGE_SECRET}
    realm: Web service

auth:
  password:
    enabled: $password_auth
  certificate:
    enabled: $certificate_auth

routing:
  client_policy: $client_policy
  host_policy: "off"
  main_interface: auto

internal_dns:
  listen: $dns_ip
  port: 53
  upstreams:
    - $SYSTEM_DNS_IP

web:
  enabled: true
  listen: 127.0.0.1
  port: $KORNODE_PANEL_PORT
  tls: false
  allow_insecure_http: true
  session_cookie_secure: false
  admin_user: admin
  admin_password: \${SECRET:VPN_SERVER_ADMIN_PASSWORD}
  terminal_enabled: true

cli:
  enabled: true
EOF

  if [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
    cat >> "$KORNODE_DIR/config/config.yaml" <<EOF

certificates:
  letsencrypt:
    enabled: true
    email: $LETSENCRYPT_EMAIL
    domains:
      - $KORNODE_DOMAIN
    renew_reload: true
    auto_renew_enabled: true
    auto_renew_interval: 7
    auto_renew_interval_unit: days
    http01_address: $SERVER_PUBLIC_IP
    http01_port: 80
EOF
  fi

  if [[ "$ROLE" == *-upstream ]]; then
    cat >> "$KORNODE_DIR/config/config.yaml" <<EOF

upstream:
  enabled: true
  interface: oc-middle0
  active_profile: vpn-b
  connect_on_boot: true
  check_interval: 5
  check_threshold: 3
  check_settle_seconds: 15
  failover: false
  profiles:
    - name: vpn-b
      kind: openconnect
      enabled: true
      server: $VPN_B_DOMAIN
      port: "443"
      interface: oc-middle0
      auth_type: p12
      trusted_cert: true
      cert_file_base64: "\${SECRET:VPN_B_UPSTREAM_P12_BASE64}"
      cert_pass: "\${SECRET:VPN_B_UPSTREAM_P12_PASSWORD}"
      camouflage_secret: "\${SECRET:VPN_B_CAMOUFLAGE_SECRET}"
      check_host: $VPN_B_DNS_IP
EOF
  fi
  chmod 0600 "$KORNODE_DIR/config/config.yaml"
}

write_kornode_unit() {
  cat > "$KORNODE_DIR/kornode.service" <<'EOF'
[Unit]
Description=kornode compose stack
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/etc/compose/kornode
ExecStart=/usr/bin/docker compose up --remove-orphans
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=5
TimeoutStartSec=60
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
  ln -sfn "$KORNODE_DIR/kornode.service" /etc/systemd/system/kornode.service
}

setup_kornode() {
  log "Writing Kornode stack"
  if [[ -e "$KORNODE_DIR" ]] && $FORCE; then
    if [[ "$ROLE" == wireguard-upstream ]]; then
      systemctl stop wg-easy-upstream-route.timer wireguard.service 2>/dev/null || true
    fi
    systemctl stop kornode.service 2>/dev/null || true
  fi
  backup_or_refuse "$KORNODE_DIR"
  mkdir -p "$KORNODE_DIR"/{config,data,logs}
  chmod 0700 "$KORNODE_DIR"

  VPN_SERVER_ADMIN_PASSWORD=${VPN_SERVER_ADMIN_PASSWORD:-$(openssl rand -hex 24)}
  VPN_SERVER_CAMOUFLAGE_SECRET=${VPN_SERVER_CAMOUFLAGE_SECRET:-$(openssl rand -hex 32)}

  {
    printf 'VPN_SERVER_ADMIN_PASSWORD=%s\n' "$VPN_SERVER_ADMIN_PASSWORD"
    printf 'VPN_SERVER_CAMOUFLAGE_SECRET=%s\n' "$VPN_SERVER_CAMOUFLAGE_SECRET"
    if [[ "$ROLE" == *-upstream ]]; then
      local p12_base64
      p12_base64=$(base64 -w0 "$VPN_B_P12_FILE")
      printf 'VPN_B_UPSTREAM_P12_BASE64=%s\n' "$p12_base64"
      printf 'VPN_B_UPSTREAM_P12_PASSWORD=%s\n' "$VPN_B_P12_PASSWORD"
      printf 'VPN_B_CAMOUFLAGE_SECRET=%s\n' "$VPN_B_CAMOUFLAGE_SECRET"
      unset p12_base64
    fi
  } > "$KORNODE_DIR/.env"
  chmod 0600 "$KORNODE_DIR/.env"

  write_kornode_compose
  write_kornode_config
  write_kornode_unit
  systemctl daemon-reload

  if ! $NO_START; then
    docker compose -f "$KORNODE_DIR/compose.yaml" pull
    systemctl enable --now kornode
    wait_for_container kornode 90
    docker compose -f "$KORNODE_DIR/compose.yaml" exec -T kornode korctl config validate
  fi
}

wait_for_container() {
  local name=$1 timeout=$2 i
  for ((i=0; i<timeout; i++)); do
    if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true; then
      return 0
    fi
    sleep 1
  done
  systemctl --no-pager --full status "${name}.service" || true
  die "Container $name did not start within ${timeout}s"
}

install_amneziawg() {
  [[ $(dpkg --print-architecture) == amd64 ]] || die "The configured Amnezia focal PPA is supported here only for amd64"
  log "Installing AmneziaWG DKMS module"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential ca-certificates curl dkms gnupg2 "linux-headers-$(uname -r)"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828' \
    | gpg --dearmor --yes -o /etc/apt/keyrings/amnezia-archive-keyring.gpg
  chmod 0644 /etc/apt/keyrings/amnezia-archive-keyring.gpg
  cat > /etc/apt/sources.list.d/amnezia.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/amnezia-archive-keyring.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
EOF
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg
  printf '%s\n' amneziawg > /etc/modules-load.d/amneziawg.conf
  modprobe amneziawg
  modinfo amneziawg >/dev/null
}

write_wireguard_stack() {
  cat > "$WIREGUARD_DIR/compose.yaml" <<EOF
---
name: wireguard
services:
  wireguard:
    image: $WG_EASY_IMAGE
    container_name: wireguard
    restart: unless-stopped
    stop_grace_period: 30s
    hostname: wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    env_file:
      - ./.env
    network_mode: host
    healthcheck:
      test: ["CMD-SHELL", "/usr/bin/timeout 5s /bin/sh -c '/usr/bin/awg show | /bin/grep -q interface'"]
      interval: 60s
      timeout: 5s
      retries: 3
    volumes:
      - ./data:/etc/wireguard/
      - /lib/modules/:/lib/modules:ro
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
EOF

  cat > "$WIREGUARD_DIR/.env" <<EOF
TZ=Europe/Moscow
EXPERIMENTAL_AWG=true
OVERRIDE_AUTO_AWG=awg
LANG=en
DISABLE_IPV6=true
PORT=$WG_PANEL_PORT
HOST=127.0.0.1
INSECURE=true
INIT_ENABLED=true
INIT_USERNAME=$WG_INIT_USERNAME
INIT_PASSWORD=$WG_INIT_PASSWORD
INIT_HOST=$SERVER_PUBLIC_IP
INIT_PORT=$WG_VPN_PORT
INIT_DNS=$VPN_B_DNS_IP
INIT_IPV4_CIDR=$WG_IPV4_CIDR
INIT_IPV6_CIDR=fd00:db8::/64
INIT_ALLOWED_IPS=0.0.0.0/0
WG_HOST=$SERVER_PUBLIC_IP
EOF
  chmod 0600 "$WIREGUARD_DIR/.env"

  cat > "$WIREGUARD_DIR/wireguard.service" <<'EOF'
[Unit]
Description=wireguard (wg-easy) compose stack
After=network-online.target docker.service kornode.service
Wants=network-online.target
Requires=docker.service kornode.service

[Service]
Type=simple
WorkingDirectory=/etc/compose/wireguard
ExecStartPre=/bin/sh -c 'for i in $(seq 1 90); do ip link show oc-middle0 >/dev/null 2>&1 && exit 0; sleep 1; done; echo "oc-middle0 did not appear" >&2; exit 1'
ExecStart=/usr/bin/docker compose up --remove-orphans
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=5
TimeoutStartSec=150
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
  ln -sfn "$WIREGUARD_DIR/wireguard.service" /etc/systemd/system/wireguard.service
}

write_route_reconciler() {
  cat > /usr/local/sbin/wg-easy-upstream-route <<EOF
#!/bin/sh
set -eu
WG_DEVICE=wg0
WG_CIDR=$WG_IPV4_CIDR
UPSTREAM=oc-middle0
TABLE=200
PRIORITY=150

ip link show dev "\$WG_DEVICE" >/dev/null 2>&1 || exit 0
while iptables -D FORWARD -i "\$WG_DEVICE" -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -o "\$WG_DEVICE" -j ACCEPT 2>/dev/null; do :; done
while iptables -D INPUT -p udp --dport "$WG_VPN_PORT" -j ACCEPT 2>/dev/null; do :; done
ip route replace blackhole default metric 32767 table "\$TABLE"
ip rule show priority "\$PRIORITY" | grep -Fq "from \$WG_CIDR lookup \$TABLE" || \
  ip rule add from "\$WG_CIDR" table "\$TABLE" priority "\$PRIORITY"
ip link show dev "\$UPSTREAM" >/dev/null 2>&1 || exit 0
ip route replace default dev "\$UPSTREAM" metric 1 table "\$TABLE"
iptables -t nat -C POSTROUTING -s "\$WG_CIDR" -o "\$UPSTREAM" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "\$WG_CIDR" -o "\$UPSTREAM" -j MASQUERADE
iptables -C FORWARD -i "\$WG_DEVICE" -s "\$WG_CIDR" -o "\$UPSTREAM" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "\$WG_DEVICE" -s "\$WG_CIDR" -o "\$UPSTREAM" -j ACCEPT
iptables -C FORWARD -i "\$UPSTREAM" -o "\$WG_DEVICE" -d "\$WG_CIDR" \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "\$UPSTREAM" -o "\$WG_DEVICE" -d "\$WG_CIDR" \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -C FORWARD -i "\$WG_DEVICE" ! -s "\$WG_CIDR" -j DROP 2>/dev/null || \
  iptables -A FORWARD -i "\$WG_DEVICE" ! -s "\$WG_CIDR" -j DROP
EOF
  chmod 0755 /usr/local/sbin/wg-easy-upstream-route

  cat > /etc/systemd/system/wg-easy-upstream-route.service <<'EOF'
[Unit]
Description=Reconcile wg-easy routing through kornode upstream
After=network-online.target kornode.service wireguard.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-easy-upstream-route
EOF

  cat > /etc/systemd/system/wg-easy-upstream-route.timer <<'EOF'
[Unit]
Description=Periodically reconcile wg-easy upstream routing

[Timer]
OnBootSec=15s
OnUnitActiveSec=15s
AccuracySec=1s
Unit=wg-easy-upstream-route.service

[Install]
WantedBy=timers.target
EOF
}

configure_wireguard_api() {
  local api="http://127.0.0.1:${WG_PANEL_PORT}/api" post_up post_down payload i
  local netrc=/run/wg-easy-install.netrc
  post_up="IFACE=\"oc-middle0\"; ip route replace blackhole default metric 32767 table 200; ip route replace default dev \"\$IFACE\" metric 1 table 200; ip rule show priority 150 | grep -Fq \"from $WG_IPV4_CIDR lookup 200\" || ip rule add from $WG_IPV4_CIDR table 200 priority 150; iptables -t nat -C POSTROUTING -s $WG_IPV4_CIDR -o \"\$IFACE\" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $WG_IPV4_CIDR -o \"\$IFACE\" -j MASQUERADE; iptables -C FORWARD -i wg0 -s $WG_IPV4_CIDR -o \"\$IFACE\" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -s $WG_IPV4_CIDR -o \"\$IFACE\" -j ACCEPT; iptables -C FORWARD -i \"\$IFACE\" -o wg0 -d $WG_IPV4_CIDR -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i \"\$IFACE\" -o wg0 -d $WG_IPV4_CIDR -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -C FORWARD -i wg0 ! -s $WG_IPV4_CIDR -j DROP 2>/dev/null || iptables -A FORWARD -i wg0 ! -s $WG_IPV4_CIDR -j DROP"
  post_down="IFACE=\"oc-middle0\"; while iptables -D FORWARD -i wg0 ! -s $WG_IPV4_CIDR -j DROP 2>/dev/null; do :; done; while iptables -D FORWARD -i \"\$IFACE\" -o wg0 -d $WG_IPV4_CIDR -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done; while iptables -D FORWARD -i wg0 -s $WG_IPV4_CIDR -o \"\$IFACE\" -j ACCEPT 2>/dev/null; do :; done; while iptables -t nat -D POSTROUTING -s $WG_IPV4_CIDR -o \"\$IFACE\" -j MASQUERADE 2>/dev/null; do :; done; ip rule del from $WG_IPV4_CIDR table 200 priority 150 2>/dev/null || true; ip route flush table 200 2>/dev/null || true"

  [[ "$WG_INIT_USERNAME" != *[[:space:]]* && "$WG_INIT_PASSWORD" != *[[:space:]]* ]] \
    || die "wg-easy bootstrap credentials must not contain whitespace"
  printf 'machine 127.0.0.1 login %s password %s\n' \
    "$WG_INIT_USERNAME" "$WG_INIT_PASSWORD" > "$netrc"
  chmod 0600 "$netrc"

  for ((i=0; i<60; i++)); do
    if curl -fsS --netrc-file "$netrc" "$api/admin/hooks" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  ((i < 60)) || die "wg-easy API did not become ready"

  payload=$(POST_UP="$post_up" POST_DOWN="$post_down" python3 - <<'PY'
import json, os
print(json.dumps({"preUp": "", "postUp": os.environ["POST_UP"],
                  "preDown": "", "postDown": os.environ["POST_DOWN"]}))
PY
)
  curl -fsS --netrc-file "$netrc" \
    -H 'Content-Type: application/json' -X POST --data-binary "$payload" \
    "$api/admin/hooks" >/dev/null
  curl -fsS --netrc-file "$netrc" \
    -H 'Content-Type: application/json' -X POST --data '{}' \
    "$api/admin/interface/restart" >/dev/null

  # INIT_* is bootstrap-only; remove password after successful API setup.
  sed -i '/^INIT_/d' "$WIREGUARD_DIR/.env"
  docker compose -f "$WIREGUARD_DIR/compose.yaml" up -d --force-recreate wireguard
  rm -f "$netrc"
}

setup_wireguard() {
  install_amneziawg
  log "Writing wg-easy stack and fail-closed upstream routing"
  if [[ -e "$WIREGUARD_DIR" ]] && $FORCE; then
    systemctl stop wg-easy-upstream-route.timer wireguard.service 2>/dev/null || true
  fi
  backup_or_refuse "$WIREGUARD_DIR"
  mkdir -p "$WIREGUARD_DIR/data"
  chmod 0700 "$WIREGUARD_DIR"
  write_wireguard_stack
  write_route_reconciler
  systemctl daemon-reload

  if ! $NO_START; then
    ip link show oc-middle0 >/dev/null 2>&1 || die "Kornode upstream interface oc-middle0 is not available"
    docker compose -f "$WIREGUARD_DIR/compose.yaml" pull
    systemctl enable --now wireguard
    wait_for_container wireguard 150
    configure_wireguard_api
    systemctl enable --now wg-easy-upstream-route.timer
    systemctl start wg-easy-upstream-route.service
  fi
}

issue_p12() {
  [[ -d "$KORNODE_DIR" ]] || die "$KORNODE_DIR does not exist"
  local client_id=${P12_CLIENT_ID:-vpn-a-upstream} password
  [[ "$client_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid client ID"
  prompt_secret password "P12 password"
  cd "$KORNODE_DIR"
  docker compose exec -T kornode korctl config validate
  grep -q '^auth = "certificate"$' data/generated/ocserv.conf \
    || die "Kornode is not configured as certificate-only"
  docker compose exec -T kornode korctl user cert create "$client_id"
  docker compose exec -T kornode korctl user p12 create "$client_id" --passphrase "$password"
  unset password
  printf '\nP12 created: %s/data/certs/users/%s.p12\n' "$KORNODE_DIR" "$client_id"
  printf 'Transfer it to the upstream client server over a secure channel.\n'
}

if [[ "$ROLE" == issue-p12 ]]; then
  issue_p12
  exit 0
fi

check_debian
prompt_value SERVER_PUBLIC_IP "Server public/listen IPv4 address"
prompt_value KORNODE_DOMAIN "Kornode domain"
prompt_value KORNODE_IPV4_NETWORK "Kornode client IPv4 network"
KORNODE_PANEL_PORT=${KORNODE_PANEL_PORT:-3003}
SYSTEM_DNS_IP=${SYSTEM_DNS_IP:-$(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ {print $2; exit}' /etc/resolv.conf)}
[[ -n "$SYSTEM_DNS_IP" ]] || prompt_value SYSTEM_DNS_IP "Upstream DNS IPv4 address"

if [[ "$ROLE" == *-upstream ]]; then
  prompt_value VPN_B_DOMAIN "Upstream Kornode domain"
  prompt_value VPN_B_DNS_IP "Upstream Kornode DNS/check IPv4 address"
  prompt_value VPN_B_P12_FILE "Path to upstream P12 file"
  VPN_B_P12_FILE=$(realpath "$VPN_B_P12_FILE")
  prompt_secret VPN_B_P12_PASSWORD "Upstream P12 password"
  prompt_secret VPN_B_CAMOUFLAGE_SECRET "Upstream Kornode camouflage secret"
fi

if [[ "$ROLE" == wireguard-upstream ]]; then
  WG_IPV4_CIDR=${WG_IPV4_CIDR:-10.10.10.0/24}
  WG_INIT_USERNAME=${WG_INIT_USERNAME:-admin}
  WG_INIT_PASSWORD=${WG_INIT_PASSWORD:-$(openssl rand -hex 24)}
  WG_PANEL_PORT=${WG_PANEL_PORT:-3004}
  WG_VPN_PORT=${WG_VPN_PORT:-443}
fi

VPN_SERVER_ADMIN_PASSWORD=${VPN_SERVER_ADMIN_PASSWORD:-$(openssl rand -hex 24)}
VPN_SERVER_CAMOUFLAGE_SECRET=${VPN_SERVER_CAMOUFLAGE_SECRET:-$(openssl rand -hex 32)}
validate_inputs
preflight_existing_stacks
install_base_packages
install_docker
prepare_kernel
setup_kornode
[[ "$ROLE" == wireguard-upstream ]] && setup_wireguard

printf '\n============================================================\n'
printf 'Installation completed for role: %s\n' "$ROLE"
printf 'Kornode panel: http://127.0.0.1:%s (use an SSH tunnel)\n' "$KORNODE_PANEL_PORT"
printf 'Kornode admin user: admin\n'
printf 'Kornode admin password: %s\n' "$VPN_SERVER_ADMIN_PASSWORD"
printf 'Kornode camouflage secret: %s\n' "$VPN_SERVER_CAMOUFLAGE_SECRET"
if [[ "$ROLE" == wireguard-upstream ]]; then
  printf 'wg-easy panel: http://127.0.0.1:%s (use an SSH tunnel)\n' "$WG_PANEL_PORT"
  printf 'wg-easy admin user: %s\n' "$WG_INIT_USERNAME"
  printf 'wg-easy admin password: %s\n' "$WG_INIT_PASSWORD"
fi
printf 'SAVE THESE SECRETS IN A PASSWORD MANAGER NOW.\n'
printf '============================================================\n\n'

warn "Inbound firewall is not modified. Allow 443/tcp for Kornode; for wireguard-upstream also allow ${WG_VPN_PORT:-443}/udp. Keep panel ports closed externally."
if [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
  warn "Let's Encrypt requires public DNS and inbound 80/tcp for issuance and renewal."
fi
