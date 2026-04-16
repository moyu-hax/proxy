#!/bin/bash
#
# FRP 内网穿透管理脚本
# 官方开源项目: https://github.com/fatedier/frp
# 许可证: Apache-2.0
# 二进制文件 100% 来自 GitHub 官方 Releases，无任何第三方来源
#

FRP_VERSION="0.68.1"
FRP_DOWNLOAD_BASE="https://github.com/fatedier/frp/releases/download"
FRP_INSTALL_DIR="/usr/local/bin"
FRP_CONFIG_DIR="/home/frp"

# 如果你在国内无法直接访问 GitHub，取消下面这行的注释并设置代理地址
# GH_PROXY="https://ghproxy.com/"
GH_PROXY="https://ghfast.top/"

# ============================================================
#  颜色定义
# ============================================================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[96m'
NC='\033[0m'

# ============================================================
#  基础工具函数
# ============================================================

print_msg() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_err() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_err "请使用 root 用户运行此脚本"
        exit 1
    fi
}

confirm_action() {
    read -e -p "$1 [y/N]: " yn
    case "$yn" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
#  架构检测 (支持 amd64 / arm64 / arm32)
# ============================================================

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)          echo "amd64" ;;
        aarch64|arm64)   echo "arm64" ;;
        armv7l|armv6l)   echo "arm"   ;;
        *)
            print_err "不支持的 CPU 架构: $arch"
            print_err "官方支持: x86_64 (amd64), aarch64 (arm64), armv7l/armv6l (arm)"
            return 1
            ;;
    esac
}

# ============================================================
#  获取公网 IP
# ============================================================

get_ip() {
    ipv4_address=$(curl -s4 --max-time 5 ifconfig.me || curl -s4 --max-time 5 ip.sb || echo "获取失败")
}

# ============================================================
#  下载并安装 frp 官方二进制文件
# ============================================================

install_frp() {
    local arch
    arch=$(get_arch) || return 1

    local filename="frp_${FRP_VERSION}_linux_${arch}"
    local tarball="${filename}.tar.gz"
    local url="${GH_PROXY}${FRP_DOWNLOAD_BASE}/v${FRP_VERSION}/${tarball}"

    echo ""
    echo "============================================"
    print_msg "正在从 GitHub 官方下载 frp v${FRP_VERSION}"
    echo "  架构: ${arch} ($(uname -m))"
    echo "  来源: ${FRP_DOWNLOAD_BASE}/v${FRP_VERSION}/${tarball}"
    echo "============================================"
    echo ""

    cd /tmp || return 1
    rm -f "$tarball"

    # 优先用 curl，兼容 NAS/busybox 等精简环境
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$tarball" "$url"
    elif wget --help 2>&1 | grep -q '\-\-show-progress'; then
        wget -q --show-progress -O "$tarball" "$url"
    else
        wget -O "$tarball" "$url"
    fi

    if [ $? -ne 0 ] || [ ! -s "$tarball" ]; then
        print_err "下载失败，请检查网络或设置 GH_PROXY"
        return 1
    fi

    # 校验: 确认解压可用（兼容无 file 命令的环境）
    if command -v file >/dev/null 2>&1; then
        if ! file "$tarball" | grep -q "gzip"; then
            print_err "下载的文件不是有效的 tar.gz 压缩包，可能被拦截"
            rm -f "$tarball"
            return 1
        fi
    fi

    tar -xzf "$tarball" || { print_err "解压失败"; return 1; }

    # 安装二进制文件
    mkdir -p "$FRP_INSTALL_DIR" "$FRP_CONFIG_DIR"
    cp "${filename}/frps" "$FRP_INSTALL_DIR/" 2>/dev/null
    cp "${filename}/frpc" "$FRP_INSTALL_DIR/" 2>/dev/null
    chmod +x "$FRP_INSTALL_DIR/frps" "$FRP_INSTALL_DIR/frpc" 2>/dev/null

    # 清理临时文件
    rm -rf "$tarball" "$filename"

    # 验证安装
    if [ -f "$FRP_INSTALL_DIR/frps" ] && [ -f "$FRP_INSTALL_DIR/frpc" ]; then
        print_msg "安装成功: frp v$($FRP_INSTALL_DIR/frps --version 2>/dev/null)"
        print_msg "二进制位置: $FRP_INSTALL_DIR/frps, $FRP_INSTALL_DIR/frpc"
    else
        print_err "安装失败: 二进制文件未找到"
        return 1
    fi
}

# ============================================================
#  systemd 服务管理
# ============================================================

create_service() {
    local role="$1"
    local config_file="$FRP_CONFIG_DIR/${role}.toml"

    cat <<EOF > /etc/systemd/system/${role}.service
[Unit]
Description=frp ${role} - https://github.com/fatedier/frp
After=network.target

[Service]
Type=simple
ExecStart=${FRP_INSTALL_DIR}/${role} -c ${config_file}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$role" >/dev/null 2>&1
    systemctl restart "$role"
}

stop_service() {
    local role="$1"
    systemctl stop "$role" >/dev/null 2>&1
    systemctl disable "$role" >/dev/null 2>&1
    rm -f /etc/systemd/system/${role}.service
    systemctl daemon-reload
}

show_service_status() {
    local role="$1"
    if systemctl is-active "$role" >/dev/null 2>&1; then
        echo -e "  运行状态: ${GREEN}运行中${NC}"
    else
        echo -e "  运行状态: ${RED}未运行${NC}"
    fi
}

# ============================================================
#  frps 服务端（公网）
# ============================================================

install_frps() {
    print_msg "正在安装 FRP 服务端..."

    local bind_port=7000
    local dashboard_port=7500
    local token
    local dashboard_user
    local dashboard_pwd
    token=$(openssl rand -hex 16)
    dashboard_user="admin_$(openssl rand -hex 4)"
    dashboard_pwd=$(openssl rand -hex 8)

    # 允许用户自定义端口
    read -e -p "绑定端口 [回车默认 7000]: " input_port
    bind_port=${input_port:-7000}
    read -e -p "面板端口 [回车默认 7500]: " input_dash
    dashboard_port=${input_dash:-7500}

    # 下载安装
    install_frp || return 1

    # 生成配置 (官方 TOML 格式)
    mkdir -p "$FRP_CONFIG_DIR"
    cat <<EOF > "$FRP_CONFIG_DIR/frps.toml"
# FRP 服务端配置
# 文档: https://github.com/fatedier/frp/blob/dev/doc/server_configures.md

bindPort = ${bind_port}

[auth]
method = "token"
token = "${token}"

[webServer]
addr = "0.0.0.0"
port = ${dashboard_port}
user = "${dashboard_user}"
password = "${dashboard_pwd}"
EOF

    # 启动服务
    create_service frps

    # 输出信息
    get_ip
    echo ""
    echo "========================================================"
    echo -e "${GREEN} FRP 服务端（公网）安装完成${NC}"
    echo "========================================================"
    echo "  客户端对接参数:"
    echo "    服务器 IP:    $ipv4_address"
    echo "    服务端口:     $bind_port"
    echo "    Token:        $token"
    echo ""
    echo "  管理面板:"
    echo "    地址:   http://$ipv4_address:$dashboard_port"
    echo "    用户名: $dashboard_user"
    echo "    密码:   $dashboard_pwd"
    echo ""
    echo "  请妥善保存以上信息！"
    echo "========================================================"
}

uninstall_frps() {
    if confirm_action "确认卸载 FRP 服务端？配置文件将被删除"; then
        stop_service frps
        rm -f "$FRP_INSTALL_DIR/frps"
        rm -f "$FRP_CONFIG_DIR/frps.toml"
        print_msg "FRP 服务端已卸载"
    fi
}

update_frps() {
    print_msg "正在更新 FRP 服务端..."
    systemctl stop frps >/dev/null 2>&1
    install_frp || return 1
    systemctl restart frps
    print_msg "FRP 服务端已更新到 v${FRP_VERSION}"
}

# ============================================================
#  frpc 客户端（无公网）
# ============================================================

install_frpc() {
    print_msg "正在安装 FRP 客户端..."

    read -e -p "请输入服务端 IP: " server_addr
    if [ -z "$server_addr" ]; then
        print_err "服务端 IP 不能为空"
        return 1
    fi
    read -e -p "服务端端口 [回车默认 7000]: " server_port
    server_port=${server_port:-7000}
    read -e -p "请输入 Token: " token
    if [ -z "$token" ]; then
        print_err "Token 不能为空"
        return 1
    fi

    # 下载安装
    install_frp || return 1

    # 生成配置 (官方 TOML 格式)
    mkdir -p "$FRP_CONFIG_DIR"
    cat <<EOF > "$FRP_CONFIG_DIR/frpc.toml"
# FRP 客户端配置
# 文档: https://github.com/fatedier/frp/blob/dev/doc/client_configures.md

serverAddr = "${server_addr}"
serverPort = ${server_port}

[auth]
method = "token"
token = "${token}"

EOF

    # 启动服务
    create_service frpc

    echo ""
    echo "========================================================"
    echo -e "${GREEN} FRP 客户端（无公网）安装完成${NC}"
    echo "========================================================"
    echo "  已对接服务端: ${server_addr}:${server_port}"
    echo "  接下来可使用「添加穿透服务」将内网服务暴露到公网"
    echo "========================================================"
}

uninstall_frpc() {
    if confirm_action "确认卸载 FRP 客户端？配置文件将被删除"; then
        stop_service frpc
        rm -f "$FRP_INSTALL_DIR/frpc"
        rm -f "$FRP_CONFIG_DIR/frpc.toml"
        print_msg "FRP 客户端已卸载"
    fi
}

update_frpc() {
    print_msg "正在更新 FRP 客户端..."
    systemctl stop frpc >/dev/null 2>&1
    install_frp || return 1
    systemctl restart frpc
    print_msg "FRP 客户端已更新到 v${FRP_VERSION}"
}

# ============================================================
#  穿透服务管理 (客户端)
# ============================================================

add_proxy() {
    if [ ! -f "$FRP_CONFIG_DIR/frpc.toml" ]; then
        print_err "请先安装 FRP 客户端"
        return 1
    fi

    read -e -p "服务名称: " proxy_name
    if [ -z "$proxy_name" ]; then
        print_err "名称不能为空"
        return 1
    fi

    read -e -p "协议类型 (tcp/udp) [回车默认 tcp]: " proxy_type
    proxy_type=${proxy_type:-tcp}

    read -e -p "内网 IP [回车默认 127.0.0.1]: " local_ip
    local_ip=${local_ip:-127.0.0.1}

    read -e -p "内网端口: " local_port
    if [ -z "$local_port" ]; then
        print_err "内网端口不能为空"
        return 1
    fi

    read -e -p "外网端口: " remote_port
    if [ -z "$remote_port" ]; then
        print_err "外网端口不能为空"
        return 1
    fi

    cat <<EOF >> "$FRP_CONFIG_DIR/frpc.toml"
[[proxies]]
name = "${proxy_name}"
type = "${proxy_type}"
localIP = "${local_ip}"
localPort = ${local_port}
remotePort = ${remote_port}

EOF

    systemctl restart frpc
    print_msg "穿透服务 [${proxy_name}] 已添加: ${local_ip}:${local_port} -> 公网:${remote_port} (${proxy_type})"
}

delete_proxy() {
    if [ ! -f "$FRP_CONFIG_DIR/frpc.toml" ]; then
        print_err "配置文件不存在"
        return 1
    fi

    echo ""
    echo "当前穿透服务列表:"
    list_proxies
    echo ""

    read -e -p "请输入要删除的服务名称: " proxy_name
    if [ -z "$proxy_name" ]; then
        print_err "名称不能为空"
        return 1
    fi

    # 使用 awk 精确删除 [[proxies]] 块
    awk -v name="$proxy_name" '
    BEGIN { skip=0; buffer="" }
    /^\[\[proxies\]\]/ {
        if (skip) { skip=0 }
        buffer=$0 "\n"
        getline
        buffer=buffer $0 "\n"
        if ($0 ~ "name = \"" name "\"") {
            skip=1
            next
        } else {
            printf "%s", buffer
            buffer=""
            next
        }
    }
    skip && /^$/ { skip=0; next }
    skip { next }
    { if (buffer != "") { printf "%s", buffer; buffer="" } print }
    END { if (buffer != "") printf "%s", buffer }
    ' "$FRP_CONFIG_DIR/frpc.toml" > "$FRP_CONFIG_DIR/frpc.toml.tmp"

    mv "$FRP_CONFIG_DIR/frpc.toml.tmp" "$FRP_CONFIG_DIR/frpc.toml"

    systemctl restart frpc
    print_msg "穿透服务 [${proxy_name}] 已删除"
}

list_proxies() {
    if [ ! -f "$FRP_CONFIG_DIR/frpc.toml" ]; then
        echo "  (无配置文件)"
        return
    fi

    local count
    count=$(grep -c '^\[\[proxies\]\]' "$FRP_CONFIG_DIR/frpc.toml" 2>/dev/null)
    if [ "$count" = "0" ] || [ -z "$count" ]; then
        echo "  (暂无穿透服务)"
        return
    fi

    printf "  %-18s %-22s %-15s %-6s\n" "名称" "内网地址" "外网端口" "协议"
    printf "  %-18s %-22s %-15s %-6s\n" "----" "--------" "--------" "----"

    awk '
    /^\[\[proxies\]\]/ { in_proxy=1; name=""; type=""; lip=""; lport=""; rport=""; next }
    in_proxy && /^name\s*=/ { gsub(/"/, "", $3); name=$3 }
    in_proxy && /^type\s*=/ { gsub(/"/, "", $3); type=$3 }
    in_proxy && /^localIP\s*=/ { gsub(/"/, "", $3); lip=$3 }
    in_proxy && /^localPort\s*=/ { lport=$3 }
    in_proxy && /^remotePort\s*=/ { rport=$3 }
    in_proxy && /^$/ {
        if (name != "") printf "  %-18s %-22s %-15s %-6s\n", name, lip":"lport, rport, type
        in_proxy=0
    }
    END {
        if (in_proxy && name != "") printf "  %-18s %-22s %-15s %-6s\n", name, lip":"lport, rport, type
    }
    ' "$FRP_CONFIG_DIR/frpc.toml"
}

edit_config() {
    local role="$1"
    local config_file="$FRP_CONFIG_DIR/${role}.toml"

    if [ ! -f "$config_file" ]; then
        print_err "配置文件不存在: $config_file"
        return 1
    fi

    if command -v nano >/dev/null 2>&1; then
        nano "$config_file"
    elif command -v vi >/dev/null 2>&1; then
        vi "$config_file"
    else
        print_err "未找到可用的文本编辑器 (nano/vi)"
        return 1
    fi

    systemctl restart "$role"
    print_msg "配置已更新，${role} 服务已重启"
}

# ============================================================
#  服务端（公网）菜单
# ============================================================

frps_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}       FRP 服务端（公网）管理${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo "  项目: https://github.com/fatedier/frp"
        echo "  许可: Apache-2.0 开源协议"

        if [ -f "$FRP_INSTALL_DIR/frps" ]; then
            echo ""
            echo -e "  安装状态: ${GREEN}已安装${NC}"
            echo "  版本: v$($FRP_INSTALL_DIR/frps --version 2>/dev/null)"
            echo "  架构: $(uname -m)"
            show_service_status frps
            if [ -f "$FRP_CONFIG_DIR/frps.toml" ]; then
                local port
                port=$(grep '^bindPort' "$FRP_CONFIG_DIR/frps.toml" 2>/dev/null | awk '{print $3}')
                local dash_port
                dash_port=$(grep '^port' "$FRP_CONFIG_DIR/frps.toml" 2>/dev/null | head -1 | awk '{print $3}')
                get_ip
                [ -n "$port" ] && echo "  绑定端口: $port"
                [ -n "$dash_port" ] && echo "  面板地址: http://$ipv4_address:$dash_port"
            fi
        else
            echo ""
            echo -e "  安装状态: ${RED}未安装${NC}"
        fi

        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────${NC}"
        echo "  1. 安装         2. 更新         3. 卸载"
        echo "  4. 编辑配置     5. 重启服务"
        echo "  0. 返回主菜单"
        echo -e "${CYAN}────────────────────────────────────────────────${NC}"
        read -e -p "  请选择: " choice

        case $choice in
            1) install_frps ;;
            2) update_frps ;;
            3) uninstall_frps ;;
            4) edit_config frps ;;
            5) systemctl restart frps && print_msg "frps 已重启" ;;
            0|*) break ;;
        esac

        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ============================================================
#  客户端（无公网）菜单
# ============================================================

frpc_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}       FRP 客户端（无公网）管理${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo "  项目: https://github.com/fatedier/frp"
        echo "  许可: Apache-2.0 开源协议"

        if [ -f "$FRP_INSTALL_DIR/frpc" ]; then
            echo ""
            echo -e "  安装状态: ${GREEN}已安装${NC}"
            echo "  版本: v$($FRP_INSTALL_DIR/frpc --version 2>/dev/null)"
            echo "  架构: $(uname -m)"
            show_service_status frpc
            if [ -f "$FRP_CONFIG_DIR/frpc.toml" ]; then
                local addr
                addr=$(grep '^serverAddr' "$FRP_CONFIG_DIR/frpc.toml" 2>/dev/null | awk -F'"' '{print $2}')
                local port
                port=$(grep '^serverPort' "$FRP_CONFIG_DIR/frpc.toml" 2>/dev/null | awk '{print $3}')
                [ -n "$addr" ] && echo "  对接服务端: ${addr}:${port}"
                echo ""
                echo "  穿透服务列表:"
                list_proxies
            fi
        else
            echo ""
            echo -e "  安装状态: ${RED}未安装${NC}"
        fi

        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────${NC}"
        echo "  1. 安装         2. 更新          3. 卸载"
        echo "  4. 添加穿透     5. 删除穿透      6. 编辑配置"
        echo "  7. 重启服务"
        echo "  0. 返回主菜单"
        echo -e "${CYAN}────────────────────────────────────────────────${NC}"
        read -e -p "  请选择: " choice

        case $choice in
            1) install_frpc ;;
            2) update_frpc ;;
            3) uninstall_frpc ;;
            4) add_proxy ;;
            5) delete_proxy ;;
            6) edit_config frpc ;;
            7) systemctl restart frpc && print_msg "frpc 已重启" ;;
            0|*) break ;;
        esac

        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ============================================================
#  主菜单
# ============================================================

main_menu() {
    check_root

    while true; do
        clear
        echo ""
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}        FRP 内网穿透管理工具${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo ""
        echo "  官方项目: https://github.com/fatedier/frp"
        echo "  当前版本: v${FRP_VERSION}"
        echo "  运行架构: $(uname -m)"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────${NC}"
        echo ""
        echo "  1. 服务端（公网）  - 部署在有公网 IP 的服务器"
        echo ""
        echo "  2. 客户端（无公网）- 部署在内网设备，连接服务端"
        echo ""
        echo "  0. 退出"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────${NC}"
        read -e -p "  请选择: " choice

        case $choice in
            1) frps_menu ;;
            2) frpc_menu ;;
            0|*) echo ""; exit 0 ;;
        esac
    done
}

# ============================================================
#  启动
# ============================================================
main_menu
