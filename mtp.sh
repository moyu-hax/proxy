#!/bin/bash

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

# 检测并安装必要依赖
install_dependencies() {
    if command -v apk &> /dev/null; then
        yellow "检测到 Alpine 系统，正在安装依赖..."
        apk update >/dev/null 2>&1
        apk add --no-cache bash curl wget coreutils jq >/dev/null 2>&1
        green "依赖安装完成"
    elif command -v apt-get &> /dev/null; then
        yellow "检测到 Debian/Ubuntu 系统，检查依赖..."
        apt-get update >/dev/null 2>&1
        apt-get install -y curl wget jq >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        yellow "检测到 CentOS/RHEL 系统，检查依赖..."
        yum install -y curl wget jq >/dev/null 2>&1
    fi
}

HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

# 兼容性处理 md5sum
if command -v md5sum &> /dev/null; then
    export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)}
elif command -v md5 &> /dev/null; then
    export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5 | head -c 32)}
else
    export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | sha256sum | head -c 32)}
fi

WORKDIR="$HOME/mtp" && mkdir -p "$WORKDIR"
pgrep -x mtg > /dev/null && pkill -9 mtg >/dev/null 2>&1

check_port () {
  port_list=$(devil port list)
  tcp_ports=$(echo "$port_list" | grep -c "tcp")
  udp_ports=$(echo "$port_list" | grep -c "udp")

  if [[ $tcp_ports -lt 1 ]]; then
      red "没有可用的TCP端口,正在调整..."

      if [[ $udp_ports -ge 3 ]]; then
          udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
          devil port del udp $udp_port_to_delete
          green "已删除udp端口: $udp_port_to_delete"
      fi

      while true; do
          tcp_port=$(shuf -i 10000-65535 -n 1)
          result=$(devil port add tcp $tcp_port 2>&1)
          if [[ $result == *"Ok"* ]]; then
              green "已添加TCP端口: $tcp_port"
              tcp_port1=$tcp_port
              break
          else
              yellow "端口 $tcp_port 不可用，尝试其他端口..."
          fi
      done

  else
      tcp_ports=$(echo "$port_list" | awk '/tcp/ {print $1}')
      tcp_port1=$(echo "$tcp_ports" | sed -n '1p')
  fi
  devil binexec on >/dev/null 2>&1
  MTP_PORT=$tcp_port1
  green "使用 $MTP_PORT 作为TG代理端口"
}

get_ip() {
IP_LIST=($(devil vhost list | awk '/^[0-9]+/ {print $1}'))
API_URL="https://status.eooce.com/api"
IP1=""; IP2=""; IP3=""
AVAILABLE_IPS=()

for ip in "${IP_LIST[@]}"; do
    RESPONSE=$(curl -s --max-time 2 "${API_URL}/${ip}")
    if [[ -n "$RESPONSE" ]] && [[ $(echo "$RESPONSE" | jq -r '.status') == "Available" ]]; then
        AVAILABLE_IPS+=("$ip")
    fi
done

[[ ${#AVAILABLE_IPS[@]} -ge 1 ]] && IP1=${AVAILABLE_IPS[0]}
[[ ${#AVAILABLE_IPS[@]} -ge 2 ]] && IP2=${AVAILABLE_IPS[1]}
[[ ${#AVAILABLE_IPS[@]} -ge 3 ]] && IP3=${AVAILABLE_IPS[2]}

if [[ -z "$IP1" ]]; then
    red "所有IP都被墙, 请更换服务器安装"
    exit 1
fi
}

download_run(){
    if [ -e "${WORKDIR}/mtg" ]; then
        cd ${WORKDIR} && chmod +x mtg
        nohup ./mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
    else
        mtg_url="https://github.com/eooce/test/releases/download/freebsd/mtg-freebsd-amd64"
        wget -q -O "${WORKDIR}/mtg" "$mtg_url"

        if [ -e "${WORKDIR}/mtg" ]; then
            cd ${WORKDIR} && chmod +x mtg
            nohup ./mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
        fi
    fi
}

generate_info() {
purple "\n分享链接:\n"
LINKS=""
[[ -n "$IP1" ]] && LINKS+="tg://proxy?server=$IP1&port=$MTP_PORT&secret=$SECRET"
[[ -n "$IP2" ]] && LINKS+="\n\ntg://proxy?server=$IP2&port=$MTP_PORT&secret=$SECRET"
[[ -n "$IP3" ]] && LINKS+="\n\ntg://proxy?server=$IP3&port=$MTP_PORT&secret=$SECRET"

green "$LINKS\n"
echo -e "$LINKS" > link.txt

cat > ${WORKDIR}/restart.sh <<EOF
#!/bin/bash

pkill mtg
cd ~ && cd ${WORKDIR}
nohup ./mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
EOF
chmod +x ${WORKDIR}/restart.sh
}

download_mtg(){
# 改进的架构检测
cmd=$(uname -m)
case "$cmd" in
    x86_64|amd64)
        arch="amd64"
        ;;
    aarch64|arm64)
        arch="arm64"
        ;;
    armv7l|armv7)
        arch="arm"
        ;;
    *)
        yellow "未知架构 $cmd，默认使用 amd64"
        arch="amd64"
        ;;
esac

green "检测到系统架构: $arch"

# 尝试多个下载源
download_success=false
urls=(
    "https://$arch.ssss.nyc.mn/mtg-linux-$arch"
    "https://github.com/9seconds/mtg/releases/latest/download/mtg-linux-$arch"
)

for url in "${urls[@]}"; do
    yellow "尝试从 $url 下载..."
    if wget -q --timeout=10 -O "${WORKDIR}/mtg" "$url"; then
        if [ -s "${WORKDIR}/mtg" ]; then
            download_success=true
            green "下载成功"
            break
        fi
    fi
done

if [ "$download_success" = false ]; then
    red "下载失败，请检查网络连接"
    exit 1
fi

export PORT=${PORT:-$(shuf -i 2000-10000 -n 1)}
export MTP_PORT=$(($PORT + 1))

if [ -e "${WORKDIR}/mtg" ]; then
    cd ${WORKDIR} && chmod +x mtg

    # 检查是否可执行
    if ! ./mtg --help >/dev/null 2>&1; then
        red "mtg 二进制文件无法执行，可能架构不匹配"
        exit 1
    fi

    nohup ./mtg run -b 0.0.0.0:$PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
    sleep 2

    if pgrep -x mtg > /dev/null; then
        green "MTG 代理启动成功"
    else
        red "MTG 代理启动失败，请检查日志"
        exit 1
    fi
fi
}

show_link(){
    # 优先获取 IPv4
    ip=$(curl -4 -s --max-time 5 ip.sb)
    if [ -z "$ip" ]; then
        ip=$(curl -s --max-time 5 ifconfig.me)
    fi
    if [ -z "$ip" ]; then
        ip=$(curl -s --max-time 5 api.ipify.org)
    fi

    if [ -z "$ip" ]; then
        red "无法获取公网IP，请手动检查"
        exit 1
    fi

    purple "\nTG分享链接:\n"
    LINKS="tg://proxy?server=$ip&port=$PORT&secret=$SECRET"
    green "$LINKS\n"
    echo -e "$LINKS" > $WORKDIR/link.txt

    purple "\n配置信息:"
    green "服务器: $ip"
    green "端口: $PORT"
    green "密钥: $SECRET"
    purple "\n一键卸载命令: rm -rf ~/mtp && pkill mtg"
    purple "重启命令: pkill mtg && cd ~/mtp && nohup ./mtg run -b 0.0.0.0:$PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &\n"
}

install(){
purple "正在安装中,请稍等...\n"

# 安装依赖
install_dependencies

if [[ "$HOSTNAME" =~ serv00.com|ct8.pl|useruno.com ]]; then
    check_port
    get_ip
    download_run
    generate_info
else
    download_mtg
    show_link
fi
}

install
