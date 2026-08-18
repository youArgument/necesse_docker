```bash
#!/usr/bin/env bash
# olcRTC Installer v1.0.0 — corrected machine IP detection.
#
# Основные исправления:
#   - IP машины определяется локально через `ip route get`
#   - нет зависимости от api.ipify.org
#   - IP записывается в OLCRTC_ADMIN_DOMAIN
#   - IP + порт записываются в OLCRTC_SUB_PUBLIC_URL
#   - повторный запуск также использует локально определённый IP
#
# Usage:
#   curl -fsSL .../olcrtc-setup.sh | sudo bash
#   sudo bash olcrtc-setup.sh --update
#   sudo bash olcrtc-setup.sh --uninstall
#   sudo bash olcrtc-setup.sh --show-token
#   sudo bash olcrtc-setup.sh --status

set -euo pipefail

INSTALLER_VERSION="1.9.64"

CARRIER_DEFAULT="jitsi"
TRANSPORT_DEFAULT="vp8channel"
DNS_DEFAULT="8.8.8.8:53"

CONFIG_DIR="/etc/olcrtc"
STATE_DIR="/var/lib/olcrtc"

ADMIN_ENV="$CONFIG_DIR/admin.env"
ENV_FILE="$CONFIG_DIR/env"
KEY_FILE="$CONFIG_DIR/key.hex"

# ── Flags ─────────────────────────────────────────────────────────────────────

DO_UPDATE=0
DO_UNINSTALL=0
DO_SHOW_TOKEN=0
DO_REGENERATE=0
DO_REGENERATE_KEY=0
DO_STATUS=0

CARRIER=""
TRANSPORT=""
SET_NAME=""
SET_ID=""

# ── Helpers ────────────────────────────────────────────────────────────────────

tty_read() {
    if [ -t 0 ]; then
        read "$@"
    else
        read "$@" < /dev/tty
    fi
}

get_env_value() {
    local key="$1"
    local file="${2:-$ENV_FILE}"

    grep -E "^${key}=" "$file" 2>/dev/null \
        | tail -1 \
        | cut -d= -f2- || true
}

set_env_value() {
    local key="$1"
    local value="$2"
    local file="${3:-$ENV_FILE}"

    if [ ! -f "$file" ]; then
        install -d -m 0750 "$(dirname "$file")"
        echo "${key}=${value}" > "$file"
        return
    fi

    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"

        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "${key}="*)
                    echo "${key}=${value}"
                    ;;
                *)
                    echo "$line"
                    ;;
            esac
        done < "$file" > "$tmp"

        mv "$tmp" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

normalize_carrier() {
    case "$1" in
        wb_stream)
            echo "wbstream"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Определение IP самой машины
#
# Основной способ:
#
#   ip -4 route get 1.1.1.1
#
# Например:
#
#   1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.50
#
# Мы берём значение после "src":
#
#   192.168.1.50
#
# Это именно IP интерфейса машины, через который используется default route.
#
# НЕ используется внешний сервис ipify.
# ─────────────────────────────────────────────────────────────────────────────

get_machine_ip() {
    local iface
    local ip

    iface="$(
        ip -4 route show default 2>/dev/null |
        awk 'NR==1 {
            for (i=1; i<=NF; i++) {
                if ($i=="dev") {
                    print $(i+1)
                    exit
                }
            }
        }'
    )"

    if [ -n "$iface" ]; then
        ip="$(
            ip -4 addr show dev "$iface" scope global 2>/dev/null |
            awk '/inet / {
                split($2, a, "/")
                print a[1]
                exit
            }'
        )"
    fi

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s\n' "$ip"
        return 0
    fi

    return 1
}
# ─────────────────────────────────────────────────────────────────────────────
# Download helpers
# ─────────────────────────────────────────────────────────────────────────────

detect_arch() {
    local arch
    arch="$(uname -m)"

    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "unsupported:$arch"
            ;;
    esac
}

download_release() {
    local name="$1"
    local dest="$2"

    local repo="Oleglog/Olcrtc_manager"
    local tag="server-v${INSTALLER_VERSION}"
    local url="https://github.com/${repo}/releases/download/${tag}/${name}"

    # Refuse Windows binaries on Linux installs.
    if [[ "$name" == *.exe ]] ||
       [[ "$name" == *-windows-* ]]; then

        echo "[!] Refusing to download Windows binary on Linux: $name" >&2
        return 1
    fi

    if [ -f "$dest" ]; then
        rm -f "$dest"
    fi

    if curl -fsSL --max-time 30 "$url" -o "$dest.tmp"; then

        # Verify downloaded file is Linux ELF.
        if command -v file >/dev/null 2>&1; then
            local ftype
            ftype="$(file -b "$dest.tmp")"

            case "$ftype" in
                ELF*)
                    ;;
                *)
                    echo "[!] Downloaded file is not a Linux binary (type: $ftype): $name" >&2
                    rm -f "$dest.tmp"
                    return 1
                    ;;
            esac
        fi

        # File must not be empty / tiny.
        local size
        size="$(
            stat -c%s "$dest.tmp" 2>/dev/null ||
            stat -f%z "$dest.tmp" 2>/dev/null ||
            echo 0
        )"

        if [ "$size" -lt 1024 ]; then
            echo "[!] Downloaded file is too small ($size bytes): $name" >&2
            rm -f "$dest.tmp"
            return 1
        fi

        mv "$dest.tmp" "$dest"
        chmod +x "$dest"

        return 0
    fi

    rm -f "$dest.tmp"

    return 1
}

# ── Uninstall ─────────────────────────────────────────────────────────────────

do_uninstall() {

    if [ -x /usr/local/lib/olcrtc/wb-automation/uninstall.sh ]; then
        echo "[*] Removing WB browser automation..."
        bash /usr/local/lib/olcrtc/wb-automation/uninstall.sh || true
    fi

    echo "[*] Stopping services..."

    systemctl stop olcrtc-server.service 2>/dev/null || true
    systemctl stop olcrtc-admin.service 2>/dev/null || true

    echo "[*] Disabling services..."

    systemctl disable olcrtc-server.service 2>/dev/null || true
    systemctl disable olcrtc-admin.service 2>/dev/null || true

    echo "[*] Removing systemd units..."

    rm -f /etc/systemd/system/olcrtc-server.service
    rm -f /etc/systemd/system/olcrtc-server@.service
    rm -f /etc/systemd/system/olcrtc-admin.service

    systemctl daemon-reload

    echo "[*] Removing binaries..."

    rm -f /usr/local/bin/olcrtc
    rm -f /usr/local/bin/olcrtc-admin
    rm -f /usr/local/bin/olcrtc-launcher

    echo "[*] Removing config..."

    rm -rf "$CONFIG_DIR"
    rm -rf "$STATE_DIR"
    rm -rf /var/lib/olcrtc/admin-tls

    echo "[*] olcRTC полностью удалён."
}

# ── Update ────────────────────────────────────────────────────────────────────

do_update() {

    echo "[*] Updating binaries..."

    local arch
    arch="$(detect_arch)"

    if [[ "$arch" == unsupported* ]]; then
        echo "[!] Unsupported architecture: $arch" >&2
        exit 1
    fi

    echo "    Detected architecture: $arch"

    local tmpdir
    tmpdir="$(mktemp -d)"

    if download_release \
        "olcrtc-linux-${arch}" \
        "$tmpdir/olcrtc"; then

        install -m 0755 "$tmpdir/olcrtc" /usr/local/bin/olcrtc
        echo "  olcrtc updated"
    else
        echo "[!] Failed to download olcrtc binary" >&2
    fi

    if download_release \
        "olcrtc-admin-linux-${arch}" \
        "$tmpdir/olcrtc-admin"; then

        install -m 0755 "$tmpdir/olcrtc-admin" /usr/local/bin/olcrtc-admin
        echo "  olcrtc-admin updated"
    else
        echo "[!] Failed to download olcrtc-admin binary" >&2
    fi

    # Update launcher.
    SCRIPT_DIR=""

    if [ -n "${BASH_SOURCE:-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    LAUNCHER_SRC=""

    [ -n "$SCRIPT_DIR" ] &&
        LAUNCHER_SRC="$SCRIPT_DIR/systemd/olcrtc-launcher"

    if [ -n "$LAUNCHER_SRC" ] &&
       [ -f "$LAUNCHER_SRC" ]; then

        install -m 0755 \
            "$LAUNCHER_SRC" \
            /usr/local/bin/olcrtc-launcher

        echo "  olcrtc-launcher updated"
    else
        echo "[!] Launcher source not found, skipping launcher update" >&2
    fi

    rm -rf "$tmpdir"

    systemctl daemon-reload

    systemctl restart olcrtc-server.service 2>/dev/null || true
    systemctl restart olcrtc-admin.service 2>/dev/null || true

    echo "[*] Update complete."
}

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: sudo ./olcrtc-setup.sh [options]

Options:

    --carrier <jitsi|telemost|wbstream>
        Carrier (default: $CARRIER_DEFAULT)

    --transport <datachannel|vp8channel|seichannel>
        Transport (default: $TRANSPORT_DEFAULT)

    --name <string>
        Connection name

    --id <room_id>
        Room ID

    --regenerate
        Regenerate Room ID

    --regenerate-key
        Regenerate key + Room ID

    --update
        Update binaries

    --uninstall
        Full uninstall

    --show-token
        Show admin credentials

    --status
        Show service status

    -h, --help
        Show this help
EOF
}

while [ $# -gt 0 ]; do

    case "$1" in

        --carrier)
            CARRIER="$(normalize_carrier "$2")"
            shift 2
            ;;

        --carrier=*)
            CARRIER="$(normalize_carrier "${1#*=}")"
            shift
            ;;

        --transport)
            TRANSPORT="$2"
            shift 2
            ;;

        --transport=*)
            TRANSPORT="${1#*=}"
            shift
            ;;

        --name)
            SET_NAME="$2"
            shift 2
            ;;

        --name=*)
            SET_NAME="${1#*=}"
            shift
            ;;

        --id)
            SET_ID="$2"
            shift 2
            ;;

        --id=*)
            SET_ID="${1#*=}"
            shift
            ;;

        --regenerate)
            DO_REGENERATE=1
            shift
            ;;

        --regenerate-key)
            DO_REGENERATE_KEY=1
            DO_REGENERATE=1
            shift
            ;;

        --update)
            DO_UPDATE=1
            shift
            ;;

        --uninstall)
            DO_UNINSTALL=1
            shift
            ;;

        --show-token)
            DO_SHOW_TOKEN=1
            shift
            ;;

        --status)
            DO_STATUS=1
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;

    esac

done

# ── Root check ────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "[!] Must run as root (try: sudo $0)" >&2
    exit 1
fi

# ── systemd check ────────────────────────────────────────────────────────────

if ! command -v systemctl >/dev/null 2>&1; then
    echo "[!] systemd required" >&2
    exit 1
fi

# ── Simple actions ───────────────────────────────────────────────────────────

if [ "$DO_UNINSTALL" -eq 1 ]; then
    do_uninstall
    exit 0
fi

if [ "$DO_UPDATE" -eq 1 ]; then
    do_update
    exit 0
fi

if [ "$DO_SHOW_TOKEN" -eq 1 ]; then

    if [ -f "$ADMIN_ENV" ]; then

        echo "Логин: $(grep '^OLCRTC_ADMIN_USER=' "$ADMIN_ENV" | cut -d= -f2-)"
        echo "Пароль: $(grep '^OLCRTC_ADMIN_PASS=' "$ADMIN_ENV" | cut -d= -f2-)"

    else

        echo "[!] Admin env not found" >&2
        exit 1

    fi

    exit 0
fi

if [ "$DO_STATUS" -eq 1 ]; then

    systemctl status olcrtc-server.service --no-pager 2>/dev/null || true
    systemctl status olcrtc-admin.service --no-pager 2>/dev/null || true

    exit 0
fi

# ── Detect machine IP ───────────────────────────────────────────────────────

MACHINE_IP="$(get_machine_ip)"

echo ""
echo "  Detected machine IP: ${MACHINE_IP}"
echo ""

if [ "$MACHINE_IP" = "unknown" ]; then
    echo "[!] Не удалось определить IP машины." >&2
    echo "    Проверьте наличие iproute2/hostname." >&2
    exit 1
fi

# ── Re-run on already-installed system ──────────────────────────────────────

is_installed() {
    [ -f /usr/local/bin/olcrtc ] &&
    [ -f /etc/systemd/system/olcrtc-server.service ] &&
    [ -f "$ENV_FILE" ]
}

if is_installed; then

    echo "  olcRTC уже установлен."
    echo ""

    ADMIN_PORT="$(
        get_env_value \
            OLCRTC_ADMIN_PORT \
            "$ADMIN_ENV" 2>/dev/null ||
        echo "8443"
    )"

    echo "  Machine IP: ${MACHINE_IP}"
    echo "  Admin UI:   https://${MACHINE_IP}:${ADMIN_PORT}"

    systemctl is-active olcrtc-server.service >/dev/null 2>&1 &&
        echo "  olcrtc-server: running" ||
        echo "  olcrtc-server: not running"

    systemctl is-active olcrtc-admin.service >/dev/null 2>&1 &&
        echo "  olcrtc-admin:  running" ||
        echo "  olcrtc-admin:  not running"

    echo ""
    echo "  Дополнительные действия:"
    echo "    --update          Обновить бинарники"
    echo "    --regenerate      Пересоздать Room ID"
    echo "    --regenerate-key  Пересоздать ключ + Room ID"
    echo "    --uninstall       Полное удаление"
    echo "    --show-token      Показать токен"
    echo ""

    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# Fresh installation
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║  olcRTC Installer v${INSTALLER_VERSION}   ║"
echo "  ╚═══════════════════════════════════════════╝"
echo ""

ARCH="$(detect_arch)"

if [[ "$ARCH" == unsupported* ]]; then
    echo "[!] Unsupported architecture: ${ARCH#unsupported:}" >&2
    exit 1
fi

echo "    Architecture: $ARCH"
echo "    Machine IP:   $MACHINE_IP"

# ── 1. Check system ──────────────────────────────────────────────────────────

echo "  [1/7] Проверка системы..."

for pkg in curl systemctl; do

    if ! command -v "$pkg" >/dev/null 2>&1; then
        echo "  [!] Missing: $pkg" >&2
        exit 1
    fi

done

echo "              ✓"

# ── 2. Download olcrtc ───────────────────────────────────────────────────────

echo "  [2/7] Скачивание olcrtc binary..."

TMPDIR="$(mktemp -d)"

if ! download_release \
    "olcrtc-linux-${ARCH}" \
    "$TMPDIR/olcrtc"; then

    echo "  [!] Не удалось скачать olcrtc binary." >&2
    rm -rf "$TMPDIR"
    exit 1
fi

echo "              ✓"

# ── 3. Download olcrtc-admin ────────────────────────────────────────────────

echo "  [3/7] Скачивание olcrtc-admin..."

if ! download_release \
    "olcrtc-admin-linux-${ARCH}" \
    "$TMPDIR/olcrtc-admin"; then

    echo "  [!] Не удалось скачать olcrtc-admin." >&2
    echo "      Установка olcrtc-admin пропущена." >&2

    touch "$TMPDIR/olcrtc-admin-missing"
fi

echo "              ✓"

# ── 4. Interactive config ───────────────────────────────────────────────────

echo "  [4/7] Настройка:"
echo ""

echo "        Доступные carrier:"
echo "          wbstream  — Wildberries Stream"
echo "          jitsi     — Jitsi Meet"
echo "          telemost  — Yandex Telemost"

if [ -z "$CARRIER" ]; then

    tty_read -rp \
        "        Carrier [wbstream]: " \
        CARRIER

    CARRIER="${CARRIER:-wbstream}"

fi

CARRIER="$(normalize_carrier "$CARRIER")"

echo ""

echo "        Доступные transport:"
echo "          vp8channel   — универсальный"
echo "          datachannel  — быстрый"
echo "          seichannel   — для wbstream/jitsi"

if [ -z "$TRANSPORT" ]; then

    tty_read -rp \
        "        Transport [vp8channel]: " \
        TRANSPORT

    TRANSPORT="${TRANSPORT:-vp8channel}"

fi

echo ""

echo "        Подписки — публичные ссылки."
echo "        URL: https://${MACHINE_IP}:PORT/sub/XXXXXX"

SUB_ENABLED=""

while [ "$SUB_ENABLED" != "y" ] &&
      [ "$SUB_ENABLED" != "n" ] &&
      [ "$SUB_ENABLED" != "Y" ] &&
      [ "$SUB_ENABLED" != "N" ]; do

    tty_read -rp \
        "        Подписки [Y/n]: " \
        SUB_ENABLED

    SUB_ENABLED="${SUB_ENABLED:-y}"

done

echo ""

if [ -z "$SET_NAME" ]; then

    DEFAULT_NAME="${CARRIER}_olcrtc"

    tty_read -rp \
        "        Имя инстанса [${DEFAULT_NAME}]: " \
        SET_NAME

    SET_NAME="${SET_NAME:-$DEFAULT_NAME}"

fi

# ── 5. Install binaries ──────────────────────────────────────────────────────

echo "  [5/7] Установка бинарников..."

install \
    -m 0755 \
    -o root \
    -g root \
    "$TMPDIR/olcrtc" \
    /usr/local/bin/olcrtc

if [ ! -f "$TMPDIR/olcrtc-admin-missing" ]; then

    install \
        -m 0755 \
        -o root \
        -g root \
        "$TMPDIR/olcrtc-admin" \
        /usr/local/bin/olcrtc-admin

fi

# ── Launcher ─────────────────────────────────────────────────────────────────

SCRIPT_DIR=""

if [ -n "${BASH_SOURCE:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

LAUNCHER_SRC=""

[ -n "$SCRIPT_DIR" ] &&
    LAUNCHER_SRC="$SCRIPT_DIR/systemd/olcrtc-launcher"

if [ -n "$LAUNCHER_SRC" ] &&
   [ -f "$LAUNCHER_SRC" ]; then

    install \
        -m 0755 \
        -o root \
        -g root \
        "$LAUNCHER_SRC" \
        /usr/local/bin/olcrtc-launcher

else

    cat > /usr/local/bin/olcrtc-launcher <<'LAUNCHER_EOF'
#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="./config.yaml"

carrier="${OLCRTC_CARRIER:-${OLCRTC_PROVIDER:-}}"

[ "$carrier" = "wb_stream" ] &&
    carrier="wbstream"

if [ -z "$carrier" ] ||
   [ -z "${OLCRTC_ROOM_ID:-}" ] ||
   [ -z "${OLCRTC_KEY:-}" ]; then

    echo "olcrtc-launcher: missing required env" >&2
    exit 64

fi

room_id="$OLCRTC_ROOM_ID"

case "$carrier" in

    jazz|salutejazz|jitsi)

        if [ -n "${OLCRTC_ROOM_PASSWORD:-}" ] &&
           [[ "$room_id" != *:* ]] &&
           [ "$room_id" != "any" ] &&
           [ "$room_id" != "dummy" ]; then

            room_id="${room_id}:${OLCRTC_ROOM_PASSWORD}"

        fi

        ;;

esac

transport="${OLCRTC_TRANSPORT:-vp8channel}"
link="${OLCRTC_LINK:-direct}"
dns="${OLCRTC_DNS:-8.8.8.8:53}"

debug="false"

if [ -n "${OLCRTC_DEBUG:-}" ] &&
   [ "$OLCRTC_DEBUG" != "0" ] &&
   [ "$OLCRTC_DEBUG" != "false" ]; then

    debug="true"

fi

cat > "$CONFIG_FILE" <<EOF
mode: srv
link: ${link}
auth:
  provider: ${carrier}
room:
  id: "${room_id}"
crypto:
  key: "${OLCRTC_KEY}"
net:
  transport: ${transport}
  dns: "${dns}"
data: data
debug: ${debug}
ffmpeg: ffmpeg
EOF

if [ -n "${OLCRTC_SOCKS_PROXY:-}" ]; then

    proxy="$OLCRTC_SOCKS_PROXY"

    proxy="${proxy#socks5://}"
    proxy="${proxy#socks5h://}"

    proxy_user=""
    proxy_pass=""

    if [[ "$proxy" == *"@"* ]]; then

        creds="${proxy%@*}"
        proxy="${proxy##*@}"

        if [[ "$creds" == *":"* ]]; then
            proxy_user="${creds%%:*}"
            proxy_pass="${creds#*:}"
        else
            proxy_user="$creds"
        fi

    fi

    proxy_host="${proxy%:*}"
    proxy_port="${proxy##*:}"

    cat >> "$CONFIG_FILE" <<EOF
socks:
  host: ""
  port: 0
  proxy_addr: "${proxy_host}"
  proxy_port: ${proxy_port}
EOF

    [ -n "$proxy_user" ] &&
        echo "  proxy_user: \"${proxy_user}\"" >> "$CONFIG_FILE"

    [ -n "$proxy_pass" ] &&
        echo "  proxy_pass: \"${proxy_pass}\"" >> "$CONFIG_FILE"

else

    cat >> "$CONFIG_FILE" <<EOF
socks:
  host: ""
  port: 0
EOF

fi

if [ -n "${OLCRTC_WARP_PROXY:-}" ]; then

    warp="$OLCRTC_WARP_PROXY"

    warp_host="${warp%:*}"
    warp_port="${warp##*:}"

    cat >> "$CONFIG_FILE" <<EOF
warp:
  proxy_addr: "${warp_host}"
  proxy_port: ${warp_port}
EOF

else

    cat >> "$CONFIG_FILE" <<EOF
warp:
  proxy_addr: ""
  proxy_port: 0
EOF

fi

sub_enabled="false"

if [ -n "${OLCRTC_SUB_ENABLED:-}" ] &&
   [ "$OLCRTC_SUB_ENABLED" != "0" ] &&
   [ "$OLCRTC_SUB_ENABLED" != "false" ]; then

    sub_enabled="true"

fi

sub_port="${OLCRTC_SUB_PORT:-2096}"
sub_db="${OLCRTC_SUB_DB:-/var/lib/olcrtc/subscriptions.db}"
sub_token="${OLCRTC_SUB_API_TOKEN:-}"

cat >> "$CONFIG_FILE" <<EOF
subscription:
  enabled: ${sub_enabled}
  port: ${sub_port}
  db_path: "${sub_db}"
  api_token: "${sub_token}"
EOF

vp8_fps="${OLCRTC_VP8_FPS:-120}"
vp8_batch="${OLCRTC_VP8_BATCH:-64}"

if [ "$transport" = "vp8channel" ]; then

    cat >> "$CONFIG_FILE" <<EOF
vp8:
  fps: ${vp8_fps}
  batch_size: ${vp8_batch}
EOF

fi

if [ "$transport" = "seichannel" ]; then

    sei_fps="${OLCRTC_SEI_FPS:-30}"
    sei_batch="${OLCRTC_SEI_BATCH:-10}"
    sei_frag="${OLCRTC_SEI_FRAG:-1200}"
    sei_ack="${OLCRTC_SEI_ACK:-500}"

    cat >> "$CONFIG_FILE" <<EOF
sei:
  fps: ${sei_fps}
  batch_size: ${sei_batch}
  fragment_size: ${sei_frag}
  ack_timeout_ms: ${sei_ack}
EOF

fi

if [ "$transport" = "videochannel" ]; then

    cat >> "$CONFIG_FILE" <<EOF
video:
  width: 1920
  height: 1080
  fps: 30
  bitrate: "2M"
  hw: none
  codec: qrcode
EOF

fi

exec /usr/local/bin/olcrtc "$CONFIG_FILE"

LAUNCHER_EOF

    chmod +x /usr/local/bin/olcrtc-launcher

fi

rm -rf "$TMPDIR"

echo "              ✓"

# ── 6. Generate keys/env/admin.env ──────────────────────────────────────────

echo "  [6/7] Генерация ключей и конфигурации..."

# Create user.

if ! id olcrtc >/dev/null 2>&1; then

    useradd \
        --system \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --home-dir "$STATE_DIR" \
        olcrtc

fi

install \
    -d \
    -m 0750 \
    -o root \
    -g olcrtc \
    "$CONFIG_DIR"

install \
    -d \
    -m 0750 \
    -o olcrtc \
    -g olcrtc \
    "$STATE_DIR"

install \
    -d \
    -m 0750 \
    -o root \
    -g root \
    /var/lib/olcrtc/admin-tls

# Encryption key.

if [ "$DO_REGENERATE_KEY" -eq 1 ] ||
   [ ! -s "$KEY_FILE" ]; then

    openssl rand -hex 32 > "$KEY_FILE"

    chown root:olcrtc "$KEY_FILE"
    chmod 0640 "$KEY_FILE"

fi

KEY="$(cat "$KEY_FILE")"

# ── Room ID ──────────────────────────────────────────────────────────────────

ROOM_ID=""

if [ "$DO_REGENERATE" -eq 0 ] &&
   [ -f "$ENV_FILE" ]; then

    EXISTING_ROOM="$(get_env_value OLCRTC_ROOM_ID)"

    if [ -n "$EXISTING_ROOM" ] &&
       [ "$EXISTING_ROOM" != "any" ]; then

        ROOM_ID="$EXISTING_ROOM"

    fi

fi

if [ -n "$SET_ID" ]; then
    ROOM_ID="$SET_ID"
fi

case "$CARRIER" in

    wbstream)

        while [ -z "$ROOM_ID" ] ||
              [ "$ROOM_ID" = "any" ]; do

            echo ""
            echo "        WB Stream больше не создаёт румы автоматически."
            echo "        Откройте https://stream.wb.ru"
            echo "        создайте руму и скопируйте Room ID."

            tty_read -rp \
                "        WB Stream Room ID: " \
                ROOM_ID

            ROOM_ID="$(echo "$ROOM_ID" | tr -d '[:space:]')"

        done

        ;;

    telemost)

        if [ -z "$ROOM_ID" ]; then
            ROOM_ID="olcrtc-$(openssl rand -hex 4)"
        fi

        ;;

    *)

        if [ -z "$ROOM_ID" ]; then
            ROOM_ID="any"
        fi

        ;;

esac

# ── Subscription port ───────────────────────────────────────────────────────

SUB_PORT=2096

if timeout 1 bash -c \
    "</dev/tcp/127.0.0.1/${SUB_PORT}" \
    2>/dev/null; then

    SUB_PORT=""

    for p in 2097 2099 3096 3097 3099 4096 4097; do

        if ! timeout 1 bash -c \
            "</dev/tcp/127.0.0.1/${p}" \
            2>/dev/null; then

            SUB_PORT=$p
            break

        fi

    done

    if [ -z "$SUB_PORT" ]; then

        echo "⚠ Не удалось найти свободный порт для sub-сервера." >&2

        SUB_PORT=2096

    else

        echo "  ℹ Порт 2096 занят."
        echo "    sub-сервер будет слушать :$SUB_PORT"

    fi

fi

# ── Main env ─────────────────────────────────────────────────────────────────

SUB_ENABLED_VAL=""

if [ "$SUB_ENABLED" = "y" ] ||
   [ "$SUB_ENABLED" = "Y" ]; then

    SUB_ENABLED_VAL="1"

fi

CLIENT_ID="$(
    cat /proc/sys/kernel/random/uuid 2>/dev/null ||
    openssl rand -hex 16
)"

cat > "$ENV_FILE" <<EOF
OLCRTC_CARRIER=$CARRIER
OLCRTC_TRANSPORT=$TRANSPORT
OLCRTC_ROOM_ID=$ROOM_ID
OLCRTC_ROOM_PASSWORD=
OLCRTC_KEY=$KEY
OLCRTC_CLIENT_ID=$CLIENT_ID
OLCRTC_DNS=$DNS_DEFAULT
OLCRTC_NAME=$SET_NAME
OLCRTC_JITSI_BRIDGE_MODE=auto
OLCRTC_JITSI_SCTP_MAX_MESSAGE_SIZE=
OLCRTC_TRAFFIC_MAX_PAYLOAD=
OLCRTC_TRAFFIC_MIN_DELAY=
OLCRTC_TRAFFIC_MAX_DELAY=
OLCRTC_VP8_FPS=120
OLCRTC_VP8_BATCH=64
OLCRTC_SUB_ENABLED=$SUB_ENABLED_VAL
OLCRTC_SUB_PORT=$SUB_PORT
EOF

chown root:olcrtc "$ENV_FILE"
chmod 0640 "$ENV_FILE"

# ── Admin env ────────────────────────────────────────────────────────────────

ADMIN_PORT=8443

if ! timeout 1 bash -c \
    "</dev/tcp/127.0.0.1/${ADMIN_PORT}" \
    2>/dev/null; then

    :

else

    for p in 9443 8080 3000 4443; do

        if ! timeout 1 bash -c \
            "</dev/tcp/127.0.0.1/${p}" \
            2>/dev/null; then

            ADMIN_PORT=$p
            break

        fi

    done

fi

ADMIN_USER="admin"
ADMIN_PASS="admin"

# ─────────────────────────────────────────────────────────────────────────────
# ВАЖНО:
#
# Раньше здесь было:
#
# OLCRTC_ADMIN_DOMAIN=
# OLCRTC_SUB_PUBLIC_URL=
#
# Теперь IP машины записывается явно.
# ─────────────────────────────────────────────────────────────────────────────

OLCRTC_ADMIN_DOMAIN="$MACHINE_IP"

OLCRTC_SUB_PUBLIC_URL="https://${MACHINE_IP}:${SUB_PORT}"

cat > "$ADMIN_ENV" <<EOF
OLCRTC_ADMIN_PORT=${ADMIN_PORT}
OLCRTC_ADMIN_USER=${ADMIN_USER}
OLCRTC_ADMIN_PASS=${ADMIN_PASS}
OLCRTC_ADMIN_DOMAIN=${OLCRTC_ADMIN_DOMAIN}
OLCRTC_SUB_PORT=${SUB_PORT}
OLCRTC_SUB_PUBLIC_URL=${OLCRTC_SUB_PUBLIC_URL}
EOF

chmod 0600 "$ADMIN_ENV"

# ── 7. Systemd units ─────────────────────────────────────────────────────────

echo "  [7/7] Создание systemd-юнитов..."

cat > /etc/systemd/system/olcrtc-server.service <<'UNIT'
[Unit]
Description=olcRTC server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=exec

EnvironmentFile=/etc/olcrtc/env

User=olcrtc
Group=olcrtc

StateDirectory=olcrtc
StateDirectoryMode=0750

RuntimeDirectory=olcrtc
RuntimeDirectoryMode=0750

Environment=OLCRTC_STATUS_FILE=/run/olcrtc/status.json

WorkingDirectory=/var/lib/olcrtc

ExecStart=/usr/local/bin/olcrtc-launcher

ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

NoNewPrivileges=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
RestrictRealtime=true

RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

SystemCallArchitectures=native

ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true

Restart=on-failure
RestartSec=5s

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/olcrtc-server@.service <<'UNIT'
[Unit]
Description=olcRTC server instance %i
After=network-online.target
Wants=network-online.target

StartLimitIntervalSec=300
StartLimitBurst=10

[Service]

Type=exec

EnvironmentFile=/etc/olcrtc/%i/env

User=olcrtc
Group=olcrtc

StateDirectory=olcrtc-%i
StateDirectoryMode=0750

RuntimeDirectory=olcrtc-%i
RuntimeDirectoryMode=0750

Environment=OLCRTC_STATUS_FILE=/run/olcrtc-%i/status.json

WorkingDirectory=/var/lib/olcrtc-%i

ExecStart=/usr/local/bin/olcrtc-launcher

ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

NoNewPrivileges=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
RestrictRealtime=true

RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

SystemCallArchitectures=native

ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true

Restart=on-failure
RestartSec=5s

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/olcrtc-admin.service <<'UNIT'
[Unit]
Description=olcRTC Admin Web UI
After=network-online.target olcrtc-server.service
Wants=network-online.target

[Service]

Type=simple

EnvironmentFile=/etc/olcrtc/admin.env

ExecStart=/usr/local/bin/olcrtc-admin \
    -port ${OLCRTC_ADMIN_PORT} \
    -domain "${OLCRTC_ADMIN_DOMAIN}" \
    -sub-port ${OLCRTC_SUB_PORT} \
    -sub-public-url "${OLCRTC_SUB_PUBLIC_URL}" \
    -tls-dir /var/lib/olcrtc/admin-tls

Restart=on-failure
RestartSec=5

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

systemctl enable --quiet olcrtc-server.service
systemctl enable --quiet olcrtc-admin.service 2>/dev/null || true

systemctl restart olcrtc-server.service

# ── Wait for Room ID ─────────────────────────────────────────────────────────

if [ "$ROOM_ID" = "any" ]; then

    echo "  [*] Waiting for carrier to create room..."

    DETECTED=""

    for i in $(seq 1 30); do

        sleep 1

        DETECTED="$(
            journalctl \
                -u olcrtc-server.service \
                --since '1 minute ago' \
                --no-pager 2>/dev/null |
            grep -oE 'Jazz room created: \S+' |
            tail -1 |
            awk '{print $NF}'
        )" || true

        [ -n "$DETECTED" ] &&
            break

    done

    if [ -n "$DETECTED" ]; then

        set_env_value \
            "OLCRTC_ROOM_ID" \
            "$DETECTED" \
            "$ENV_FILE"

        systemctl restart olcrtc-server.service

        ROOM_ID="$DETECTED"

        sleep 2

    fi

fi

systemctl start olcrtc-admin.service 2>/dev/null || true

# ── Final IP detection ──────────────────────────────────────────────────────
#
# Получаем IP ещё раз после запуска сервисов.
# Это полезно, если интерфейс/маршрут поднялся во время установки.
# ─────────────────────────────────────────────────────────────────────────────

MACHINE_IP="$(get_machine_ip)"

if [ "$MACHINE_IP" = "unknown" ]; then
    MACHINE_IP="$OLCRTC_ADMIN_DOMAIN"
fi

# Если IP изменился во время установки — обновляем admin.env.

if [ "$MACHINE_IP" != "$OLCRTC_ADMIN_DOMAIN" ] &&
   [ "$MACHINE_IP" != "unknown" ]; then

    OLCRTC_ADMIN_DOMAIN="$MACHINE_IP"
    OLCRTC_SUB_PUBLIC_URL="https://${MACHINE_IP}:${SUB_PORT}"

    cat > "$ADMIN_ENV" <<EOF
OLCRTC_ADMIN_PORT=${ADMIN_PORT}
OLCRTC_ADMIN_USER=${ADMIN_USER}
OLCRTC_ADMIN_PASS=${ADMIN_PASS}
OLCRTC_ADMIN_DOMAIN=${OLCRTC_ADMIN_DOMAIN}
OLCRTC_SUB_PORT=${SUB_PORT}
OLCRTC_SUB_PUBLIC_URL=${OLCRTC_SUB_PUBLIC_URL}
EOF

    chmod 0600 "$ADMIN_ENV"

    systemctl restart olcrtc-admin.service 2>/dev/null || true
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "  ═══════════════════════════════════════════"
echo "  Установка завершена!"
echo "  ═══════════════════════════════════════════"
echo ""

echo "  Machine IP:  ${MACHINE_IP}"
echo "  Admin UI:    https://${MACHINE_IP}:${ADMIN_PORT}"
echo "  Sub URL:     ${OLCRTC_SUB_PUBLIC_URL}"

echo ""
echo "  Логин:       ${ADMIN_USER}"
echo "  Пароль:      ${ADMIN_PASS}"

echo ""
echo "  ⚠  Сертификат самоподписанный."
echo "     В браузере нажмите 'Дополнительно' → 'Перейти'."

echo ""
echo "  ═══════════════════════════════════════════"
echo ""
```
