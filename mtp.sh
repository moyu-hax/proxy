#!/bin/bash

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

# 检测系统类型
detect_system() {
    if command -v apk &> /dev/null; then
        echo "alpine"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "redhat"
    else
        echo "unknown"
    fi
}

# 检测并安装必要依赖
install_dependencies() {
    SYSTEM_TYPE=$(detect_system)

    if [ "$SYSTEM_TYPE" = "alpine" ]; then
        yellow "检测到 Alpine 系统，正在安装依赖..."
        apk update >/dev/null 2>&1
        apk add --no-cache bash curl wget coreutils jq libc6-compat libstdc++ >/dev/null 2>&1
        green "依赖安装完成"
    elif [ "$SYSTEM_TYPE" = "debian" ]; then
        yellow "检测到 Debian/Ubuntu 系统，检查依赖..."
        apt-get update >/dev/null 2>&1
        apt-get install -y curl wget jq >/dev/null 2>&1
    elif [ "$SYSTEM_TYPE" = "redhat" ]; then
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

# 检测系统类型
SYSTEM_TYPE=$(detect_system)
green "检测到系统类型: $SYSTEM_TYPE"

# 根据系统类型选择下载源
download_success=false

if [ "$SYSTEM_TYPE" = "alpine" ]; then
    # Alpine 使用 musl libc，需要静态编译版本
    yellow "Alpine 系统，尝试下载静态编译版本..."
    urls=(
        "https://github.com/9seconds/mtg/releases/download/v2.1.8/mtg-linux-$arch"
        "https://github.com/eooce/test/releases/download/ARM/mtg-linux-$arch"
        "https://$arch.ssss.nyc.mn/mtg-linux-$arch"
    )
else
    # 其他系统使用标准版本
    urls=(
        "https://$arch.ssss.nyc.mn/mtg-linux-$arch"
        "https://github.com/9seconds/mtg/releases/download/v2.1.8/mtg-linux-$arch"
    )
fi

for url in "${urls[@]}"; do
    yellow "尝试从 $url 下载..."
    if wget -q --timeout=15 -O "${WORKDIR}/mtg" "$url"; then
        if [ -s "${WORKDIR}/mtg" ]; then
            chmod +x "${WORKDIR}/mtg"

            # 检查文件类型
            if command -v file &> /dev/null; then
                file_info=$(file "${WORKDIR}/mtg")
                yellow "文件信息: $file_info"
            fi

            # 尝试执行测试
            if "${WORKDIR}/mtg" --help >/dev/null 2>&1; then
                download_success=true
                green "下载成功并验证可执行"
                break
            else
                yellow "此版本无法执行，尝试下一个源..."
                rm -f "${WORKDIR}/mtg"
            fi
        fi
    fi
done

if [ "$download_success" = false ]; then
    red "所有下载源都失败了"

    # 尝试使用 Docker 方式（如果可用）
    if command -v docker &> /dev/null; then
        yellow "尝试使用 Docker 运行 MTG..."
        export PORT=${PORT:-$(shuf -i 2000-10000 -n 1)}

        docker run -d --name mtg \
            --restart=unless-stopped \
            -p $PORT:3128 \
            nineseconds/mtg:latest \
            run $SECRET

        if [ $? -eq 0 ]; then
            green "Docker 方式启动成功"
            show_link
            exit 0
        fi
    fi

    red "安装失败，请尝试以下方案："
    yellow "1. 手动下载: wget https://github.com/9seconds/mtg/releases/download/v2.1.8/mtg-linux-$arch -O ~/mtp/mtg"
    yellow "2. 使用 Docker: docker run -d -p PORT:3128 nineseconds/mtg:latest run SECRET"
    yellow "3. 从源码编译: https://github.com/9seconds/mtg"
    exit 1
fi

export PORT=${PORT:-$(shuf -i 2000-10000 -n 1)}

# 查找可用的统计端口
find_available_port() {
    local start_port=$1
    local max_attempts=100
    for ((i=0; i<max_attempts; i++)); do
        local test_port=$((start_port + i))
        # 尝试绑定端口来测试是否可用
        if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/$test_port" 2>/dev/null; then
            continue  # 端口被占用
        else
            echo $test_port
            return 0
        fi
    done
    # 如果都失败，使用随机端口
    echo $((10000 + RANDOM % 20000))
}

export MTP_PORT=$(find_available_port $((PORT + 1)))
green "使用统计端口: $MTP_PORT"

cd ${WORKDIR}

# 先尝试不带统计服务器启动（更稳定）
yellow "尝试启动 MTG 代理..."
nohup ./mtg run -b 0.0.0.0:$PORT $SECRET >mtg.log 2>&1 &
MTG_PID=$!
sleep 3

# 检查进程是否还在运行
if kill -0 $MTG_PID 2>/dev/null; then
    green "MTG 代理启动成功（PID: $MTG_PID）"
    # 验证端口是否监听
    if netstat -tuln 2>/dev/null | grep -q ":$PORT " || ss -tuln 2>/dev/null | grep -q ":$PORT "; then
        green "端口 $PORT 已成功监听"
    else
        yellow "警告：进程运行中但端口未监听，请检查日志"
    fi
else
    red "MTG 代理启动失败"
    yellow "查看日志信息："
    cat mtg.log
    exit 1
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
