#!/bin/bash
# ============================================================
#  spooflan2.sh  —  VXLAN Spoof Tunnel  (A ↔ B only)
#  Roles: IR (Server A) | Kharej (Server B)
#  Both ends use spoofed IPs on lo as VXLAN source
#  Persistence: systemd oneshot service
# ============================================================

# ── Fixed constants ──────────────────────────────────────────
PRIVATE_SUBNET="10.100.100"
VXLAN_ID=10
VXLAN_PORT=80
SYSTEMD_DIR="/etc/systemd/system"
TAG="spooflan2"         # prefix for services & scripts
ITAG="sl2"             # prefix for network interfaces (≤15 chars)

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; }
die()     { error "$*"; exit 1; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root (sudo $0)"

# ── Auto-detect default interface ───────────────────────────
detect_iface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [[ -z "$iface" ]] && die "Cannot detect default network interface."
    echo "$iface"
}

# ── Input helpers ────────────────────────────────────────────
prompt() {
    local var="$1" label="$2" val
    while true; do
        read -rp "  ${label}: " val
        [[ -n "$val" ]] && { printf -v "$var" '%s' "$val"; return; }
        warn "Value cannot be empty."
    done
}

validate_ip() {
    local ip="$1"
    local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    [[ $ip =~ $re ]] || die "Invalid IP address: $ip"
    local IFS='.'
    read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do
        (( p <= 255 )) || die "Invalid IP octet: $p"
    done
}

# ════════════════════════════════════════════════════════════
#  INSTALL — Server A  (IR)
#
#  Topology:
#    lo alias: IR_SPOOF_IP  ──VXLAN 10──▶  KB_REAL_IP (Server B)
#    Private:  10.100.100.1/24 on vxlan iface
# ════════════════════════════════════════════════════════════
install_ir() {
    echo -e "\n${BOLD}── Install: IR (Server A) ──${NC}"
    prompt IR_SPOOF_IP  "IR Spoof IP         (assign on lo,   e.g. 188.209.152.178)"
    prompt KB_REAL_IP   "Kharej REAL IP      (Server B real,  e.g. 193.31.117.138)"

    validate_ip "$IR_SPOOF_IP"
    validate_ip "$KB_REAL_IP"

    local IFACE; IFACE=$(detect_iface)
    local VXLAN="${ITAG}-vx-ir"      # 9 chars
    local SERVICE="${TAG}-ir.service"
    local PRIV_IP="${PRIVATE_SUBNET}.1"

    info "Detected interface : $IFACE"
    info "Tunnel             : IR ($IR_SPOOF_IP) ──VXLAN $VXLAN_ID──▶ Kharej ($KB_REAL_IP)"
    info "Private IP on A    : $PRIV_IP/24"

    # ── Up script ────────────────────────────────────────────
    cat > /usr/local/bin/${TAG}-ir-up.sh <<EOF
#!/bin/bash
# spooflan2: IR (Server A) — bring up

IFACE=$IFACE
IR_SPOOF=$IR_SPOOF_IP
KB_REAL=$KB_REAL_IP
VXLAN=$VXLAN
PRIV_IP=$PRIV_IP

# Add spoof IP to loopback
ip addr show lo | grep -q "\${IR_SPOOF}/32" || \\
    ip addr add "\${IR_SPOOF}/32" dev lo

# Create VXLAN tunnel to Server B
ip link show "\${VXLAN}" &>/dev/null || \\
    ip link add "\${VXLAN}" type vxlan id ${VXLAN_ID} \\
        local "\${IR_SPOOF}" dev "\${IFACE}" remote "\${KB_REAL}" \\
        dstport ${VXLAN_PORT} nolearning

ip link set "\${VXLAN}" up

# Assign private IP
ip addr show "\${VXLAN}" | grep -q "\${PRIV_IP}/24" || \\
    ip addr add "\${PRIV_IP}/24" dev "\${VXLAN}"
EOF

    # ── Down script ──────────────────────────────────────────
    cat > /usr/local/bin/${TAG}-ir-down.sh <<EOF
#!/bin/bash
# spooflan2: IR (Server A) — tear down

IFACE=$IFACE
IR_SPOOF=$IR_SPOOF_IP
VXLAN=$VXLAN
PRIV_IP=$PRIV_IP

ip addr del "\${PRIV_IP}/24" dev "\${VXLAN}"  2>/dev/null || true
ip link set "\${VXLAN}" down                   2>/dev/null || true
ip link del "\${VXLAN}"                        2>/dev/null || true
ip addr del "\${IR_SPOOF}/32" dev lo           2>/dev/null || true
EOF

    chmod +x /usr/local/bin/${TAG}-ir-up.sh /usr/local/bin/${TAG}-ir-down.sh

    # ── systemd unit ─────────────────────────────────────────
    cat > "${SYSTEMD_DIR}/${SERVICE}" <<EOF
[Unit]
Description=SpoofLAN2 – IR tunnel (Server A)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/${TAG}-ir-up.sh
ExecStop=/usr/local/bin/${TAG}-ir-down.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${SERVICE}"
    success "IR tunnel UP and enabled on boot  (${SERVICE})"
}

# ════════════════════════════════════════════════════════════
#  INSTALL — Server B  (Kharej)
#
#  Topology:
#    lo alias: KB_SPOOF_IP  ──VXLAN 10──▶  IR_REAL_IP (Server A)
#    Private:  10.100.100.2/24 on vxlan iface
#
#  Note: no bridge, no Server C — tunnel terminates here.
# ════════════════════════════════════════════════════════════
install_kharej() {
    echo -e "\n${BOLD}── Install: Kharej (Server B) ──${NC}"
    prompt KB_SPOOF_IP  "Kharej Spoof IP     (assign on lo,   e.g. 194.225.80.103)"
    prompt IR_REAL_IP   "IR REAL IP          (Server A real,  e.g. 185.112.151.225)"

    validate_ip "$KB_SPOOF_IP"
    validate_ip "$IR_REAL_IP"

    local IFACE; IFACE=$(detect_iface)
    local VXLAN="${ITAG}-vx-kb"      # 9 chars
    local SERVICE="${TAG}-kharej.service"
    local PRIV_IP="${PRIVATE_SUBNET}.2"

    info "Detected interface : $IFACE"
    info "Tunnel             : Kharej ($KB_SPOOF_IP) ──VXLAN $VXLAN_ID──▶ IR ($IR_REAL_IP)"
    info "Private IP on B    : $PRIV_IP/24"

    # ── Up script ────────────────────────────────────────────
    cat > /usr/local/bin/${TAG}-kharej-up.sh <<EOF
#!/bin/bash
# spooflan2: Kharej (Server B) — bring up

IFACE=$IFACE
KB_SPOOF=$KB_SPOOF_IP
IR_REAL=$IR_REAL_IP
VXLAN=$VXLAN
PRIV_IP=$PRIV_IP

# Add spoof IP to loopback
ip addr show lo | grep -q "\${KB_SPOOF}/32" || \\
    ip addr add "\${KB_SPOOF}/32" dev lo

# Create VXLAN tunnel to Server A
ip link show "\${VXLAN}" &>/dev/null || \\
    ip link add "\${VXLAN}" type vxlan id ${VXLAN_ID} \\
        local "\${KB_SPOOF}" dev "\${IFACE}" remote "\${IR_REAL}" \\
        dstport ${VXLAN_PORT} nolearning

ip link set "\${VXLAN}" up

# Assign private IP
ip addr show "\${VXLAN}" | grep -q "\${PRIV_IP}/24" || \\
    ip addr add "\${PRIV_IP}/24" dev "\${VXLAN}"
EOF

    # ── Down script ──────────────────────────────────────────
    cat > /usr/local/bin/${TAG}-kharej-down.sh <<EOF
#!/bin/bash
# spooflan2: Kharej (Server B) — tear down

KB_SPOOF=$KB_SPOOF_IP
VXLAN=$VXLAN
PRIV_IP=$PRIV_IP

ip addr del "\${PRIV_IP}/24" dev "\${VXLAN}"  2>/dev/null || true
ip link set "\${VXLAN}" down                   2>/dev/null || true
ip link del "\${VXLAN}"                        2>/dev/null || true
ip addr del "\${KB_SPOOF}/32" dev lo           2>/dev/null || true
EOF

    chmod +x /usr/local/bin/${TAG}-kharej-up.sh /usr/local/bin/${TAG}-kharej-down.sh

    # ── systemd unit ─────────────────────────────────────────
    cat > "${SYSTEMD_DIR}/${SERVICE}" <<EOF
[Unit]
Description=SpoofLAN2 – Kharej tunnel (Server B)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/${TAG}-kharej-up.sh
ExecStop=/usr/local/bin/${TAG}-kharej-down.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${SERVICE}"
    success "Kharej tunnel UP and enabled on boot  (${SERVICE})"
}

# ════════════════════════════════════════════════════════════
#  UNINSTALL  —  removes ONLY what this script created
# ════════════════════════════════════════════════════════════
uninstall_all() {
    echo -e "\n${BOLD}── Uninstall: removing all SpoofLAN2 resources ──${NC}"

    local SERVICES=("${TAG}-ir.service" "${TAG}-kharej.service")
    local SCRIPTS=(
        "${TAG}-ir-up.sh"     "${TAG}-ir-down.sh"
        "${TAG}-kharej-up.sh" "${TAG}-kharej-down.sh"
    )

    # Stop & disable services
    for svc in "${SERVICES[@]}"; do
        if systemctl list-unit-files "${svc}" 2>/dev/null | grep -q "${svc}"; then
            info "Stopping & disabling ${svc} …"
            systemctl stop    "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
            rm -f "${SYSTEMD_DIR}/${svc}"
            success "Removed ${svc}"
        fi
    done

    systemctl daemon-reload

    # Remove helper scripts
    for scr in "${SCRIPTS[@]}"; do
        local path="/usr/local/bin/${scr}"
        if [[ -f "$path" ]]; then
            rm -f "$path"
            success "Removed $path"
        fi
    done

    # Tear down any lingering interfaces with our prefix
    for iface in $(ip link show 2>/dev/null | awk -F': ' '{print $2}' | grep "^${ITAG}-"); do
        info "Removing interface $iface …"
        ip link set "$iface" down 2>/dev/null || true
        ip link del "$iface"      2>/dev/null || true
        success "Removed interface $iface"
    done

    success "Uninstall complete — no SpoofLAN2 resources remain."
}

# ════════════════════════════════════════════════════════════
#  STATUS
# ════════════════════════════════════════════════════════════
show_status() {
    echo -e "\n${BOLD}── SpoofLAN2 Status ──${NC}"
    local found=0
    for svc in "${TAG}-ir.service" "${TAG}-kharej.service"; do
        if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
            found=1
            echo -e "  ${CYAN}${svc}${NC}"
            systemctl status "$svc" --no-pager -l | grep -E 'Active:|Loaded:' | sed 's/^/    /'
        fi
    done
    [[ $found -eq 0 ]] && warn "No SpoofLAN2 services found on this server."

    echo -e "\n  ${BOLD}Interfaces:${NC}"
    local any=0
    while read -r iface; do
        any=1
        local state; state=$(ip link show "$iface" 2>/dev/null | grep -oP '(?<=state )\S+' || echo "?")
        echo -e "    ${GREEN}${iface}${NC}  [$state]"
    done < <(ip link show 2>/dev/null | awk -F': ' '{print $2}' | grep "^${ITAG}-")
    [[ $any -eq 0 ]] && echo "    (none)"
}

# ════════════════════════════════════════════════════════════
#  MENUS
# ════════════════════════════════════════════════════════════
install_menu() {
    while true; do
        echo -e "\n${BOLD}  Install — Select Role${NC}"
        echo "    1) IR       (Server A — Iran,   uses spoof IP on lo)"
        echo "    2) Kharej   (Server B — Abroad, uses spoof IP on lo)"
        echo "    0) Back"
        read -rp "  Choice: " choice
        case "$choice" in
            1) install_ir ;;
            2) install_kharej ;;
            0) return ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

main_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════╗"
    echo "  ║       S P O O F L A N  2         ║"
    echo "  ║   VXLAN Spoof Tunnel  (A ↔ B)   ║"
    echo "  ╚══════════════════════════════════╝"
    echo -e "${NC}"

    while true; do
        echo -e "\n${BOLD}  Main Menu${NC}"
        echo "    1) Install"
        echo "    2) Uninstall"
        echo "    3) Status"
        echo "    4) Exit"
        read -rp "  Choice: " choice
        case "$choice" in
            1) install_menu ;;
            2) uninstall_all ;;
            3) show_status ;;
            4) echo "Bye."; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

main_menu
