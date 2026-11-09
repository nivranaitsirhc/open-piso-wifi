#!/bin/bash
# ==============================================================================
# 🚀 OpenPisoWiFi - Linux SBC Standalone Gateway Setup (Profile 2)
# ==============================================================================
# Turns a Linux SBC into a universal router & captive portal gateway.
# - The built-in Ethernet is preferred as WAN (ISP modem/ONT via DHCP)
# - A USB Ethernet adapter is preferred as LAN (connected to an AP/bridge)
# - nftables: Kernel-level hardware-speed NAT, authorization sets, and captive redirect
# - dnsmasq: DHCP server (10.0.0.10 - 10.0.3.250) + captive DNS responder
#
# Usage:
#   sudo ./scripts/setup-sbc-gateway.sh               # Run standard installation
#   sudo ./scripts/setup-sbc-gateway.sh --dry-run     # Preview actions without changes
#   sudo ./scripts/setup-sbc-gateway.sh --no-wan-portal # Keep portal LAN-only
#   sudo ./scripts/setup-sbc-gateway.sh --rollback    # Remove gateway configuration
#   sudo ./scripts/setup-sbc-gateway.sh --status      # Check current gateway status
# ==============================================================================

set -eo pipefail

# ANSI Color Codes
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Default Configuration Parameters. Interface names are detected below when
# callers do not provide WAN_IFACE/LAN_IFACE explicitly.
WAN_IFACE="${WAN_IFACE:-}"
LAN_IFACE="${LAN_IFACE:-}"
LAN_IP="${LAN_IP:-}"
LAN_PREFIX="${LAN_PREFIX:-}"
LAN_NETMASK="${LAN_NETMASK:-}"
DHCP_RANGE="${DHCP_RANGE:-10.0.0.10,10.0.3.250,255.255.252.0,12h}"
PORTAL_PORT="${PORTAL_PORT:-3000}"
# Expose only portal HTTP endpoints on WAN; keep daemon API port 4000 LAN-only.
ALLOW_WAN_PORTAL="${ALLOW_WAN_PORTAL:-true}"
INSTALL_ROOT="${OPENPISOWIFI_INSTALL_DIR:-/opt/open-piso-wifi}"
DAEMON_ENV_FILE="${INSTALL_ROOT}/daemon/.env"
GATEWAY_STATE_FILE="/etc/openpiso-gateway.env"
NETWORKD_DIR="/etc/systemd/network"
NETWORKD_WAN_FILE="${NETWORKD_DIR}/10-openpiso-gateway-wan.network"
NETWORKD_LAN_FILE="${NETWORKD_DIR}/20-openpiso-gateway-lan.network"
IFUPDOWN_FILE="/etc/network/interfaces.d/openpiso-gateway"
DHCPCD_MARKER_BEGIN="# BEGIN OPENPISOWIFI GATEWAY"
DHCPCD_MARKER_END="# END OPENPISOWIFI GATEWAY"
FALLBACK_NETWORK_UNIT="/etc/systemd/system/openpiso-gateway-network.service"
DNSMASQ_DROPIN="/etc/systemd/system/dnsmasq.service.d/openpiso-gateway.conf"
NFTABLES_DROPIN="/etc/systemd/system/nftables.service.d/openpiso-gateway.conf"
NETWORK_BACKEND=""

# Reuse the last explicit gateway assignment on reruns. Command-line and
# environment values remain higher priority because they are assigned first.
if [ -f "$GATEWAY_STATE_FILE" ]; then
  state_value() { sed -n "s/^$1=//p" "$GATEWAY_STATE_FILE" | head -n1 | tr -d '\r'; }
  [ -n "$WAN_IFACE" ] || WAN_IFACE="$(state_value WAN_IFACE)"
  [ -n "$LAN_IFACE" ] || LAN_IFACE="$(state_value LAN_IFACE)"
  [ -n "$LAN_IP" ] || LAN_IP="$(state_value LAN_IP)"
  [ -n "$LAN_PREFIX" ] || LAN_PREFIX="$(state_value LAN_PREFIX)"
  [ -n "$LAN_NETMASK" ] || LAN_NETMASK="$(state_value LAN_NETMASK)"
fi

LAN_IP="${LAN_IP:-10.0.0.1}"
LAN_PREFIX="${LAN_PREFIX:-22}"
LAN_NETMASK="${LAN_NETMASK:-255.255.252.0}"

DRY_RUN=false
ROLLBACK=false
STATUS_CHECK=false

# Parse command line flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --rollback)
      ROLLBACK=true
      shift
      ;;
    --status)
      STATUS_CHECK=true
      shift
      ;;
    --wan-iface)
      WAN_IFACE="$2"
      shift 2
      ;;
    --lan-iface)
      LAN_IFACE="$2"
      shift 2
      ;;
    --no-wan-portal)
      ALLOW_WAN_PORTAL=false
      shift
      ;;
    --wan-portal)
      ALLOW_WAN_PORTAL=true
      shift
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

detect_gateway_interfaces() {
  local iface_path iface device_path operstate
  local -a ethernet_ifaces=() usb_ifaces=() builtin_ifaces=()

  is_physical_ethernet() {
    local candidate="$1"
    [ "$candidate" != "lo" ] || return 1
    [ -e "/sys/class/net/$candidate/device" ] || return 1
    [ "$(cat "/sys/class/net/$candidate/type" 2>/dev/null || echo 0)" = "1" ] || return 1
    [ ! -e "/sys/class/net/$candidate/wireless" ] || return 1
    return 0
  }

  # Predictable names (end0, enP..., enx...) are normal. Inspecting the
  # resolved sysfs device path works on Armbian even when udev properties are
  # incomplete or udevadm is unavailable.
  for iface_path in /sys/class/net/*; do
    [ -e "$iface_path" ] || continue
    iface="$(basename "$iface_path")"
    is_physical_ethernet "$iface" || continue
    ethernet_ifaces+=("$iface")
    device_path="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
    if [[ "$device_path" == */usb/* ]]; then
      usb_ifaces+=("$iface")
    else
      builtin_ifaces+=("$iface")
    fi
  done

  # Sort by interface name for deterministic selection across boots.
  if [ ${#builtin_ifaces[@]} -gt 0 ]; then
    IFS=$'\n' builtin_ifaces=($(printf '%s\n' "${builtin_ifaces[@]}" | sort -V))
  fi
  if [ ${#usb_ifaces[@]} -gt 0 ]; then
    IFS=$'\n' usb_ifaces=($(printf '%s\n' "${usb_ifaces[@]}" | sort -V))
  fi
  if [ ${#ethernet_ifaces[@]} -gt 0 ]; then
    IFS=$'\n' ethernet_ifaces=($(printf '%s\n' "${ethernet_ifaces[@]}" | sort -V))
  fi

  echo -e "${CYAN}Detected physical Ethernet interfaces:${NC}"
  for iface in "${ethernet_ifaces[@]}"; do
    operstate="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)"
    device_path="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
    if [[ "$device_path" == */usb/* ]]; then
      echo -e "  • ${iface} (USB Ethernet, ${operstate})"
    else
      echo -e "  • ${iface} (built-in/PCI Ethernet, ${operstate})"
    fi
  done

  if [ -n "${WAN_IFACE}" ] && ! is_physical_ethernet "$WAN_IFACE"; then
    echo -e "${RED}❌ WAN_IFACE='${WAN_IFACE}' is not a physical Ethernet interface.${NC}" >&2
    exit 1
  fi
  if [ -n "${LAN_IFACE}" ] && ! is_physical_ethernet "$LAN_IFACE"; then
    echo -e "${RED}❌ LAN_IFACE='${LAN_IFACE}' is not a physical Ethernet interface.${NC}" >&2
    exit 1
  fi

  if [ -z "$WAN_IFACE" ]; then
    if [ ${#builtin_ifaces[@]} -gt 0 ]; then
      WAN_IFACE="${builtin_ifaces[0]}"
    elif [ ${#ethernet_ifaces[@]} -gt 0 ]; then
      WAN_IFACE="${ethernet_ifaces[0]}"
    fi
  fi
  if [ -z "$LAN_IFACE" ]; then
    if [ ${#usb_ifaces[@]} -gt 0 ]; then
      LAN_IFACE="${usb_ifaces[0]}"
    else
      for iface in "${ethernet_ifaces[@]}"; do
        [ "$iface" != "$WAN_IFACE" ] && { LAN_IFACE="$iface"; break; }
      done
    fi
  fi

  if [ -z "$WAN_IFACE" ] || [ -z "$LAN_IFACE" ] || [ "$WAN_IFACE" = "$LAN_IFACE" ]; then
    echo -e "${RED}❌ Could not detect two distinct Ethernet interfaces.${NC}" >&2
    echo -e "${YELLOW}Set WAN_IFACE and LAN_IFACE explicitly or use --wan-iface/--lan-iface.${NC}" >&2
    exit 1
  fi

  echo -e "${GREEN}Selected WAN=${WAN_IFACE}, LAN=${LAN_IFACE}.${NC}"
}

detect_gateway_interfaces

persist_daemon_gateway_config() {
  mkdir -p "$(dirname "$DAEMON_ENV_FILE")"
  touch "$DAEMON_ENV_FILE"

  set_env_value() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$DAEMON_ENV_FILE"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$DAEMON_ENV_FILE"
    else
      printf '%s=%s\n' "$key" "$value" >> "$DAEMON_ENV_FILE"
    fi
  }

  # The daemon uses ROUTER_MODE to select the local Linux gateway backend.
  # Keep the detected interfaces available to local firewall/QoS commands.
  set_env_value "ROUTER_MODE" "local_linux"
  set_env_value "ROUTER_WAN_INTERFACE" "$WAN_IFACE"
  set_env_value "ROUTER_LAN_INTERFACE" "$LAN_IFACE"
  set_env_value "WAN_IFACE" "$WAN_IFACE"
  set_env_value "LAN_IFACE" "$LAN_IFACE"
  set_env_value "LAN_IP" "$LAN_IP"
  set_env_value "LAN_PREFIX" "$LAN_PREFIX"
}

persist_gateway_state() {
  cat > "$GATEWAY_STATE_FILE" <<EOF
# OpenPisoWiFi SBC gateway network state. Managed by setup-sbc-gateway.sh.
WAN_IFACE=$WAN_IFACE
LAN_IFACE=$LAN_IFACE
LAN_IP=$LAN_IP
LAN_PREFIX=$LAN_PREFIX
LAN_NETMASK=$LAN_NETMASK
NETWORK_BACKEND=$NETWORK_BACKEND
EOF
  chmod 600 "$GATEWAY_STATE_FILE"
}

ensure_ifupdown_include() {
  mkdir -p /etc/network/interfaces.d
  if [ ! -f /etc/network/interfaces ]; then
    touch /etc/network/interfaces
  fi
  if ! grep -Eq '^[[:space:]]*(source|source-directory)[[:space:]]+/etc/network/interfaces\.d/\*' /etc/network/interfaces; then
    printf '\nsource /etc/network/interfaces.d/*\n' >> /etc/network/interfaces
  fi
}

configure_gateway_network() {
  local ip_bin
  ip_bin="$(command -v ip)"

  # Remove only configurations owned by this gateway profile before selecting
  # the active backend. This prevents stale backend files from competing after
  # a migration or a repeated setup run.
  nmcli connection delete openpiso-gateway-lan 2>/dev/null || true
  nmcli connection delete openpiso-gateway-wan 2>/dev/null || true
  rm -f "$NETWORKD_WAN_FILE" "$NETWORKD_LAN_FILE" "$FALLBACK_NETWORK_UNIT"
  rm -f "$DNSMASQ_DROPIN" "$NFTABLES_DROPIN"
  sed -i "/^${DHCPCD_MARKER_BEGIN}$/,/^${DHCPCD_MARKER_END}$/d" /etc/dhcpcd.conf 2>/dev/null || true

  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
    NETWORK_BACKEND="networkmanager"
    nmcli connection delete openpiso-gateway-lan 2>/dev/null || true
    nmcli connection delete openpiso-gateway-wan 2>/dev/null || true
    nmcli connection add type ethernet con-name openpiso-gateway-lan ifname "$LAN_IFACE" \
      ipv4.method manual ipv4.addresses "$LAN_IP/$LAN_PREFIX" ipv6.method disabled
    nmcli connection add type ethernet con-name openpiso-gateway-wan ifname "$WAN_IFACE" \
      ipv4.method auto ipv6.method auto
    nmcli connection up openpiso-gateway-lan || true
    nmcli connection up openpiso-gateway-wan || true
  elif systemctl is-active --quiet systemd-networkd || systemctl is-enabled --quiet systemd-networkd; then
    NETWORK_BACKEND="systemd-networkd"
    mkdir -p "$NETWORKD_DIR"
    cat > "$NETWORKD_WAN_FILE" <<EOF
[Match]
Name=${WAN_IFACE}

[Network]
DHCP=yes
IPv6AcceptRA=no
EOF
    cat > "$NETWORKD_LAN_FILE" <<EOF
[Match]
Name=${LAN_IFACE}

[Network]
Address=${LAN_IP}/${LAN_PREFIX}
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
    systemctl enable --now systemd-networkd
    networkctl reload 2>/dev/null || true
    networkctl reconfigure "$WAN_IFACE" 2>/dev/null || true
    networkctl reconfigure "$LAN_IFACE" 2>/dev/null || true
  elif command -v ifup >/dev/null 2>&1 && [ -f /etc/network/interfaces ]; then
    NETWORK_BACKEND="ifupdown"
    ensure_ifupdown_include
    cat > "$IFUPDOWN_FILE" <<EOF
# Managed by OpenPisoWiFi setup-sbc-gateway.sh.
auto ${WAN_IFACE}
iface ${WAN_IFACE} inet dhcp

auto ${LAN_IFACE}
iface ${LAN_IFACE} inet static
    address ${LAN_IP}
    netmask ${LAN_NETMASK}
EOF
    ifup "$WAN_IFACE" 2>/dev/null || true
    ifup "$LAN_IFACE" 2>/dev/null || true
  elif command -v dhcpcd >/dev/null 2>&1 && [ -f /etc/dhcpcd.conf ]; then
    NETWORK_BACKEND="dhcpcd"
    sed -i "/^${DHCPCD_MARKER_BEGIN}$/,/^${DHCPCD_MARKER_END}$/d" /etc/dhcpcd.conf
    cat >> /etc/dhcpcd.conf <<EOF

${DHCPCD_MARKER_BEGIN}
interface ${LAN_IFACE}
static ip_address=${LAN_IP}/${LAN_PREFIX}
${DHCPCD_MARKER_END}
EOF
    systemctl enable --now dhcpcd 2>/dev/null || systemctl restart dhcpcd 2>/dev/null || true
  else
    NETWORK_BACKEND="systemd-fallback"
    mkdir -p "$(dirname "$DNSMASQ_DROPIN")" "$(dirname "$NFTABLES_DROPIN")"
    for dropin in "$DNSMASQ_DROPIN" "$NFTABLES_DROPIN"; do
      cat > "$dropin" <<EOF
[Unit]
Requires=openpiso-gateway-network.service
After=openpiso-gateway-network.service
EOF
    done
    cat > "$FALLBACK_NETWORK_UNIT" <<EOF
[Unit]
Description=OpenPisoWiFi persistent SBC LAN configuration
Wants=network-pre.target
After=network-pre.target network.target
Before=dnsmasq.service nftables.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for attempt in {1..60}; do if ${ip_bin} link show dev ${LAN_IFACE} >/dev/null 2>&1; then ${ip_bin} link set dev ${LAN_IFACE} up && ${ip_bin} addr replace ${LAN_IP}/${LAN_PREFIX} dev ${LAN_IFACE} && ${ip_bin} -o -4 addr show dev ${LAN_IFACE} | grep -Fq " inet ${LAN_IP}/${LAN_PREFIX} " && exit 0; fi; sleep 2; done; echo "Timed out waiting for ${LAN_IFACE} to receive ${LAN_IP}/${LAN_PREFIX}" >&2; exit 1'
RemainAfterExit=yes
Restart=on-failure
RestartSec=5
TimeoutStartSec=130

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now openpiso-gateway-network.service
  fi

  persist_gateway_state
}

# ------------------------------------------------------------------------------
# STATUS CHECK
# ------------------------------------------------------------------------------
if [ "$STATUS_CHECK" = true ]; then
  echo -e "${CYAN}==============================================================${NC}"
  echo -e "${GREEN}🔍 OpenPisoWiFi - Gateway Status${NC}"
  echo -e "${CYAN}==============================================================${NC}"
  echo -e "• WAN Interface ($WAN_IFACE): $(ip -br addr show "$WAN_IFACE" 2>/dev/null || echo "NOT FOUND")"
  echo -e "• LAN Interface ($LAN_IFACE): $(ip -br addr show "$LAN_IFACE" 2>/dev/null || echo "NOT FOUND")"
  echo -e "• IP Forwarding: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")"
  echo -e "• dnsmasq Service: $(systemctl is-active dnsmasq 2>/dev/null || echo "inactive")"
  echo -e "• nftables Service: $(systemctl is-active nftables 2>/dev/null || echo "inactive")"
  if command -v nft >/dev/null 2>&1; then
    echo -e "• Active Authorized Clients: $(nft list set inet piso piso_auth 2>/dev/null | grep -c 'elements = {' || echo "0")"
  fi
  exit 0
fi

# ------------------------------------------------------------------------------
# ROOT PERMISSION CHECK
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = false ]; then
  echo -e "${RED}❌ Please run as root (sudo ./scripts/setup-sbc-gateway.sh)${NC}"
  exit 1
fi

# ------------------------------------------------------------------------------
# ROLLBACK HANDLER
# ------------------------------------------------------------------------------
if [ "$ROLLBACK" = true ]; then
  echo -e "${YELLOW}==============================================================${NC}"
  echo -e "${YELLOW}⏪ Rolling back OpenPisoWiFi Gateway configuration...${NC}"
  echo -e "${YELLOW}==============================================================${NC}"

  # Remove dnsmasq config
  rm -f /etc/dnsmasq.d/openpiso-gateway.conf
  systemctl restart dnsmasq 2>/dev/null || true

  # Remove persisted network backend configuration created by this script.
  nmcli connection delete openpiso-gateway-lan 2>/dev/null || true
  nmcli connection delete openpiso-gateway-wan 2>/dev/null || true
  sed -i "/^${DHCPCD_MARKER_BEGIN}$/,/^${DHCPCD_MARKER_END}$/d" /etc/dhcpcd.conf 2>/dev/null || true
  rm -f "$NETWORKD_WAN_FILE" "$NETWORKD_LAN_FILE" "$IFUPDOWN_FILE" "$FALLBACK_NETWORK_UNIT" "$GATEWAY_STATE_FILE"
  rm -f "$DNSMASQ_DROPIN" "$NFTABLES_DROPIN"
  rmdir "$(dirname "$DNSMASQ_DROPIN")" "$(dirname "$NFTABLES_DROPIN")" 2>/dev/null || true
  systemctl disable --now openpiso-gateway-network.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  # Remove nftables table
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet piso 2>/dev/null || true
  fi
  if [ -f /etc/nftables.conf ]; then
    sed -i '\|^include "/etc/nftables.d/openpiso-gateway.nft"$|d' /etc/nftables.conf
  fi
  rm -f /etc/nftables.d/openpiso-gateway.nft
  systemctl restart nftables 2>/dev/null || true

  # Remove sysctl
  rm -f /etc/sysctl.d/99-openpiso-gateway.conf
  sysctl -w net.ipv4.ip_forward=0 2>/dev/null || true

  echo -e "${GREEN}✅ Rollback completed. Gateway settings removed.${NC}"
  exit 0
fi

if [ "$DRY_RUN" = false ]; then
  persist_daemon_gateway_config
  echo -e "${GREEN}✅ Daemon configured for local Linux gateway mode.${NC}"
fi

echo -e "${CYAN}==============================================================${NC}"
echo -e "${GREEN}🚀 Configuring Linux SBC Gateway (Profile 2 - Universal AP)${NC}"
echo -e "${CYAN}==============================================================${NC}"
echo -e "• WAN Interface (ISP)  : ${YELLOW}${WAN_IFACE}${NC}"
echo -e "• LAN Interface (AP)   : ${YELLOW}${LAN_IFACE}${NC}"
echo -e "• Gateway Subnet       : ${YELLOW}${LAN_IP}/${LAN_PREFIX}${NC}"
echo -e "• Captive Portal Port  : ${YELLOW}:${PORTAL_PORT}${NC}"
echo -e "• WAN Portal Access    : ${YELLOW}${ALLOW_WAN_PORTAL}${NC} (HTTP 80/${PORTAL_PORT}; daemon API 4000 remains LAN-only)"
echo -e "• Dry Run Mode         : ${YELLOW}${DRY_RUN}${NC}"
echo ""

# ------------------------------------------------------------------------------
# 1. DEPENDENCY CHECKS & INSTALLATION
# ------------------------------------------------------------------------------
REQUIRED_PACKAGES=(dnsmasq nftables conntrack ethtool iproute2)
MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PACKAGES+=("$pkg")
  fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
  echo -e "${YELLOW}📦 Installing required gateway packages: ${MISSING_PACKAGES[*]}...${NC}"
  if [ "$DRY_RUN" = false ]; then
    apt-get update -y
    apt-get install -y "${MISSING_PACKAGES[@]}"
  fi
fi

# ------------------------------------------------------------------------------
# 2. SYSCTL KERNEL CONFIGURATION (IP FORWARDING)
# ------------------------------------------------------------------------------
echo -e "${CYAN}⚙️ Configuring Linux Kernel IP Routing & Sysctl...${NC}"
SYSCTL_CONF="/etc/sysctl.d/99-openpiso-gateway.conf"

if [ "$DRY_RUN" = false ]; then
  cat <<EOF > "$SYSCTL_CONF"
# OpenPisoWiFi Gateway Kernel Routing
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
EOF
  sysctl -p "$SYSCTL_CONF" >/dev/null
fi
echo -e "${GREEN}✅ IP Forwarding enabled.${NC}"

# ------------------------------------------------------------------------------
# 3. LAN INTERFACE STATIC IP CONFIGURATION
# ------------------------------------------------------------------------------
echo -e "${CYAN}🌐 Configuring LAN Interface (${LAN_IFACE} -> ${LAN_IP}/${LAN_PREFIX})...${NC}"

if [ "$DRY_RUN" = false ]; then
  configure_gateway_network
  if ! ip -o -4 addr show dev "$LAN_IFACE" 2>/dev/null | awk '{print $4}' | grep -Fxq "${LAN_IP}/${LAN_PREFIX}"; then
    echo -e "${RED}❌ LAN address ${LAN_IP}/${LAN_PREFIX} is not active on ${LAN_IFACE}.${NC}" >&2
    exit 1
  fi
fi
echo -e "${GREEN}✅ LAN interface configured.${NC}"

# ------------------------------------------------------------------------------
# 4. DNSMASQ DHCP & CAPTIVE PROBE DNS CONFIGURATION
# ------------------------------------------------------------------------------
echo -e "${CYAN}📡 Configuring dnsmasq (DHCP & Captive Portal DNS Hijacking)...${NC}"
DNSMASQ_CONF="/etc/dnsmasq.d/openpiso-gateway.conf"

if [ "$DRY_RUN" = false ]; then
  mkdir -p /etc/dnsmasq.d
  cat <<EOF > "$DNSMASQ_CONF"
# ==============================================================================
# OpenPisoWiFi Standalone Gateway DHCP & DNS
# ==============================================================================
interface=${LAN_IFACE}
bind-dynamic
domain-needed
bogus-priv

# DHCP IP Pool (10.0.0.10 -> 10.0.3.250)
dhcp-range=${DHCP_RANGE}
dhcp-option=option:router,${LAN_IP}
dhcp-option=option:dns-server,${LAN_IP}

# Piso-WiFi Local Shortcut & Captive Probes
address=/wifi.local/${LAN_IP}
address=/piso.wifi/${LAN_IP}

# Android / Google Captive Portal Detection
address=/connectivitycheck.gstatic.com/${LAN_IP}
address=/connectivitycheck.android.com/${LAN_IP}
address=/clients3.google.com/${LAN_IP}

# Apple iOS / macOS Captive Portal Detection
address=/captive.apple.com/${LAN_IP}
address=/www.airport.us/${LAN_IP}

# Windows / Microsoft Captive Portal Detection
address=/www.msftconnecttest.com/${LAN_IP}
address=/ipv6.msftconnecttest.com/${LAN_IP}

# Upstream Public DNS Fallback
no-resolv
server=1.1.1.1
server=8.8.8.8
EOF

  systemctl restart dnsmasq
  systemctl enable dnsmasq
fi
echo -e "${GREEN}✅ dnsmasq active on ${LAN_IFACE}.${NC}"

# ------------------------------------------------------------------------------
# 5. NFTABLES FIREWALL & CAPTIVE REDIRECT RULES
# ------------------------------------------------------------------------------
echo -e "${CYAN}🛡️ Applying nftables NAT & Authorization Sets...${NC}"
NFT_FILE="/etc/nftables.d/openpiso-gateway.nft"
NFTABLES_MAIN_CONF="/etc/nftables.conf"
NFTABLES_INCLUDE="include \"${NFT_FILE}\""

if [ "$DRY_RUN" = false ]; then
  mkdir -p /etc/nftables.d

    WAN_PORTAL_RULE=""
    if [ "$ALLOW_WAN_PORTAL" = true ]; then
        WAN_PORTAL_RULE="    iifname \"${WAN_IFACE}\" tcp dport { 80, ${PORTAL_PORT} } accept"
    fi

  cat <<EOF > "$NFT_FILE"
#!/usr/sbin/nft -f
# ==============================================================================
# OpenPisoWiFi inet piso firewall table
# ==============================================================================

table inet piso {
  # Authorized Client MAC Addresses with dynamic kernel timeouts
  set piso_auth {
    type ether_addr
    flags timeout
  }

  # Whitelisted Devices (Always allowed, e.g. Owner phone or admin devices)
  set piso_whitelist {
    type ether_addr
  }

  # Blacklisted Devices (Permanently blocked)
  set piso_blacklist {
    type ether_addr
  }

  # Inbound packet filtering (Services hosted on the Pi)
  chain input {
    type filter hook input priority filter; policy drop;

    # Allow established and related traffic
    ct state established,related accept

    # Allow localhost traffic
    iifname "lo" accept

    # Drop blacklisted clients immediately
    ether saddr @piso_blacklist drop

    # Allow essential network services from LAN
    iifname "${LAN_IFACE}" udp dport { 53, 67 } accept
    iifname "${LAN_IFACE}" tcp dport 53 accept

    # Allow captive portal web traffic
    iifname "${LAN_IFACE}" tcp dport { 80, ${PORTAL_PORT}, 4000 } accept

    # Optional upstream access to the portal only. The daemon API (4000)
    # remains LAN-only by design.
${WAN_PORTAL_RULE}

    # Allow SSH on management (or restrict as needed)
    tcp dport 22 accept
  }

  # Forwarded traffic filtering (Client internet access)
  chain forward {
    type filter hook forward priority filter; policy drop;

    # Allow established and related traffic
    ct state established,related accept

    # Drop blacklisted devices
    ether saddr @piso_blacklist drop

    # Allow whitelisted devices without payment
    ether saddr @piso_whitelist accept

    # Allow paid authorized customers
    iifname "${LAN_IFACE}" oifname "${WAN_IFACE}" ether saddr @piso_auth accept
  }

  # Network Address Translation (NAT) & Captive Redirection
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;

    # Skip redirection for authorized or whitelisted users
    ether saddr @piso_whitelist return
    ether saddr @piso_auth return

    # Intercept HTTP Port 80 from unauthorized clients and redirect to captive portal
    iifname "${LAN_IFACE}" tcp dport 80 redirect to :${PORTAL_PORT}
  }

  # Masquerade outbound traffic to ISP WAN
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${WAN_IFACE}" masquerade
  }
}
EOF

  # Persist the gateway rules across nftables service restarts and reboots.
  # Armbian may not include /etc/nftables.d by default, so add an explicit,
  # idempotent include to the distro's main nftables configuration.
  touch "$NFTABLES_MAIN_CONF"
  if ! grep -Fqx "$NFTABLES_INCLUDE" "$NFTABLES_MAIN_CONF"; then
    printf '\n%s\n' "$NFTABLES_INCLUDE" >> "$NFTABLES_MAIN_CONF"
  fi

  if ! nft -c -f "$NFTABLES_MAIN_CONF"; then
    echo -e "${RED}❌ nftables configuration validation failed; gateway rules were not activated.${NC}" >&2
    exit 1
  fi

  # Ensure nftables starts on system boot
  systemctl enable nftables
  systemctl restart nftables
fi
echo -e "${GREEN}✅ nftables active (Kernel sets: piso_auth, piso_whitelist, piso_blacklist).${NC}"

# ------------------------------------------------------------------------------
# 6. SUMMARY & NEXT STEPS
# ------------------------------------------------------------------------------
echo ""
echo -e "${CYAN}==============================================================${NC}"
echo -e "${GREEN}🎉 OpenPisoWiFi Standalone Gateway Setup Complete!${NC}"
echo -e "${CYAN}==============================================================${NC}"
echo -e "• WAN Interface : ${YELLOW}${WAN_IFACE}${NC} (DHCP client to ISP modem)"
echo -e "• LAN Interface : ${YELLOW}${LAN_IFACE}${NC} (Static ${LAN_IP}/${LAN_PREFIX})"
if [ "$ALLOW_WAN_PORTAL" = true ]; then
  echo -e "• WAN Portal   : ${YELLOW}http://<WAN-IP>/${NC} or ${YELLOW}http://<WAN-IP>:${PORTAL_PORT}/${NC}"
else
  echo -e "• WAN Portal   : ${YELLOW}disabled${NC} (use --wan-portal to enable)"
fi
echo -e "• Next Steps:"
echo -e "  1. Plug Ethernet from LAN (${LAN_IFACE}) into ANY Wi-Fi Access Point (set in AP/Bridge mode)."
echo -e "  2. Daemon mode and detected interfaces were saved to ${DAEMON_ENV_FILE}."
echo -e "  3. Start the OpenPisoWiFi daemon & portal (systemctl restart pisowifi-daemon pisowifi-portal)."
echo -e "${CYAN}==============================================================${NC}"
