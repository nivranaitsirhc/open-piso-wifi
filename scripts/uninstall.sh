#!/bin/bash
# ==============================================================================
# 🧹 OpenPisoWiFi - Automated Uninstallation & Cleanup Script
# ==============================================================================
# Target: ARM SBCs / Linux SBC (Armbian/Debian/Ubuntu / Debian / Ubuntu)
# Features:
#   - Safely stops, disables, and removes systemd background services
#   - Removes port 80 iptables NAT redirection rules
#   - Cleans up passwordless sudoers permissions (/etc/sudoers.d/openpisowifi)
#   - Rolls back standalone gateway configuration (dnsmasq / nftables / sysctl)
#   - Automatic pre-uninstall safety backup of database (dev.db) & configurations
#   - Optional data purge (--purge) or safe preservation (--keep-data)
#   - Optional remote OpenWrt router rules cleanup (--router)
#   - Optional network configuration rollback (--revert-network)
# ==============================================================================

set -e

# ANSI Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
NC='\033[0m'

CURRENT_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
ROOT_DIR="${OPENPISOWIFI_INSTALL_DIR:-/opt/open-piso-wifi}"

PORTAL_DIR="$ROOT_DIR/portal"
[ ! -d "$PORTAL_DIR" ] && [ -d "$ROOT_DIR/pisowifi-portal" ] && PORTAL_DIR="$ROOT_DIR/pisowifi-portal"
DAEMON_DIR="$ROOT_DIR/daemon"
[ ! -d "$DAEMON_DIR" ] && [ -d "$ROOT_DIR/pisowifi-daemon" ] && DAEMON_DIR="$ROOT_DIR/pisowifi-daemon"

# CLI Options
NON_INTERACTIVE=false
PURGE_DATA=false
KEEP_DATA=false
CLEAN_ROUTER=false
CLEAN_GATEWAY=false
REVERT_NETWORK=false
CREATE_BACKUP=true

CLI_ROUTER_IP=""
CLI_ROUTER_USER=""
CLI_ROUTER_PORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y|--non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --purge)
            PURGE_DATA=true
            KEEP_DATA=false
            shift
            ;;
        --keep-data)
            KEEP_DATA=true
            PURGE_DATA=false
            shift
            ;;
        --no-backup)
            CREATE_BACKUP=false
            shift
            ;;
        --router)
            CLEAN_ROUTER=true
            shift
            ;;
        --router-ip=*)
            CLI_ROUTER_IP="${1#*=}"
            shift
            ;;
        --router-ip)
            CLI_ROUTER_IP="$2"
            shift 2
            ;;
        --router-user=*)
            CLI_ROUTER_USER="${1#*=}"
            shift
            ;;
        --router-user)
            CLI_ROUTER_USER="$2"
            shift 2
            ;;
        --router-port=*)
            CLI_ROUTER_PORT="${1#*=}"
            shift
            ;;
        --router-port)
            CLI_ROUTER_PORT="$2"
            shift 2
            ;;
        --gateway)
            CLEAN_GATEWAY=true
            shift
            ;;
        --revert-network)
            REVERT_NETWORK=true
            shift
            ;;
        --help|-h)
            echo "Usage: sudo bash scripts/uninstall.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -y, --yes, --non-interactive  Run without interactive confirmation"
            echo "  --keep-data                   Keep SQLite database and .env configuration files (Default)"
            echo "  --purge                       Permanently delete SQLite database (dev.db) and .env files"
            echo "  --no-backup                   Skip creating safety backup before uninstallation"
            echo "  --router                      Also remove OpenPisoWiFi firewall/DNS rules on OpenWrt router"
            echo "  --router-ip=IP                OpenWrt router IP address (default from .env or 192.168.1.1)"
            echo "  --router-user=USER            OpenWrt SSH user (default from .env or root)"
            echo "  --router-port=PORT            OpenWrt SSH port (default from .env or 22)"
            echo "  --gateway                     Also remove standalone Linux SBC gateway settings"
            echo "  --revert-network              Revert static IP in /etc/dhcpcd.conf / NetworkManager to DHCP"
            echo "  -h, --help                    Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Run 'bash scripts/uninstall.sh --help' for available options."
            exit 1
            ;;
    esac
done

# Read router and portal settings from .env if available
ROUTER_IP="192.168.1.1"
ROUTER_SSH_USER="root"
ROUTER_SSH_PORT="22"
PORTAL_PORT="3000"

if [ -f "$PORTAL_DIR/.env" ]; then
    VAL=$(grep -E '^ROUTER_IP=' "$PORTAL_DIR/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    [ -n "$VAL" ] && ROUTER_IP="$VAL"
    VAL=$(grep -E '^PORTAL_PORT=' "$PORTAL_DIR/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    [ -n "$VAL" ] && PORTAL_PORT="$VAL"
fi

if [ -f "$DAEMON_DIR/.env" ]; then
    VAL=$(grep -E '^ROUTER_IP=' "$DAEMON_DIR/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    [ -n "$VAL" ] && ROUTER_IP="$VAL"
    VAL=$(grep -E '^ROUTER_SSH_USER=' "$DAEMON_DIR/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    [ -n "$VAL" ] && ROUTER_SSH_USER="$VAL"
    VAL=$(grep -E '^ROUTER_SSH_PORT=' "$DAEMON_DIR/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    [ -n "$VAL" ] && ROUTER_SSH_PORT="$VAL"
    VAL=$(grep -E '^PORTAL_PORT=' "$DAEMON_DIR/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    [ -n "$VAL" ] && PORTAL_PORT="$VAL"
fi

[ -n "$CLI_ROUTER_IP" ] && ROUTER_IP="$CLI_ROUTER_IP"
[ -n "$CLI_ROUTER_USER" ] && ROUTER_SSH_USER="$CLI_ROUTER_USER"
[ -n "$CLI_ROUTER_PORT" ] && ROUTER_SSH_PORT="$CLI_ROUTER_PORT"

echo -e "${CYAN}==============================================================${NC}"
echo -e "${RED}⚠️  OpenPisoWiFi Uninstallation & Cleanup Tool${NC}"
echo -e "${CYAN}==============================================================${NC}"
echo -e "• User:              ${YELLOW}${CURRENT_USER}${NC}"
echo -e "• Install Directory: ${YELLOW}${ROOT_DIR}${NC}"
echo ""

# ------------------------------------------------------------------------------
# INTERACTIVE CONFIRMATION & QUESTIONNAIRE
# ------------------------------------------------------------------------------
IS_INTERACTIVE=false
if [ "$NON_INTERACTIVE" = false ]; then
    if [ -t 0 ]; then
        if exec 3<&0 2>/dev/null; then
            IS_INTERACTIVE=true
        fi
    elif [ -c /dev/tty ] && { exec 3</dev/tty; } 2>/dev/null; then
        IS_INTERACTIVE=true
    fi
fi

if [ "$IS_INTERACTIVE" = true ]; then
    echo -e "${YELLOW}This script will remove OpenPisoWiFi services and system configurations.${NC}"
    echo ""
    read -r -u 3 -p "Are you sure you want to uninstall OpenPisoWiFi? [y/N]: " CONFIRM_UNINSTALL
    case "$CONFIRM_UNINSTALL" in
        [yY]|[yY][eE][sS])
            echo ""
            ;;
        *)
            echo -e "${GREEN}Uninstallation cancelled.${NC}"
            exec 3<&- 2>/dev/null || true
            exit 0
            ;;
    esac

    # Ask about database and config files
    if [ "$PURGE_DATA" = false ] && [ "$KEEP_DATA" = false ]; then
        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        echo -e "${PURPLE}Data & Configuration Retention:${NC}"
        echo -e "  Do you want to KEEP your database (sales, sessions, vouchers) and .env files,"
        echo -e "  or permanently PURGE all data?"
        read -r -u 3 -p "  Keep database and configurations? [Y/n]: " KEEP_REPLY
        case "$KEEP_REPLY" in
            [nN]|[nN][oO])
                PURGE_DATA=true
                echo -e "  • ${RED}Database and .env files will be removed.${NC}"
                ;;
            *)
                PURGE_DATA=false
                echo -e "  • ${GREEN}Database and .env files will be preserved.${NC}"
                ;;
        esac
    fi

    # Check for OpenWrt Router cleanup
    if [ "$CLEAN_ROUTER" = false ]; then
        echo ""
        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        echo -e "${PURPLE}OpenWrt Router Cleanup:${NC}"
        echo -e "  Do you also want to remove OpenPisoWiFi firewall rules & DNS configurations"
        echo -e "  from your OpenWrt router (${ROUTER_SSH_USER}@${ROUTER_IP}:${ROUTER_SSH_PORT})?"
        read -r -u 3 -p "  Clean OpenWrt router as well? [y/N]: " ROUTER_REPLY
        case "$ROUTER_REPLY" in
            [yY]|[yY][eE][sS])
                CLEAN_ROUTER=true
                echo -e "  • ${YELLOW}OpenWrt router cleanup enabled.${NC}"
                ;;
            *)
                CLEAN_ROUTER=false
                echo -e "  • ${GREEN}OpenWrt router configuration will remain untouched.${NC}"
                ;;
        esac
    fi

    # Check for network settings rollback
    if [ "$REVERT_NETWORK" = false ]; then
        if grep -q "OpenPisoWifi Static IP Configuration" /etc/dhcpcd.conf 2>/dev/null; then
            echo ""
            echo -e "${CYAN}--------------------------------------------------------------${NC}"
            echo -e "${PURPLE}Host Network Configuration (/etc/dhcpcd.conf):${NC}"
            echo -e "  A static IP configuration was found in /etc/dhcpcd.conf."
            read -r -u 3 -p "  Revert /etc/dhcpcd.conf static IP back to default DHCP? [y/N]: " NET_REPLY
            case "$NET_REPLY" in
                [yY]|[yY][eE][sS])
                    REVERT_NETWORK=true
                    ;;
                *)
                    REVERT_NETWORK=false
                    ;;
            esac
        fi
    fi

    echo ""
    exec 3<&- 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# STEP 0: CREATE SAFETY BACKUP ARCHIVE
# ------------------------------------------------------------------------------
if [ "$CREATE_BACKUP" = true ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="${HOME}/openpiso-backup-${TIMESTAMP}.tar.gz"
    echo -e "${PURPLE}[0/6] Creating pre-uninstallation safety backup...${NC}"

    BACKUP_ITEMS=()
    [ -f "$PORTAL_DIR/prisma/dev.db" ] && BACKUP_ITEMS+=("$PORTAL_DIR/prisma/dev.db")
    [ -f "$PORTAL_DIR/prisma/dev.db-wal" ] && BACKUP_ITEMS+=("$PORTAL_DIR/prisma/dev.db-wal")
    [ -f "$PORTAL_DIR/prisma/dev.db-shm" ] && BACKUP_ITEMS+=("$PORTAL_DIR/prisma/dev.db-shm")
    [ -f "$PORTAL_DIR/.env" ] && BACKUP_ITEMS+=("$PORTAL_DIR/.env")
    [ -f "$DAEMON_DIR/.env" ] && BACKUP_ITEMS+=("$DAEMON_DIR/.env")
    [ -f "$HOME/.github_token" ] && BACKUP_ITEMS+=("$HOME/.github_token")

    if [ ${#BACKUP_ITEMS[@]} -gt 0 ]; then
        tar -czf "$BACKUP_FILE" "${BACKUP_ITEMS[@]}" 2>/dev/null || true
        if [ -f "$BACKUP_FILE" ]; then
            chmod 600 "$BACKUP_FILE" 2>/dev/null || true
            chown "${CURRENT_USER}:${CURRENT_USER}" "$BACKUP_FILE" 2>/dev/null || true
            echo -e "${GREEN}✓ Safety backup created: ${YELLOW}${BACKUP_FILE}${NC}"
        fi
    else
        echo -e "  • No existing database or env files found to backup."
    fi
    echo ""
fi

# ------------------------------------------------------------------------------
# STEP 1: STOP & REMOVE SYSTEMD SERVICES
# ------------------------------------------------------------------------------
echo -e "${PURPLE}[1/6] Stopping and removing systemd services...${NC}"

for SVC in pisowifi-daemon.service pisowifi-portal.service; do
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        echo -e "  • Stopping ${SVC}..."
        sudo systemctl stop "$SVC" 2>/dev/null || true
    fi
    if systemctl is-enabled --quiet "$SVC" 2>/dev/null; then
        echo -e "  • Disabling ${SVC}..."
        sudo systemctl disable "$SVC" 2>/dev/null || true
    fi
    if [ -f "/etc/systemd/system/${SVC}" ]; then
        echo -e "  • Removing /etc/systemd/system/${SVC}..."
        sudo rm -f "/etc/systemd/system/${SVC}"
    fi
done

sudo systemctl daemon-reload 2>/dev/null || true
sudo systemctl reset-failed 2>/dev/null || true
echo -e "${GREEN}✓ Systemd services removed.${NC}"
echo ""

# ------------------------------------------------------------------------------
# STEP 2: REMOVE IPTABLES PORT 80 REDIRECTION
# ------------------------------------------------------------------------------
echo -e "${PURPLE}[2/6] Cleaning up iptables port redirection rules...${NC}"

# Remove PREROUTING port 80 redirect
while sudo iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port "${PORTAL_PORT}" 2>/dev/null; do
    echo -e "  • Removing PREROUTING port 80 redirect rule..."
    sudo iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port "${PORTAL_PORT}" 2>/dev/null || break
done

# Remove OUTPUT loopback port 80 redirect
while sudo iptables -t nat -C OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-port "${PORTAL_PORT}" 2>/dev/null; do
    echo -e "  • Removing OUTPUT loopback port 80 redirect rule..."
    sudo iptables -t nat -D OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-port "${PORTAL_PORT}" 2>/dev/null || break
done

# Also check common default 3000 if PORTAL_PORT was different
if [ "${PORTAL_PORT}" != "3000" ]; then
    while sudo iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3000 2>/dev/null; do
        sudo iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3000 2>/dev/null || break
    done
    while sudo iptables -t nat -C OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-port 3000 2>/dev/null; do
        sudo iptables -t nat -D OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-port 3000 2>/dev/null || break
    done
fi

if command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save 2>/dev/null || true
fi
echo -e "${GREEN}✓ Iptables port redirection cleaned up.${NC}"
echo ""

# ------------------------------------------------------------------------------
# STEP 3: REMOVE PASSWORDLESS SUDOERS CONFIGURATION
# ------------------------------------------------------------------------------
echo -e "${PURPLE}[3/6] Removing sudoers permissions (/etc/sudoers.d/openpisowifi)...${NC}"
if [ -f /etc/sudoers.d/openpisowifi ]; then
    sudo rm -f /etc/sudoers.d/openpisowifi
    echo -e "${GREEN}✓ Sudoers file removed.${NC}"
else
    echo -e "  • No sudoers file found at /etc/sudoers.d/openpisowifi."
fi
echo ""

# ------------------------------------------------------------------------------
# STEP 4: CLEAN STANDALONE GATEWAY CONFIGURATION (If installed)
# ------------------------------------------------------------------------------
echo -e "${PURPLE}[4/6] Checking for standalone gateway configuration...${NC}"

GATEWAY_FOUND=false
if [ -f /etc/dnsmasq.d/openpiso-gateway.conf ] || [ -f /etc/nftables.d/openpiso-gateway.nft ] || [ "$CLEAN_GATEWAY" = true ]; then
    GATEWAY_FOUND=true
    echo -e "  • Removing /etc/dnsmasq.d/openpiso-gateway.conf..."
    sudo rm -f /etc/dnsmasq.d/openpiso-gateway.conf
    sudo systemctl restart dnsmasq 2>/dev/null || true

    echo -e "  • Removing nftables gateway table & configuration..."
    if command -v nft >/dev/null 2>&1; then
        sudo nft delete table inet piso 2>/dev/null || true
    fi
    sudo rm -f /etc/nftables.d/openpiso-gateway.nft

    echo -e "  • Removing /etc/sysctl.d/99-openpiso-gateway.conf..."
    sudo rm -f /etc/sysctl.d/99-openpiso-gateway.conf
    sudo sysctl -w net.ipv4.ip_forward=0 2>/dev/null || true

    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
        sudo nmcli connection delete "openpiso-lan" 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ Standalone gateway configuration removed.${NC}"
else
    echo -e "  • No standalone gateway configuration detected."
fi
echo ""

# ------------------------------------------------------------------------------
# STEP 5: REVERT STATIC IP CONFIGURATION (Optional)
# ------------------------------------------------------------------------------
echo -e "${PURPLE}[5/6] Network configuration status...${NC}"
if [ "$REVERT_NETWORK" = true ]; then
    if [ -f /etc/dhcpcd.conf ] && grep -q "OpenPisoWifi Static IP Configuration" /etc/dhcpcd.conf; then
        echo -e "  • Reverting static IP block in /etc/dhcpcd.conf..."
        # Remove OpenPisoWifi static block from dhcpcd.conf
        sudo sed -i '/# OpenPisoWifi Static IP Configuration/,+4d' /etc/dhcpcd.conf 2>/dev/null || true
        sudo systemctl restart dhcpcd 2>/dev/null || true
        echo -e "${GREEN}✓ /etc/dhcpcd.conf static IP reverted to DHCP.${NC}"
    elif command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
        ETH_CONN=$(nmcli -t -f NAME,TYPE connection show | grep ':802-3-ethernet' | head -n1 | cut -d':' -f1 || echo "")
        if [ -n "$ETH_CONN" ]; then
            echo -e "  • Reverting NetworkManager connection '${ETH_CONN}' to DHCP (auto)..."
            sudo nmcli connection modify "$ETH_CONN" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns "" 2>/dev/null || true
            sudo nmcli connection up "$ETH_CONN" 2>/dev/null || true
            echo -e "${GREEN}✓ NetworkManager connection reverted to auto DHCP.${NC}"
        fi
    fi
else
    echo -e "  • Host network configuration was preserved (Static IP untouched)."
fi
echo ""

# ------------------------------------------------------------------------------
# STEP 6: OPENWRT ROUTER CLEANUP (Optional)
# ------------------------------------------------------------------------------
if [ "$CLEAN_ROUTER" = true ]; then
    echo -e "${PURPLE}[6/6] Cleaning OpenPisoWiFi configurations from OpenWrt Router (${ROUTER_IP})...${NC}"
    ROUTER_SCRIPT="$ROOT_DIR/openwrt/uninstall-openwrt.sh"

    # Identify SSH identity key
    SSH_OPTS=(-p "$ROUTER_SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=8)
    if sudo test -f /root/.ssh/id_rsa; then
        SSH_KEY_ARG=(-i /root/.ssh/id_rsa)
    elif [ -f "$HOME/.ssh/id_rsa" ]; then
        SSH_KEY_ARG=(-i "$HOME/.ssh/id_rsa")
    else
        SSH_KEY_ARG=()
    fi

    if [ -f "$ROUTER_SCRIPT" ]; then
        echo -e "  • Running router uninstallation script on ${ROUTER_SSH_USER}@${ROUTER_IP}..."
        if sudo ssh "${SSH_OPTS[@]}" "${SSH_KEY_ARG[@]}" "${ROUTER_SSH_USER}@${ROUTER_IP}" 'sh -s' < "$ROUTER_SCRIPT"; then
            echo -e "${GREEN}✓ OpenWrt Router cleanup completed successfully.${NC}"
        else
            echo -e "${YELLOW}⚠️ Could not automatically execute script over SSH.${NC}"
            echo -e "  You can run the router cleanup manually on your OpenWrt router:"
            echo -e "  ${CYAN}cat openwrt/uninstall-openwrt.sh | ssh ${ROUTER_SSH_USER}@${ROUTER_IP} 'sh'${NC}"
        fi
    else
        # Inline fallback commands for OpenWrt
        ssh "${SSH_OPTS[@]}" "${SSH_KEY_ARG[@]}" "${ROUTER_SSH_USER}@${ROUTER_IP}" << 'EOF' || true
            /etc/init.d/piso-firewall stop 2>/dev/null || true
            /etc/init.d/piso-firewall disable 2>/dev/null || true
            rm -f /etc/init.d/piso-firewall

            /etc/init.d/piso-qos stop 2>/dev/null || true
            /etc/init.d/piso-qos disable 2>/dev/null || true
            rm -f /etc/init.d/piso-qos

            nft delete table inet piso_portal 2>/dev/null || true
            rm -f /etc/nftables.piso.nft /etc/pisowifi-dhcp-hook.sh /etc/sysctl.d/99-piso-performance.conf
            rm -f /etc/config/piso_devices /etc/config/piso_qos

            uci -q delete firewall.piso_portal
            uci commit firewall
            uci -q delete dhcp.piso_domain
            uci -q delete dhcp.@dnsmasq[0].dhcpscript
            uci commit dhcp
            uci -q delete network.lan_alias10
            uci commit network

            ip addr del 10.0.0.1/32 dev br-lan 2>/dev/null || true
            sed -i '/wifi\.local/d' /etc/hosts 2>/dev/null || true

            /etc/init.d/firewall restart 2>/dev/null || true
            /etc/init.d/dnsmasq restart 2>/dev/null || true
EOF
        echo -e "${GREEN}✓ OpenWrt Router cleanup command executed.${NC}"
    fi
    echo ""
else
    echo -e "${PURPLE}[6/6] OpenWrt Router cleanup skipped.${NC}"
    echo -e "  • If you want to clean up your OpenWrt router rules later, run:"
    echo -e "    ${YELLOW}bash scripts/uninstall.sh --router${NC} or run ${YELLOW}openwrt/uninstall-openwrt.sh${NC} directly on the router."
    echo ""
fi

# ------------------------------------------------------------------------------
# STEP 7: DATA & DIRECTORY CLEANUP (PURGE MODE)
# ------------------------------------------------------------------------------
if [ "$PURGE_DATA" = true ]; then
    echo -e "${RED}🗑️ Purging application database and environment files...${NC}"
    rm -f "$PORTAL_DIR/prisma/dev.db"* 2>/dev/null || true
    rm -f "$PORTAL_DIR/.env" 2>/dev/null || true
    rm -f "$DAEMON_DIR/.env" 2>/dev/null || true
    rm -f "$HOME/.github_token" 2>/dev/null || true
    echo -e "${GREEN}✓ Database and environment configuration files removed.${NC}"
else
    echo -e "${GREEN}🔒 Data Retention: Database (dev.db) and .env files were PRESERVED.${NC}"
    echo -e "  Location: ${YELLOW}${PORTAL_DIR}/prisma/dev.db${NC}"
    echo -e "  If you reinstall OpenPisoWiFi, all your sales and settings will be intact."
fi

echo ""
echo -e "${CYAN}==============================================================${NC}"
echo -e "${GREEN}🎉 OpenPisoWiFi Uninstallation Finished!${NC}"
echo -e "${CYAN}==============================================================${NC}"
echo -e "Summary of actions taken:"
echo -e "  • Background services stopped and removed from systemd"
echo -e "  • Port 80 iptables redirection removed"
echo -e "  • Sudoers permissions (/etc/sudoers.d/openpisowifi) removed"
if [ "$CREATE_BACKUP" = true ] && [ -f "$BACKUP_FILE" ]; then
    echo -e "  • Safety backup archive saved at: ${YELLOW}${BACKUP_FILE}${NC}"
fi
if [ "$PURGE_DATA" = true ]; then
    echo -e "  • Database and .env files: ${RED}Purged${NC}"
else
    echo -e "  • Database and .env files: ${GREEN}Preserved for future reinstall${NC}"
fi

echo ""
echo -e "💡 To completely remove this folder, run:"
echo -e "   ${YELLOW}cd .. && rm -rf ${ROOT_DIR}${NC}"
echo -e "${CYAN}==============================================================${NC}"
