while true; do
      clear
      echo -e "${purple}▶ 节点搭建脚本合集${re}"
      echo -e "${green}---------------------------------------------------------${re}"
      echo -e "${white} 1. Hysteria2一键脚本        2. Reality一键脚本${re}"
      echo -e "${yellow}---------------------------------------------------------${re}"
      echo -e "${skyblue} 0. 返回主菜单${re}"
      echo "---------------"
      read -p $'\033[1;91m请输入你的选择: \033[0m' sub_choice   
      case $sub_choice in
        1)
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
                1)
                  clear
                    read -p $'\033[1;35m请输入Hysteria2节点端口(nat小鸡请输入可用端口范围内的端口),回车跳过则使用随机端口：\033[0m' port
                    [[ -z $port ]]
                    until [[ -z $(netstat -tuln | grep -w udp | awk '{print $4}' | sed 's/.*://g' | grep -w "$port") ]]; do
                        if [[ -n $(netstat -tuln | grep -w udp | awk '{print $4}' | sed 's/.*://g' | grep -w "$port") ]]; then
                            echo -e "${red}${port}端口已经被其他程序占用，请更换端口重试${re}"
                            read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车将使用随机端口）：\033[0m' port
                            [[ -z $HY2_PORT ]] && port=8880
                        fi
                    done
                    if [ -f "/etc/alpine-release" ]; then
                        SERVER_PORT=$port bash -c "$(curl -L https://raw.githubusercontent.com/eooce/scripts/master/containers-shell/hy2.sh)"
                    else
                        HY2_PORT=$port bash -c "$(curl -L https://raw.githubusercontent.com/eooce/scripts/master/Hysteria2.sh)"
                    fi
                    sleep 1
                    break_end

                    ;;
                2)
                    if [ -f "/etc/alpine-release" ]; then
                        pkill -f '[w]eb'
                        pkill -f '[n]pm'
                        cd && rm -rf web npm server.crt server.key config.yaml
                    else
                        systemctl stop hysteria-server.service
                        rm /usr/local/bin/hysteria
                        rm /etc/systemd/system/hysteria-server.service
                        rm /etc/hysteria/config.yaml
                        sudo systemctl daemon-reload
                        clear
                    fi
                    echo -e "${green}Hysteria2已卸载${re}"
                    break_end
                    ;;
                3)
                    clear
                        read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                        [[ -z $new_port ]] && new_port=$(shuf -i 2000-65000 -n 1)
                        until [[ -z $(netstat -tuln | grep -w udp | awk '{print $4}' | sed 's/.*://g' | grep -w "$new_port") ]]; do
                            if [[ -n $(netstat -tuln | grep -w udp | awk '{print $4}' | sed 's/.*://g' | grep -w "$new_port") ]]; then
                                echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                                read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                                [[ -z $new_port ]] && new_port=$(shuf -i 2000-65000 -n 1)
                            fi
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
                        sleep 1   
                        break_end
                    ;;

                0)
                    break

                    ;;                   
                *)
                    echo -e "${red}无效的输入!${re}"
                    ;;
            esac  
        done
        ;;     
		2)
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
                1)
                  clear
                    install lsof
                    clear
                    read -p $'\033[1;35m请输入reality节点端口(nat小鸡请输入可用端口范围内的端口),回车跳过则使用随机端口：\033[0m' port
                    [[ -z $port ]]
                    until [[ -z $(lsof -i :$port 2>/dev/null) ]]; do
                        if [[ -n $(lsof -i :$port 2>/dev/null) ]]; then
                            echo -e "${red}${port}端口已经被其他程序占用，请更换端口重试${re}"
                            read -p $'\033[1;35m设置 reality 端口[1-65535]（回车跳过将使用随机端口）：\033[0m' port
                            [[ -z $port ]] && port=$(shuf -i 2000-65000 -n 1)
                        fi
                    done
                    if [ -f "/etc/alpine-release" ]; then
                        PORT=$port bash -c "$(curl -L https://raw.githubusercontent.com/eooce/scripts/master/test.sh)"
                    else
                        PORT=$port bash -c "$(curl -L https://raw.githubusercontent.com/eooce/xray-reality/master/reality.sh)"
                    fi
                    sleep 1
                    break_end
                    ;;
                2)
                if [ -f "/etc/alpine-release" ]; then
                    pkill -f '[w]eb'
                    pkill -f '[n]pm'
                    cd && rm -rf app
                    clear
                else
                    sudo systemctl stop xray
                    sudo rm /usr/local/bin/xray
                    sudo rm /etc/systemd/system/xray.service
                    sudo rm /usr/local/etc/xray/config.json
                    sudo rm /usr/local/share/xray/geoip.dat
                    sudo rm /usr/local/share/xray/geosite.dat
                    sudo rm /etc/systemd/system/xray@.service

                    # Reload the systemd daemon
                    sudo systemctl daemon-reload

                    # Remove any leftover Xray files or directories
                    sudo rm -rf /var/log/xray /var/lib/xray
                    clear
                  fi

                    echo -e "\e[1;32mReality已卸载\033[0m"
                    break_end
                    ;;
                3)
                    clear
                        read -p $'\033[1;35m设置 reality 端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                        [[ -z $new_port ]] && new_port=$(shuf -i 2000-65000 -n 1)
                        until [[ -z $(lsof -i :$new_port 2>/dev/null) ]]; do
                            if [[ -n $(lsof -i :$new_port 2>/dev/null) ]]; then
                                echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                                read -p $'\033[1;35m设置reality端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                                [[ -z $new_port ]] && new_port=$(shuf -i 2000-65000 -n 1)
                            fi
                        done
                        install jq 
                        if [ -f "/etc/alpine-release" ]; then
                            jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' /root/app/config.json > tmp.json && mv tmp.json /root/app/config.json
                            pkill -f '[w]eb'
                            cd ~ && cd app
                            nohup ./web -c config.json >/dev/null 2>&1 &
                        else
                            clear
                            jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' /usr/local/etc/xray/config.json > tmp.json && mv tmp.json /usr/local/etc/xray/config.json
                            systemctl restart xray.service
                        fi
                        echo -e "${green}Reality端口已更换成$new_port,请手动更改客户端配置!${re}"
                        sleep 1   
                        break_end
                    ;;
                0)
                    break

                    ;;
                *)
                    echo -e "${red}无效的输入!${re}"
                    ;;
            esac  
        done
        ;;
