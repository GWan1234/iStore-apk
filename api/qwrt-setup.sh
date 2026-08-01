#!/bin/sh
# ============================================================
#  iStore App - QWRT 一次性授权脚本
#  作用：为 QWRT 路由器安装 rpcd ACL 授权（LuCI 基础接口），
#        使 iStore App 可以用 root 账号密码登录并读取数据。
#  用法：SSH 到 QWRT，执行：
#        wget -O- https://raw.githubusercontent.com/HWYWL/iStore/main/api/qwrt-setup.sh | sh
#  只需执行一次，永久生效（重启不丢失）。可随时重复执行（幂等）。
# ============================================================

ACL_FILE="/usr/share/rpcd/acl.d/istore-app.json"

echo ""
echo "╔═══════════════════════════════════╗"
echo "║   iStore App - QWRT 授权安装      ║"
echo "╚═══════════════════════════════════╝"
echo ""

# ---- 1. 安装 rpcd-mod-file（提供 ubus file 对象） ----
if ubus list 2>/dev/null | grep -qw '^file$' || ubus list 2>/dev/null | grep -qw 'file'; then
    echo "[✓] ubus file 对象已存在"
else
    echo "[i] 安装 rpcd-mod-file ..."
    opkg update >/dev/null 2>&1
    if opkg install rpcd-mod-file >/dev/null 2>&1; then
        echo "[✓] rpcd-mod-file 安装完成"
    else
        echo "[!] rpcd-mod-file 安装失败（可能是网络问题），继续安装授权文件"
    fi
fi

# ---- 2. 写入 ACL 授权文件 ----
echo "[i] 写入 ACL 授权文件 $ACL_FILE ..."
mkdir -p /usr/share/rpcd/acl.d
cat > "$ACL_FILE" <<'ISTORE_ACL_EOF'
{
	"istore-app": {
		"description": "iStore App / LuCI base access",
		"read": {
			"ubus": {
				"system": ["board", "info"],
				"network.interface": ["dump"],
				"network.device": ["status"],
				"network.wireless": ["status"],
				"luci": ["*"],
				"luci-rpc": ["*"],
				"iwinfo": ["*"],
				"rc": ["list"],
				"service": ["list"],
				"session": ["access", "login"],
				"file": ["read", "list", "stat", "md5"],
				"uci": ["get", "state", "configs", "changes"],
				"dhcp": ["ipv4leases", "ipv6leases"],
				"hostapd.*": ["del_client", "wps_status"]
			},
			"file": {
				"/proc/sys/net/netfilter/nf_conntrack_count": ["read"],
				"/proc/sys/net/netfilter/nf_conntrack_max": ["read"],
				"/proc/mounts": ["read"],
				"/proc/net/dev": ["read"],
				"/proc/meminfo": ["read"],
				"/proc/cpuinfo": ["read"],
				"/proc/loadavg": ["read"],
				"/proc/stat": ["read"],
				"/tmp/dhcp.leases": ["read"],
				"/sys/class/thermal/*": ["read"],
				"/etc/board.json": ["read"]
			}
		},
		"write": {
			"ubus": {
				"system": ["reboot"],
				"rc": ["list", "init"],
				"service": ["list", "state", "signal", "event"],
				"uci": ["get", "state", "configs", "set", "add", "delete", "rename", "order", "changes", "apply", "confirm", "rollback", "revert"],
				"file": ["read", "write", "list", "stat", "remove", "exec"],
				"appfilter": ["*"],
				"luci": ["setInitAction", "setLocaltime", "setPassword", "setBlockDetect"]
			},
			"uci": {
				"*": ["read", "write"]
			},
			"file": {
				"/etc/config/*": ["read", "write"],
				"/sbin/reboot": ["exec"],
				"/sbin/firstboot -r -y": ["exec"],
				"/sbin/ip -[46] route show table all": ["exec"],
				"/sbin/ip -[46] neigh show": ["exec"],
				"/bin/df": ["exec"],
				"/bin/ps": ["exec"],
				"/usr/bin/ps": ["exec"]
			}
		}
	}
}
ISTORE_ACL_EOF

if [ ! -s "$ACL_FILE" ]; then
    echo "[x] 授权文件写入失败"
    exit 1
fi
echo "[✓] 授权文件已安装"

# ---- 3. 重启 rpcd 使授权生效 ----
echo "[i] 重启 rpcd ..."
/etc/init.d/rpcd restart >/dev/null 2>&1
sleep 1

# ---- 4. 验证 ----
if ubus call system board >/dev/null 2>&1; then
    echo "[✓] 验证通过：system board 可访问"
else
    echo "[!] 验证未通过，请检查 /etc/config/rpcd 中 login 段的 read/write 是否包含 '*'"
fi

echo ""
echo "=============================================="
echo "  授权完成！现在打开 iStore App，"
echo "  用 root + 路由器管理密码即可登录本设备。"
echo "=============================================="
echo ""
