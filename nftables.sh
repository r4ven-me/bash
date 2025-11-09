#!/usr/bin/env bash

# Script security parameters
set -Eeuo pipefail

# Explicit PATH definition
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# =============================================================
# ========== BEGINNING OF USER CONFIGURATION SECTION ==========

NFT="$(command -v nft)"
NFT_CONFIG="/etc/nftables.conf"
NFT_RULES=(
# =====================
#     TABLES & SETS
# =====================
# "flush ruleset"
"add table inet filter"
"flush table inet filter"
"add table inet nat"
"flush table inet nat"

"add set inet filter lan4 { type ipv4_addr; flags interval; elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } }"
"add set inet filter lan6 { type ipv6_addr; flags interval; elements = { fd00::/8, fe80::/10 } }"
"add set inet filter trusted { type ipv4_addr; elements = { 123.34.56.78 } }"

# =====================
#        CHAINS
# =====================
"add chain inet filter input { type filter hook input priority 0; policy drop; }"
"add chain inet filter forward { type filter hook forward priority 50; policy drop; }"
"add chain inet filter output { type filter hook output priority -200; policy accept; }"
"add chain inet nat prerouting { type nat hook prerouting priority dstnat; policy accept; }"
"add chain inet nat postrouting { type nat hook postrouting priority srcnat; policy accept; }"

"add chain inet filter input_wan"
"add chain inet filter input_lan"
"add chain inet filter log_drop"

# =====================
#      INPUT BASE
# =====================
"add rule inet filter input ct state invalid drop comment \"Drop invalid connections\""
"add rule inet filter input ct state { established, related } accept comment \"Allow established connections\""
"add rule inet filter input iif lo accept comment \"Allow loopback\""
"add rule inet filter input ip saddr @trusted accept comment \"Allow trusted IPs\""

# ICMP
"add rule inet filter input meta l4proto icmp icmp type { echo-request, destination-unreachable, time-exceeded } limit rate 10/second accept comment \"ICMP rate limited\""
"add rule inet filter input meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, mld-listener-query, mld-listener-report, mld-listener-reduction, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, mld2-listener-report } accept comment \"Necessary IPv6 ICMP\""

# UDP traceroute
"add rule inet filter input_wan udp dport 33434-33534 reject comment \"Allow UDP traceroute\""

# LAN/WAN
"add rule inet filter input ip saddr @lan4 jump input_lan comment \"LAN IPv4 processing\""
"add rule inet filter input ip6 saddr @lan6 jump input_lan comment \"LAN IPv6 processing\""
"add rule inet filter input ip saddr != @lan4 jump input_wan comment \"WAN IPv4 processing\""
"add rule inet filter input ip6 saddr != @lan6 jump input_wan comment \"WAN IPv6 processing\""
"add rule inet filter input jump log_drop comment \"Default drop\""

# =====================
#       INPUT LAN
# =====================
# Allow all
"add rule inet filter input_lan meta l4proto { tcp, udp } accept comment \"Allow all TCP/UDP from LAN\""
# Or allow selected
# "add rule inet filter input_lan tcp dport { 80, 443 } accept comment \"Allowed TCP ports from LAN\""
# "add rule inet filter input_lan udp dport { 53, 123 } accept comment \"Allowed UDP ports from LAN\""
# "add rule inet filter input_lan ct state new jump log_drop comment \"Drop all from LAN with log\""

# =====================
#       INPUT WAN
# =====================
"add rule inet filter input_wan tcp dport 22 accept comment \"Allow SSH from WAN\"" 
"add rule inet filter input_wan tcp dport { 80, 443 } accept comment \"Allowed TCP ports from WAN\""
"add rule inet filter input_wan udp dport { 53, 123 } accept comment \"Allowed UDP ports from WAN\""
"add rule inet filter input_wan iifname \"eth0\" tcp dport 443 accept comment \"DNAT: 443->43443\""
"add rule inet filter input_wan iifname \"eth0\" ct status dnat tcp dport 43443 accept comment \"DNAT: 443->43443\""
"add rule inet filter input_wan ct state new jump log_drop comment \"Drop all from WAN\""

# =====================
#        FORWARD
# =====================
"add rule inet filter forward ct state established,related accept"
"add rule inet filter forward iifname \"cni*\" accept comment \"Allow K8s forward in\""
"add rule inet filter forward oifname \"cni*\" accept comment \"Allow K8s forward out\""
"add rule inet filter forward iifname \"flannel.*\" accept comment \"Allow K8s forward in\""
"add rule inet filter forward oifname \"flannel.*\" accept comment \"Allow K8s forward out\""
"add rule inet filter forward iifname \"vxlan.calico\" accept comment \"Allow K8s forward in\""
"add rule inet filter forward oifname \"vxlan.calico\" accept comment \"Allow K8s forward out\""
"add rule inet filter forward iifname \"br-*\" accept comment \"Allow Docker forward in\""
"add rule inet filter forward oifname \"br-*\" accept comment \"Allow Docker forward out\""
"add rule inet filter forward iifname \"virbr*\" accept comment \"Allow VMs forward in\""
"add rule inet filter forward oifname \"virbr*\" accept comment \"Allow VMs forward out\""
"add rule inet filter forward iifname \"tun*\" accept comment \"Allow OC forward in\""
"add rule inet filter forward oifname \"tun*\" accept comment \"Allow OC forward out\""
"add rule inet filter forward iifname \"wg*\" accept comment \"Allow WG forward in\""
"add rule inet filter forward oifname \"wg*\" accept comment \"Allow WG forward out\""
"add rule inet filter forward ct state new jump log_drop comment \"Drop all forward\""

# =====================
#      LOG & DROP
# =====================
"add rule inet filter log_drop limit rate 5/second log prefix \"NFT-DROP: \" flags all counter comment \"Drop logging\""
# "add rule inet filter input meta l4proto tcp reject with tcp reset comment \"Reject TCP\""
# "add rule inet filter input meta l4proto udp reject comment \"Reject UDP\""
# "add rule inet filter input counter reject with icmpx type port-unreachable comment \"Reject other protocols\""
# "add rule inet filter input pkttype host limit rate 5/second counter reject with icmpx type admin-prohibited comment \"Protection from port scanning\""
"add rule inet filter log_drop drop comment \"Drop all\""

# =====================
#         NAT
# =====================
"add rule inet nat prerouting iifname \"eth0\" tcp dport 443 redirect to 43443 comment \"DNAT: 443->43443\""
# "add rule inet nat prerouting iifname \"eth0\" tcp dport 443 dnat to :43443 comment \"DNAT:  443->43443 \""
# "add rule inet nat postrouting oifname != lo masquerade comment \"SNAT: NAT processing for all\""
# "add rule inet nat postrouting oifname \"eth0\" masquerade comment \"SNAT: NAT procesing for eth0\""
"add rule inet nat postrouting oifname \"tun*\" masquerade comment \"SNAT: NAT procesing for OC\""
)

# ========== END OF USER CONFIGURATION SECTION ==========
# =======================================================

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd -P)
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_TMP=$(mktemp "${SCRIPT_DIR}"/"${SCRIPT_NAME}"_XXXXXXXX)

cleanup() {
    trap - SIGINT SIGTERM SIGHUP SIGQUIT ERR EXIT

    rm -f "$SCRIPT_TMP"
}

trap cleanup SIGINT SIGTERM SIGHUP SIGQUIT ERR EXIT


usage() {
    cat <<EOF
Usage: $SCRIPT_NAME OPTIONS

Description:
  Script to configure the firewall via nftables.

Options:
  -h, --help            Show this help message and exit
  -a, --apply           *Apply new rules from this script
  -s, --save            *Save current ruleset to /etc/nftables.conf
  -b, --backup          *Create a backup of /etc/nftables.conf
  -c, --check           *Dry-run mode (check syntax without applying changes)

Note:
  One of the * options is required.

Examples:
  nftables.sh -a
  nftables.sh --check --apply
  nftables.sh --apply --save --backup
EOF
}


parse_params() {
    APPLY=0 SAVE=0 BACKUP=0 CHECK=0

    while [[ $# -gt 0 ]]; do
      case $1 in
        -h|--help) usage; exit 0 ;;
        -a|--apply) APPLY=1 ;;
        -s|--save) SAVE=1 ;;
        -b|--backup) BACKUP=1 ;;
        -c|--check) CHECK=1 ;;
        *) usage; exit 1 ;;
      esac
      shift
    done

    (( APPLY || SAVE || BACKUP || CHECK )) || { usage; exit 1; }

    # echo "apply=$APPLY save=$SAVE backup=$BACKUP"
}


save_current_rules() {
    echo -e "#!${NFT} -f\n\nflush ruleset\n\n$($NFT -s list table inet filter)" > "$NFT_CONFIG"
    chmod 644 "$NFT_CONFIG"
	echo "Rules successfully saved at $NFT_CONFIG"
}


backup_current_config() {
    local datetime
    datetime="$(date +%Y-%m-%d_%H-%M-%S)"

	if [[ -f "$NFT_CONFIG" ]]; then
		cp "${NFT_CONFIG}"{,_"${datetime}"}
		echo "Backup created: ${NFT_CONFIG}_${datetime}"
	fi
}


# =====================
#   Main script flow
# =====================
parse_params "$@"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root"
    exit 1
fi

if (( BACKUP )); then backup_current_config; fi

if (( CHECK )); then
    for rule in "${NFT_RULES[@]}"; do
        echo "$rule" >> "$SCRIPT_TMP"
    done

    "$NFT" -c -f "$SCRIPT_TMP"|| { echo "Syntax - error"; exit 1; }
    cat "$SCRIPT_TMP"
    echo -e "-----------\nSyntax - ok"
fi

if (( APPLY )); then
    for rule in "${NFT_RULES[@]}"; do
        echo "$rule" >> "$SCRIPT_TMP"
    done

    if ! (( CHECK )); then
        "$NFT" -c -f "$SCRIPT_TMP" || { echo "Syntax - error"; exit 1; }
    fi

    "$NFT" -f "$SCRIPT_TMP" && echo "Rules applied"
fi

if (( SAVE )); then save_current_rules; fi

