#!/bin/bash

CLASH_DNS_PORT=5334
CLASH_TPROXY_PORT=7894
FAKE_IP_RANGE="198.18.0.0/16"
BYPASS_IPSET_NAME="bypass"
PROXY_IPSET_NAME="proxy"
MARK_VALUE="0x114"
ROUTE_TABLE=514
CLASH_USER="mihomo"
CLASH_GROUP="mihomo"
DUMMY_DNS_IFACE="mihomo-dns0"
IP_RULE_PREF=9000

# 绕过IP范围
BYPASS_IPRANGES=(
    "0.0.0.0/8"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/4"
    "240.0.0.0/4"
)

BYPASS_IP6RANGES=(
    "::/128"
    "::1/128"
    "fc00::/7"
    "fe80::/10"
    "ff00::/8"
    "2001:250:4001:108::/64"
)

setup_nftables() {
    # 初始化规则表
    nft add table ip clash
    nft flush table ip clash

    # 初始化IPSET
    nft add set ip clash $BYPASS_IPSET_NAME { type ipv4_addr \; flags interval \; }
    for iprange in "${BYPASS_IPRANGES[@]}"; do
        nft add element ip clash $BYPASS_IPSET_NAME { $iprange }
    done
    # nft add set ip clash $PROXY_IPSET_NAME { type ipv4_addr \; flags interval \; }
    # for iprange in "${PROXY_IPRANGES[@]}"; do
    #     nft add element ip clash $PROXY_IPSET_NAME { $iprange }
    # done

    ## DNS流量拦截
    # 局域网流量
    nft add chain ip clash dns_prerouting { type nat hook prerouting priority dstnat \; }
    nft add rule ip clash dns_prerouting ip protocol udp udp dport 53 redirect to $CLASH_DNS_PORT
    nft add rule ip clash dns_prerouting ip protocol tcp tcp dport 53 redirect to $CLASH_DNS_PORT
    # 本机流量
    if systemctl is-active --quiet systemd-resolved.service; then
    # systemd-resolved 可用时, 采用 dummy link 配置 upstream
        ip link add "$DUMMY_DNS_IFACE" type dummy
    ip addr add 10.254.254.254/32 dev "$DUMMY_DNS_IFACE"
    ip link set "$DUMMY_DNS_IFACE" up
    resolvectl dns "$DUMMY_DNS_IFACE" "127.0.0.1:${CLASH_DNS_PORT}"
    resolvectl domain "$DUMMY_DNS_IFACE" "~."
    resolvectl default-route "$DUMMY_DNS_IFACE" yes
    resolvectl dnssec "$DUMMY_DNS_IFACE" no
    resolvectl flush-caches
    else
    # 回退使用流量劫持
        nft add chain ip clash dns_output { type nat hook output priority dstnat \; }
        # CLASH放行
        nft add rule ip clash dns_output skuid $CLASH_USER return
        nft add rule ip clash dns_output skgid $CLASH_GROUP return
    # Tailscale放行
    nft add rule ip clash dns_output meta mark \& 0xff0000 == 0x80000 return
    # 其余流量全部劫持
        nft add rule ip clash dns_output ip protocol udp udp dport 53 redirect to $CLASH_DNS_PORT
        nft add rule ip clash dns_output ip protocol tcp tcp dport 53 redirect to $CLASH_DNS_PORT
    fi

    ## 局域网流量代理
    nft add chain ip clash prerouting { type filter hook prerouting priority mangle \; }
    # 已经建立连接的 TCP 流量无需再检查
    nft add rule ip clash prerouting meta l4proto tcp socket transparent 1 meta mark set $MARK_VALUE accept
    # 绕过IP范围不代理
    nft add rule ip clash prerouting ip daddr @$BYPASS_IPSET_NAME return
    # 代理IP范围进行tproxy
    # nft add rule ip clash prerouting ip daddr @$PROXY_IPSET_NAME meta l4proto {tcp, udp} mark set $MARK_VALUE tproxy to 127.0.0.1:$CLASH_TPROXY_PORT
    nft add rule ip clash prerouting meta l4proto {tcp, udp} mark set $MARK_VALUE tproxy to 127.0.0.1:$CLASH_TPROXY_PORT

    ## 本地流量代理
    nft add chain ip clash output { type route hook output priority mangle \; }
    # CLASH流量不代理
    nft add rule ip clash output skuid $CLASH_USER return
    nft add rule ip clash output skgid $CLASH_GROUP return
    # Tailscale bypass mark 不代理
    nft add rule ip clash output meta mark \& 0xff0000 == 0x80000 return
    # 绕过IP范围不代理
    nft add rule ip clash output ip daddr @$BYPASS_IPSET_NAME return
    # 配合ip route重路由至prerouting
    # nft add rule ip clash output ip daddr @$PROXY_IPSET_NAME meta l4proto {tcp, udp} mark set $MARK_VALUE
    nft add rule ip clash output meta l4proto {tcp, udp} mark set $MARK_VALUE
}

setup_nftables_v6() {
    nft add table ip6 clash6
    nft flush table ip6 clash6

    nft add set ip6 clash6 bypass6 { type ipv6_addr \; flags interval \; }
    for iprange in "${BYPASS_IP6RANGES[@]}"; do
        nft add element ip6 clash6 bypass6 { $iprange }
    done

    ## IPv6 DNS 流量拦截：LAN 设备
    nft add chain ip6 clash6 dns_prerouting { type nat hook prerouting priority dstnat \; }
    nft add rule ip6 clash6 dns_prerouting meta l4proto udp udp dport 53 redirect to $CLASH_DNS_PORT
    nft add rule ip6 clash6 dns_prerouting meta l4proto tcp tcp dport 53 redirect to $CLASH_DNS_PORT

    ## IPv6 局域网流量代理
    nft add chain ip6 clash6 prerouting { type filter hook prerouting priority mangle \; }

    # 已经建立连接的 TCP 流量无需再检查
    nft add rule ip6 clash6 prerouting meta l4proto tcp socket transparent 1 meta mark set $MARK_VALUE accept

    # 绕过 IPv6 私网、本地链路、多播、LAN 前缀
    nft add rule ip6 clash6 prerouting ip6 daddr @bypass6 return

    # TCP/UDP 进入 mihomo tproxy-port
    nft add rule ip6 clash6 prerouting meta l4proto { tcp, udp } meta mark set $MARK_VALUE tproxy to :$CLASH_TPROXY_PORT
}

# 将本机流量下一跳跳入回环, 使其走入prerouting完成tproxy, 设置socket transparent属性以保证tproxy可用
setup_route() {
    ip route add local 0.0.0.0/0 dev lo table $ROUTE_TABLE
    ip rule add fwmark $MARK_VALUE table $ROUTE_TABLE pref $IP_RULE_PREF

    ip -6 route replace local ::/0 dev lo table $ROUTE_TABLE
    ip -6 rule add fwmark $MARK_VALUE table $ROUTE_TABLE pref $IP_RULE_PREF 2>/dev/null || true
}

cleanup_route() {
    ip rule del fwmark $MARK_VALUE table $ROUTE_TABLE pref $IP_RULE_PREF 2>/dev/null || true
    ip rule del fwmark $MARK_VALUE table $ROUTE_TABLE 2>/dev/null || true
    ip route flush table $ROUTE_TABLE 2>/dev/null || true

    ip -6 rule del fwmark $MARK_VALUE table $ROUTE_TABLE pref $IP_RULE_PREF 2>/dev/null || true
    ip -6 rule del fwmark $MARK_VALUE table $ROUTE_TABLE 2>/dev/null || true
    ip -6 route flush table $ROUTE_TABLE 2>/dev/null || true
}

cleanup_nftables() {
    if systemctl is-active --quiet systemd-resolved.service; then
        ip link del "$DUMMY_DNS_IFACE" 2>/dev/null || true
        resolvectl flush-caches 2>/dev/null || true
    fi
    nft delete table ip clash 2>/dev/null || true
    nft delete table ip6 clash6 2>/dev/null || true
}

start() {
    setup_nftables
    setup_nftables_v6
    setup_route
}

stop() {
    cleanup_route
    cleanup_nftables
}

status() {
    echo "当前 IPv4 nftables 规则:"
    nft list table ip clash 2>/dev/null || echo "IPv4 透明代理未启动"

    echo -e "\n当前 IPv6 nftables 规则:"
    nft list table ip6 clash6 2>/dev/null || echo "IPv6 透明代理未启动"
    
    echo -e "\n当前 IPv4 路由规则:"
    ip rule list | grep $MARK_VALUE || echo "没有 IPv4 相关路由规则"
    
    echo -e "\n当前 IPv4 路由表($ROUTE_TABLE):"
    ip route list table $ROUTE_TABLE 2>/dev/null || echo "IPv4 路由表为空"

    echo -e "\n当前 IPv6 路由规则:"
    ip -6 rule list | grep $MARK_VALUE || echo "没有 IPv6 相关路由规则"

    echo -e "\n当前 IPv6 路由表($ROUTE_TABLE):"
    ip -6 route list table $ROUTE_TABLE 2>/dev/null || echo "IPv6 路由表为空"
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        sleep 1
        start
        ;;
    status)
        status
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
