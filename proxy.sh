#!/bin/bash

# --- 颜色定义 ---
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
purple='\033[0;35m'
skyblue='\033[0;36m'
white='\033[1;91m'
re='\033[0m' # 重置颜色

# --- 辅助函数 ---

# 检查并安装软件包
install_soft() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${yellow}正在安装 $1...${re}"
        if command -v apt-get &> /dev/null; then
            apt-get update -y > /dev/null 2>&1
            apt-get install -y $1
        elif command -v yum &> /dev/null; then
            yum install -y $1
        elif command -v dnf &> /dev/null; then
            dnf install -y $1
        elif command -v apk &> /dev/null; then
            apk add $1
        else
            echo -e "${red}错误: 未知的包管理器，请手动安装 $1 ${re}"
            exit 1
        fi
    fi
}

# --- 核心功能：端口占用检测 (仅使用 netstat) ---
check_port() {
    local port=$1
    # 确保 netstat 已安装
    if ! command -v netstat &> /dev/null; then
        install_soft net-tools
    fi

    # 使用 netstat 检测 TCP 和 UDP
    if netstat -tuln | grep -qE ":$port\b"; then
        return 0 # 返回 0 代表被占用
    else
        return 1 # 返回 1 代表空闲
    fi
}

# 按任意键继续
press_any_key_to_continue() {
    echo -e "${skyblue}---------------------------------------------------------${re}"
    read -n 1 -s -r -p "按任意键返回上一级菜单..."
}

# 检测服务器架构
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "x86_64-unknown-linux-gnu"
            ;;
        i686)
            echo "i686-unknown-linux-gnu"
            ;;
        armv7l)
            echo "armv7-unknown-linux-gnueabi"
            ;;
        aarch64)
            echo "aarch64-unknown-linux-gnu"
            ;;
        *)
            echo -e "${red}不支持的架构: $arch${re}"
            exit 1
            ;;
    esac
}

# --- Tuic-V5 功能实现 ---

install_tuic() {
    install_soft jq
    install_soft curl
    install_soft openssl
    install_soft wget
    install_soft net-tools # 确保 netstat 可用

    echo -e "${green}Tuic V5 正在安装中，请稍候...${re}"

    server_arch=$(detect_arch)
    latest_release_version=$(curl -s "https://api.github.com/repos/etjec4/tuic/releases/latest" | jq -r ".tag_name")

    # 构建下载URL
    download_url="https://github.com/etjec4/tuic/releases/download/$latest_release_version/$latest_release_version-$server_arch"

    # 下载二进制文件
    mkdir -p /root/tuic
    cd /root/tuic
    echo -e "${yellow}正在下载 Tuic 二进制文件...${re}"
    wget -O tuic-server -q "$download_url"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}错误: 下载 tuic 二进制文件失败！${re}"
        press_any_key_to_continue
        return
    fi
    chmod 755 tuic-server

    # 生成自签名证书
    echo -e "${yellow}正在生成自签名证书...${re}"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /root/tuic/server.key -out /root/tuic/server.crt -subj "/CN=bing.com" -days 36500

    # 提示用户输入端口和密码
    echo ""
    local port
    read -p $'\033[1;35m请输入 Tuic 端口 (10000-65000, 回车使用随机端口): \033[0m' port
    [ -z "$port" ] && port=$(shuf -i 10000-65000 -n 1)

    # 循环检查端口是否被占用
    while check_port "$port"; do
        echo -e "${red}端口 ${port} 已被占用，请更换端口重试！${re}"
        read -p $'\033[1;35m请输入 Tuic 端口 (10000-65000, 回车使用随机端口): \033[0m' port
        [ -z "$port" ] && port=$(shuf -i 10000-65000 -n 1)
    done
    echo -e "${green}Tuic 端口: ${port}${re}"

    local password
    read -p $'\033[1;35m请输入您想设定的密码 (回车使用随机密码): \033[0m' password
    [ -z "$password" ] && password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)
    echo -e "${green}Tuic 密码: ${password}${re}"

    # 生成 UUID
    UUID=$(openssl rand -hex 16 | awk '{print substr($0,1,8)"-"substr($0,9,4)"-"substr($0,13,4)"-"substr($0,17,4)"-"substr($0,21,12)}')
    echo -e "${green}Tuic UUID: ${UUID}${re}"

    if [ -z "$UUID" ]; then
        echo -e "${red}错误: 生成 UUID 失败！${re}"
        press_any_key_to_continue
        return
    fi

    # 创建 config.json
    cat > config.json <<EOL
{
  "server": "[::]:$port",
  "users": {
    "$UUID": "$password"
  },
  "certificate": "/root/tuic/server.crt",
  "private_key": "/root/tuic/server.key",
  "congestion_control": "bbr",
  "alpn": ["h3", "spdy/3.1"],
  "udp_relay_ipv6": true,
  "zero_rtt_handshake": false,
  "dual_stack": true,
  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_idle_time": "10s",
  "max_external_packet_size": 1500,
  "gc_interval": "3s",
  "gc_lifetime": "15s",
  "log_level": "warn"
}
EOL

    # --- 针对 Alpine 和 Systemd 的不同启动逻辑 ---
    if [ -f "/etc/alpine-release" ]; then
        # Alpine 系统使用 nohup 后台运行
        echo -e "${yellow}检测到 Alpine 系统，使用 nohup 启动 Tuic...${re}"
        nohup /root/tuic/tuic-server -c /root/tuic/config.json > /root/tuic/tuic.log 2>&1 &
        echo -e "${green}Tuic 已在后台启动。${re}"
    else
        # 其他系统 (Debian/Ubuntu/CentOS) 使用 Systemd
        cat > /etc/systemd/system/tuic.service <<EOL
[Unit]
Description=tuic service
Documentation=TUIC v5
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root/tuic
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/root/tuic/tuic-server -c /root/tuic/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOL
        systemctl daemon-reload
        systemctl enable tuic > /dev/null 2>&1
        systemctl start tuic
        systemctl restart tuic
    fi

    # 获取公共 IP
    public_ip=$(curl -s https://api.ipify.org)

    # 获取 ISP 信息
    isp=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')

    echo -e "${green}Tuic V5 安装成功！配置信息如下：${re}"
    echo -e "${white}V2rayN、NekoBox 客户端配置链接: ${re}"
    echo -e "${skyblue}tuic://$UUID:$password@$public_ip:$port?congestion_control=bbr&alpn=h3&sni=www.bing.com&udp_relay_mode=native&allow_insecure=1#$isp${re}"
    echo ""
    press_any_key_to_continue
}

change_tuic_config() {
    install_soft jq
    install_soft net-tools

    echo -e "${yellow}正在更改 Tuic 配置...${re}"

    local config_file="/root/tuic/config.json"
    if [ ! -f "$config_file" ]; then
        echo -e "${red}错误: Tuic 配置文件 $config_file 不存在，请先安装 Tuic.${re}"
        press_any_key_to_continue
        return
    fi

    # 获取当前UUID和密码
    local current_uuid=$(jq -r '.users | to_entries[0].key' "$config_file" 2>/dev/null)
    local current_password=$(jq -r ".users[\"$current_uuid\"]" "$config_file" 2>/dev/null)
    local current_port=$(jq -r '.server' "$config_file" | awk -F":" '{print $NF}' | tr -d '"')

    # 更改 UUID
    local new_uuid
    read -p $'\033[1;35m请输入新的 UUID (或回车使用随机 UUID，当前: '$current_uuid'): \033[0m' new_uuid
    [ -z "$new_uuid" ] && new_uuid=$(openssl rand -hex 16 | awk '{print substr($0,1,8)"-"substr($0,9,4)"-"substr($0,13,4)"-"substr($0,17,4)"-"substr($0,21,12)}')

    jq --arg old_uuid "$current_uuid" --arg new_uuid "$new_uuid" --arg password "$current_password" \
        '.users = { ($new_uuid): $password }' "$config_file" > temp.json && mv temp.json "$config_file"
    echo -e "${green}新的 UUID: $new_uuid${re}"

    # 更改端口
    local new_port
    read -p $'\033[1;35m请输入新的端口 (或回车使用随机端口，当前: '$current_port'): \033[0m' new_port
    [ -z "$new_port" ] && new_port=$(shuf -i 10000-65000 -n 1)

    # 检测端口占用
    while check_port "$new_port"; do
        echo -e "${red}端口 ${new_port} 已被占用，请更换端口重试！${re}"
        read -p $'\033[1;35m请输入新的端口 (或回车使用随机端口): \033[0m' new_port
        [ -z "$new_port" ] && new_port=$(shuf -i 10000-65000 -n 1)
    done

    sed -i "s/\"\[::\]:[0-9]\+\"/\"\[::\]:$new_port\"/" "$config_file"
    echo -e "${green}新的 PORT: $new_port${re}"

    # --- 重启服务 (兼容 Alpine) ---
    if [ -f "/etc/alpine-release" ]; then
        echo -e "${yellow}正在重启 Tuic (Alpine)...${re}"
        pkill -f tuic-server > /dev/null 2>&1
        sleep 1
        nohup /root/tuic/tuic-server -c /root/tuic/config.json > /root/tuic/tuic.log 2>&1 &
    else
        systemctl daemon-reload
        systemctl restart tuic
    fi
    echo -e "${green}Tuic 配置已更新并服务已重启。${re}"

    # 重新获取公共 IP 和 ISP
    public_ip=$(curl -s https://api.ipify.org)
    isp=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')

    echo -e "${white}更新后的客户端配置链接: ${re}"
    echo -e "${skyblue}tuic://$new_uuid:$current_password@$public_ip:$new_port?congestion_control=bbr&alpn=h3&sni=www.bing.com&udp_relay_mode=native&allow_insecure=1#$isp${re}"
    echo ""
    press_any_key_to_continue
}

uninstall_tuic() {
    echo -e "${yellow}正在卸载 Tuic V5...${re}"
    
    # --- 停止服务 (兼容 Alpine) ---
    if [ -f "/etc/alpine-release" ]; then
        pkill -f tuic-server > /dev/null 2>&1
    else
        systemctl stop tuic > /dev/null 2>&1
        systemctl disable tuic > /dev/null 2>&1
        rm -f /etc/systemd/system/tuic.service
        systemctl daemon-reload
    fi
    
    rm -rf /root/tuic
    echo -e "${green}Tuic V5 已卸载成功！${re}"
    press_any_key_to_continue
}

# --- Alpine 系统环境预处理 ---
if [ -f "/etc/alpine-release" ]; then
    if ! command -v bash &> /dev/null || ! command -v openssl &> /dev/null || ! command -v netstat &> /dev/null; then
        echo -e "${yellow}检测到 Alpine 系统，正在安装基础依赖 (bash, openssl, net-tools)...${re}"
        if command -v apk &> /dev/null; then
            apk update > /dev/null 2>&1
            apk add bash openssl net-tools > /dev/null 2>&1
            echo -e "${green}基础依赖安装完成。${re}"
        else
            echo -e "${red}错误: 未找到 apk 包管理器，无法自动安装依赖。${re}"
        fi
    fi
fi

# --- 主菜单 ---
while true; do
      clear
      echo -e "${purple}▶ 节点搭建脚本合集${re}"
      echo -e "${green}---------------------------------------------------------${re}"
      echo -e "${cyan} 1. Hysteria2一键脚本        2. Reality一键脚本${re}"
      echo -e "${cyan} 3. Tuic-V5一键脚本${re}"
      echo -e "${yellow}---------------------------------------------------------${re}"
      echo -e "${skyblue} 0. 退出脚本${re}"
      echo "---------------"
      read -p $'\033[1;91m请输入你的选择: \033[0m' main_choice
      case $main_choice in
        1) # Hysteria2 子菜单
        while true; do
        clear
          echo "--------------"
          echo -e "${green}1.安装Hysteria2${re}"
          echo -e "${red}2.卸载Hysteria2${re}"
          echo -e "${yellow}3.更换Hysteria2端口${re}"
          echo "--------------"
          echo -e "${skyblue}0. 返回上一级菜单${re}"
          echo "--------------"
          read -p $'\033[1;91m请输入你的选择: \033[0m' sub_choice
            case $sub_choice in
                1) # 安装Hysteria2
                    clear
                    install_soft net-tools
                    read -p $'\033[1;35m请输入Hysteria2节点端口(nat小鸡请输入可用端口范围内的端口),回车跳过则使用随机端口：\033[0m' port
                    if [[ -z "$port" ]]; then
                        port=$(shuf -i 2000-65000 -n 1)
                        echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                    fi

                    while check_port "$port"; do
                        echo -e "${red}${port}端口已经被其他程序占用，请更换端口重试${re}"
                        read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车将使用随机端口）：\033[0m' port
                        if [[ -z "$port" ]]; then
                            port=$(shuf -i 2000-65000 -n 1)
                            echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                        fi
                    done

                    if [ -f "/etc/alpine-release" ]; then
                        SERVER_PORT=$port bash -c "$(curl -L https://raw.githubusercontent.com/eooce/scripts/master/containers-shell/hy2.sh)"
                    else
                        HY2_PORT=$port bash -c "$(curl -L https://raw.githubusercontent.com/eooce/scripts/master/Hysteria2.sh)"
                    fi
                    press_any_key_to_continue
                    break
                    ;;
                2) # 卸载Hysteria2
                    if [ -f "/etc/alpine-release" ]; then
                        pkill -f 'web'
                        cd && rm -rf web npm server.crt server.key config.yaml
                        echo -e "${green}Hysteria2 (Alpine) 已卸载${re}"
                    else
                        systemctl stop hysteria-server.service
                        systemctl disable hysteria-server.service
                        rm -f /usr/local/bin/hysteria
                        rm -f /etc/systemd/system/hysteria-server.service
                        rm -rf /etc/hysteria
                        systemctl daemon-reload
                        echo -e "${green}Hysteria2 (Systemd) 已卸载${re}"
                    fi
                    press_any_key_to_continue
                    break
                    ;;
                3) # 更换Hysteria2端口
                    clear
                    install_soft net-tools
                    read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                    [[ -z "$new_port" ]] && new_port=$(shuf -i 2000-65000 -n 1)

                    while check_port "$new_port"; do
                        echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                        read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                        [[ -z "$new_port" ]] && new_port=$(shuf -i 2000-65000 -n 1)
                    done

                    if [ -f "/etc/alpine-release" ]; then
                        sed -i "s/^listen: :[0-9]*/listen: :$new_port/" /root/config.yaml
                        pkill -f 'web'
                        nohup ./web server config.yaml >/dev/null 2>&1 &
                    else
                        clear
                        sed -i "s/^listen: :[0-9]*/listen: :$new_port/" /etc/hysteria/config.yaml
                        systemctl restart hysteria-server.service
                    fi
                    echo -e "${green}Hysteria2端口已更换成$new_port,请手动更改客户端配置!${re}"
                    press_any_key_to_continue
                    break
                    ;;
                0)
                    break
                    ;;
                *)
                    echo -e "${red}无效的输入!${re}"
                    sleep 1
                    ;;
            esac
        done
        ;;
		2) # Reality 子菜单
        while true; do
        clear
          echo "--------------"
          echo -e "${green}1.安装Reality${re}"
          echo -e "${red}2.卸载Reality${re}"
          echo -e "${yellow}3.更换Reality端口${re}"
          echo "--------------"
          echo -e "${skyblue}0. 返回上一级菜单${re}"
          echo "--------------"
          read -p $'\033[1;91m请输入你的选择: \033[0m' sub_choice
            case $sub_choice in
                1) # 安装Reality
                    clear
                    install_soft net-tools
                    read -p $'\033[1;35m请输入reality节点端口(nat小鸡请输入可用端口范围内的端口),回车跳过则使用随机端口：\033[0m' port
                    if [[ -z "$port" ]]; then
                        port=$(shuf -i 2000-65000 -n 1)
                        echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                    fi

                    while check_port "$port"; do
                        echo -e "${red}${port}端口已经被其他程序占用，请更换端口重试${re}"
                        read -p $'\033[1;35m设置 reality 端口[1-65535]（回车跳过将使用随机端口）：\033[0m' port
                        if [[ -z "$port" ]]; then
                            port=$(shuf -i 2000-65000 -n 1)
                            echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                        fi
                    done

                    if [ -f "/etc/alpine-release" ]; then
                        PORT=$port bash -c "$(curl -L https://raw.githubusercontent.com/eooce/scripts/master/test.sh)"
                    else
                        PORT=$port bash -c "$(curl -L https://raw.githubusercontent.com/eooce/xray-reality/master/reality.sh)"
                    fi
                    press_any_key_to_continue
                    break
                    ;;
                2) # 卸载Reality
                    if [ -f "/etc/alpine-release" ]; then
                        pkill -f 'web'
                        cd && rm -rf app
                        echo -e "${green}Reality (Alpine) 已卸载${re}"
                    else
                        systemctl stop xray
                        systemctl disable xray
                        rm -f /usr/local/bin/xray
                        rm -f /etc/systemd/system/xray.service
                        rm -f /etc/systemd/system/xray@.service
                        rm -rf /usr/local/etc/xray
                        rm -rf /usr/local/share/xray
                        rm -rf /var/log/xray /var/lib/xray
                        systemctl daemon-reload
                        echo -e "${green}Reality (Systemd) 已卸载${re}"
                    fi
                    press_any_key_to_continue
                    break
                    ;;
                3) # 更换Reality端口
                    clear
                    install_soft jq
                    install_soft net-tools
                    read -p $'\033[1;35m设置 reality 端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                    [[ -z "$new_port" ]] && new_port=$(shuf -i 2000-65000 -n 1)

                    while check_port "$new_port"; do
                        echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                        read -p $'\033[1;35m设置reality端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                        [[ -z "$new_port" ]] && new_port=$(shuf -i 2000-65000 -n 1)
                    done

                    if [ -f "/etc/alpine-release" ]; then
                        jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' /root/app/config.json > tmp.json && mv tmp.json /root/app/config.json
                        pkill -f 'web'
                        cd ~/app
                        nohup ./web -c config.json >/dev/null 2>&1 &
                    else
                        clear
                        jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' /usr/local/etc/xray/config.json > tmp.json && mv tmp.json /usr/local/etc/xray/config.json
                        systemctl restart xray.service
                    fi
                    echo -e "${green}Reality端口已更换成$new_port,请手动更改客户端配置!${re}"
                    press_any_key_to_continue
                    break
                    ;;
                0)
                    break
                    ;;
                *)
                    echo -e "${red}无效的输入!${re}"
                    sleep 1
                    ;;
            esac
        done
        ;;
      3) # Tuic-V5 子菜单
        while true; do
            clear
            echo "--------------"
            echo -e "${green}1. 安装或重新安装 Tuic-V5${re}"
            echo -e "${yellow}2. 更改 Tuic-V5 配置 (UUID/端口)${re}"
            echo -e "${red}3. 卸载 Tuic-V5${re}"
            echo "--------------"
            echo -e "${skyblue}0. 返回上一级菜单${re}"
            echo "--------------"
            read -p $'\033[1;91m请输入你的选择: \033[0m' tuic_sub_choice
            case $tuic_sub_choice in
                1)
                    # 检查是否已安装，如果已安装则提供重新安装选项
                    if [ -d "/root/tuic" ]; then
                        echo -e "${yellow}检测到 Tuic 已安装.${re}"
                        read -p $'\033[1;35m您想重新安装吗? (y/N): \033[0m' reinstall_confirm
                        if [[ "$reinstall_confirm" =~ ^[Yy]$ ]]; then
                            uninstall_tuic # 先卸载
                            install_tuic   # 再安装
                        else
                            echo -e "${yellow}取消重新安装.${re}"
                        fi
                    else
                        install_tuic
                    fi
                    break
                    ;;
                2)
                    change_tuic_config
                    break
                    ;;
                3)
                    uninstall_tuic
                    break
                    ;;
                0)
                    break
                    ;;
                *)
                    echo -e "${red}无效的输入!${re}"
                    sleep 1
                    ;;
            esac
        done
        ;;
      0)
        echo "退出脚本。"
        exit 0
        ;;
      *)
        echo -e "${red}无效的输入!${re}"
        sleep 1
        ;;
    esac
done
