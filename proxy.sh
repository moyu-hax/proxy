#!/bin/bash

# --- 颜色定义 (问题 1 修正) ---
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
purple='\033[0;35m'
skyblue='\033[0;36m'
white='\033[1;37m'
re='\033[0m' # 重置颜色

# --- 辅助函数 ---

# 检查并安装软件包 (问题 3 修正)
install_soft() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${yellow}正在安装 $1...${re}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y $1
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

# 按任意键继续 (问题 1 修正 - 实现 break_end 的功能)
press_any_key_to_continue() {
    echo -e "${skyblue}---------------------------------------------------------${re}"
    read -n 1 -s -r -p "按任意键返回上一级菜单..."
}

# --- 主菜单 ---
while true; do
      clear
      echo -e "${purple}▶ 节点搭建脚本合集${re}"
      echo -e "${green}---------------------------------------------------------${re}"
      echo -e "${white} 1. Hysteria2一键脚本        2. Reality一键脚本${re}"
      echo -e "${yellow}---------------------------------------------------------${re}"
      echo -e "${skyblue} 0. 退出脚本${re}" # 优化：主菜单的0通常是退出
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
                    read -p $'\033[1;35m请输入Hysteria2节点端口(nat小鸡请输入可用端口范围内的端口),回车跳过则使用随机端口：\033[0m' port
                    # (问题 2 修正) 如果为空，则分配随机端口
                    if [[ -z "$port" ]]; then
                        port=$(shuf -i 2000-65000 -n 1)
                        echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                    fi

                    # 循环检查端口是否被占用
                    until [[ -z $(netstat -tuln | grep -w udp | awk '{print $4}' | sed 's/.*://g' | grep -w "$port") ]]; do
                        echo -e "${red}${port}端口已经被其他程序占用，请更换端口重试${re}"
                        read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车将使用随机端口）：\033[0m' port
                        # (问题 2 修正) 修复逻辑，回车使用随机端口
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
                    press_any_key_to_continue && break
                    ;;
                2) # 卸载Hysteria2
                    if [ -f "/etc/alpine-release" ]; then
                        pkill -f '[w]eb'
                        pkill -f '[n]pm'
                        cd && rm -rf web npm server.crt server.key config.yaml
                    else
                        systemctl stop hysteria-server.service
                        systemctl disable hysteria-server.service
                        rm -f /usr/local/bin/hysteria
                        rm -f /etc/systemd/system/hysteria-server.service
                        rm -rf /etc/hysteria
                        systemctl daemon-reload
                    fi
                    clear
                    echo -e "${green}Hysteria2已卸载${re}"
                    press_any_key_to_continue && break
                    ;;
                3) # 更换Hysteria2端口
                    clear
                    read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                    [[ -z "$new_port" ]] && new_port=$(shuf -i 2000-65000 -n 1)

                    until [[ -z $(netstat -tuln | grep -w udp | awk '{print $4}' | sed 's/.*://g' | grep -w "$new_port") ]]; do
                        echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                        read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                        [[ -z "$new_port" ]] && new_port=$(shuf -i 2000-65000 -n 1)
                    done

                    if [ -f "/etc/alpine-release" ]; then
                        sed -i "s/^listen: :[0-9]*/listen: :$new_port/" /root/config.yaml
                        pkill -f '[w]eb'
                        nohup ./web server config.yaml >/dev/null 2>&1 &
                    else
                        clear
                        sed -i "s/^listen: :[0-9]*/listen: :$new_port/" /etc/hysteria/config.yaml
                        systemctl restart hysteria-server.service
                    fi
                    echo -e "${green}Hysteria2端口已更换成$new_port,请手动更改客户端配置!${re}"
                    press_any_key_to_continue && break
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
                    install_soft lsof # 使用通用安装函数
                    clear
                    read -p $'\033[1;35m请输入reality节点端口(nat小鸡请输入可用端口范围内的端口),回车跳过则使用随机端口：\033[0m' port
                    # (问题 2 修正) 如果为空，则分配随机端口
                    if [[ -z "$port" ]]; then
                        port=$(shuf -i 2000-65000 -n 1)
                        echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                    fi

                    until [[ -z $(lsof -i :$port 2>/dev/null) ]]; do
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
                    press_any_key_to_continue && break
                    ;;
                2) # 卸载Reality
                    if [ -f "/etc/alpine-release" ]; then
                        pkill -f '[w]eb'
                        pkill -f '[n]pm'
                        cd && rm -rf app
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
                    fi
                    clear
                    echo -e "\e[1;32mReality已卸载\033[0m"
                    press_any_key_to_continue && break
                    ;;
                3) # 更换Reality端口
                    clear
                    install_soft jq # 使用通用安装函数
                    read -p $'\033[1;35m设置 reality 端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                    [[ -z "$new_port" ]] && new_port=$(shuf -i 2000-65000 -n 1)

                    until [[ -z $(lsof -i :$new_port 2>/dev/null) ]]; do
                        echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                        read -p $'\033[1;35m设置reality端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                        [[ -z "$new_port" ]] && new_port=$(shuf -i 2000-65000 -n 1)
                    done

                    if [ -f "/etc/alpine-release" ]; then
                        jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' /root/app/config.json > tmp.json && mv tmp.json /root/app/config.json
                        pkill -f '[w]eb'
                        cd ~/app
                        nohup ./web -c config.json >/dev/null 2>&1 &
                    else
                        clear
                        jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' /usr/local/etc/xray/config.json > tmp.json && mv tmp.json /usr/local/etc/xray/config.json
                        systemctl restart xray.service
                    fi
                    echo -e "${green}Reality端口已更换成$new_port,请手动更改客户端配置!${re}"
                    press_any_key_to_continue && break
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
