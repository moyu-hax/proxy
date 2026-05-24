#!/bin/sh

set -eu

red() { printf '\033[1;91m%b\033[0m\n' "$1"; }
green() { printf '\033[1;32m%b\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%b\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%b\033[0m\n' "$1"; }

HOSTNAME_VALUE="$(hostname 2>/dev/null || printf 'server')"
USERNAME_VALUE="$(whoami 2>/dev/null | tr '[:upper:]' '[:lower:]' || printf 'user')"
WORKDIR="${WORKDIR:-$HOME/mtp}"
MTG_VERSION="${MTG_VERSION:-2.2.8}"
GH_PROXY="${GH_PROXY:-}"

mkdir -p "$WORKDIR"

make_secret() {
    seed="$USERNAME_VALUE+$HOSTNAME_VALUE"
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$seed" | md5sum | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$seed" | md5 | awk '{print $NF}'
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$seed" | openssl md5 | awk '{print $NF}'
    else
        red "缺少 md5sum/md5/openssl，无法生成 MTProto secret"
        exit 1
    fi
}

SECRET="${SECRET:-}"
export SECRET

save_secret() {
    printf '%s\n' "$SECRET" >"$WORKDIR/secret.txt"
    export SECRET
}

ensure_secret() {
    if [ -n "${SECRET:-}" ]; then
        save_secret
        return 0
    fi

    if [ -s "$WORKDIR/secret.txt" ]; then
        SECRET="$(tr -d '[:space:]' <"$WORKDIR/secret.txt")"
        export SECRET
        return 0
    fi

    domain="${FAKETLS_DOMAIN:-www.cloudflare.com}"
    generated=""
    if [ -x "$WORKDIR/mtg" ]; then
        generated="$("$WORKDIR/mtg" generate-secret --hex "$domain" 2>/dev/null | awk '{print $NF}' | tail -n 1 | tr -d '[:space:]' || true)"
    fi

    case "$generated" in
        *[!0-9A-Fa-f]*|'')
            generated=""
            ;;
    esac

    if [ -n "$generated" ] && [ "${#generated}" -ge 32 ]; then
        SECRET="$generated"
        green "已生成 FakeTLS secret，伪装域名: $domain"
    else
        SECRET="$(make_secret)"
        yellow "mtg 无法生成 FakeTLS secret，已使用兼容 secret"
    fi

    save_secret
}

stop_old_mtg() {
    if command -v pkill >/dev/null 2>&1; then
        pkill -x mtg >/dev/null 2>&1 || true
    fi
}

install_alpine_deps() {
    [ -f /etc/alpine-release ] || return 0
    [ "$(id -u 2>/dev/null || printf 1)" = "0" ] || return 0
    command -v apk >/dev/null 2>&1 || return 0

    missing=""
    for cmd in curl wget tar gzip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done

    if [ -n "$missing" ]; then
        yellow "Alpine 缺少基础工具，正在安装:$missing ca-certificates"
        apk add --no-cache ca-certificates curl wget tar gzip >/dev/null
    fi
}

download_file() {
    url="$1"
    output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --retry 2 "$url" -o "$output" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 10 -O "$output" "$url" && return 0
    fi

    red "缺少可用的 curl 或 wget，无法下载 mtg"
    return 1
}

fetch_url() {
    url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL --max-time 5 "$url" 2>/dev/null && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O - "$url" 2>/dev/null && return 0
    fi

    return 1
}

random_port() {
    min="$1"
    max="$2"

    if command -v shuf >/dev/null 2>&1; then
        shuf -i "$min-$max" -n 1
    elif command -v od >/dev/null 2>&1; then
        number="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')"
        number="${number:-$$}"
        printf '%s\n' "$((min + number % (max - min + 1)))"
    else
        printf '%s\n' "$((min + $$ % (max - min + 1)))"
    fi
}

port_in_use() {
    port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -q "[.:]$port "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -q "[.:]$port "
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

is_ipv4() {
    printf '%s\n' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

pick_random_free_port() {
    count=0
    while [ "$count" -lt 30 ]; do
        candidate="$(random_port 20000 65535)"
        if ! port_in_use "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        count=$((count + 1))
    done

    red "没有找到可用端口，请手动指定，例如：PORT=34567 sh mtp.sh"
    exit 1
}

pick_free_port() {
    if [ "${PORT:-}" ]; then
        case "$PORT" in
            *[!0-9]*|'')
                red "PORT 必须是 1-65535 的数字"
                exit 1
                ;;
        esac
        if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            red "PORT 必须是 1-65535 的数字"
            exit 1
        fi
        printf '%s\n' "$PORT"
        return 0
    fi

    pick_random_free_port
}

pick_stats_port() {
    proxy_port="$1"
    if [ "$proxy_port" -lt 65535 ]; then
        candidate=$((proxy_port + 1))
    else
        candidate=$((proxy_port - 1))
    fi

    if ! port_in_use "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    pick_random_free_port
}

detect_arch() {
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            red "暂不支持当前 CPU 架构: $arch"
            exit 1
            ;;
    esac
}

extract_mtg_archive() {
    archive="$1"
    tmpdir="$WORKDIR/extract.$$"

    mkdir -p "$tmpdir"
    if ! tar -xzf "$archive" -C "$tmpdir" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        return 1
    fi

    mtg_bin="$(find "$tmpdir" -type f -name mtg 2>/dev/null | head -n 1 || true)"
    if [ -z "$mtg_bin" ]; then
        rm -rf "$tmpdir"
        return 1
    fi

    mv "$mtg_bin" "$WORKDIR/mtg"
    rm -rf "$tmpdir"
    return 0
}

verify_mtg() {
    [ -s "$WORKDIR/mtg" ] || return 1
    chmod +x "$WORKDIR/mtg"
    "$WORKDIR/mtg" --help >/dev/null 2>&1 || "$WORKDIR/mtg" -h >/dev/null 2>&1
}

download_mtg_linux() {
    arch="$(detect_arch)"

    if [ -x "$WORKDIR/mtg" ] && verify_mtg; then
        green "检测到已安装 mtg，继续使用现有文件"
        return 0
    fi

    tmp="$WORKDIR/mtg.download.$$"
    tag="v$MTG_VERSION"
    github_url="https://github.com/9seconds/mtg/releases/download/$tag/mtg-$MTG_VERSION-linux-$arch.tar.gz"
    mirror_url="https://$arch.ssss.nyc.mn/mtg-linux-$arch"

    for url in ${MTG_URL:-} "$github_url" "${GH_PROXY}${github_url}" "$mirror_url"; do
        [ -n "$url" ] || continue
        yellow "正在下载 mtg: $url"
        if download_file "$url" "$tmp"; then
            case "$url" in
                *.tar.gz)
                    if extract_mtg_archive "$tmp" && verify_mtg; then
                        rm -f "$tmp"
                        return 0
                    fi
                    ;;
                *)
                    mv "$tmp" "$WORKDIR/mtg"
                    if verify_mtg; then
                        return 0
                    fi
                    ;;
            esac
        fi
        rm -f "$tmp"
    done

    red "mtg 下载或运行校验失败。可手动指定下载地址：MTG_URL=https://... sh mtp.sh"
    exit 1
}

get_public_ip() {
    if [ "${SERVER_IP:-}" ]; then
        printf '%s\n' "$SERVER_IP"
        return 0
    fi

    for url in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://ifconfig.me/ip" \
        "https://ip.sb"; do
        ip="$(fetch_url "$url" | tr -d '[:space:]' || true)"
        if [ -n "$ip" ] && is_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done

    red "无法获取公网 IPv4，请检查网络，或手动指定：SERVER_IP=你的公网IP sh mtp.sh"
    exit 1
}

start_mtg() {
    proxy_port="$1"
    stats_port="$2"

    stop_old_mtg
    cd "$WORKDIR"
    nohup ./mtg run -b "0.0.0.0:$proxy_port" "$SECRET" --stats-bind="127.0.0.1:$stats_port" >"$WORKDIR/mtg.log" 2>&1 &
    mtg_pid="$!"
    sleep 1

    if kill -0 "$mtg_pid" >/dev/null 2>&1; then
        green "mtg 已启动，PID: $mtg_pid"
    else
        red "mtg 启动失败，日志如下："
        tail -n 30 "$WORKDIR/mtg.log" 2>/dev/null || true
        exit 1
    fi
}

write_restart_script() {
    proxy_port="$1"
    stats_port="$2"

    cat >"$WORKDIR/restart.sh" <<EOF
#!/bin/sh
pkill -x mtg >/dev/null 2>&1 || true
cd "$WORKDIR" || exit 1
nohup ./mtg run -b 0.0.0.0:$proxy_port $SECRET --stats-bind=127.0.0.1:$stats_port >"$WORKDIR/mtg.log" 2>&1 &
EOF
    chmod +x "$WORKDIR/restart.sh"
}

show_link() {
    ip="$1"
    proxy_port="$2"

    link="tg://proxy?server=$ip&port=$proxy_port&secret=$SECRET"
    printf '%s\n' "$link" >"$WORKDIR/link.txt"

    purple "\nTG 分享链接:\n"
    green "$link\n"
    purple "重启命令: sh $WORKDIR/restart.sh"
    purple "一键卸载: rm -rf $WORKDIR && pkill -x mtg"
    yellow "如果 Telegram 仍显示不可用，请在 VPS 防火墙和云厂商安全组放行 TCP $proxy_port。"
}

check_serv00_port() {
    port_list="$(devil port list)"
    tcp_count="$(printf '%s\n' "$port_list" | grep -c "tcp" || true)"
    udp_count="$(printf '%s\n' "$port_list" | grep -c "udp" || true)"

    if [ "$tcp_count" -lt 1 ]; then
        red "没有可用的 TCP 端口，正在调整..."

        if [ "$udp_count" -ge 3 ]; then
            udp_port_to_delete="$(printf '%s\n' "$port_list" | awk '/udp/ {print $1}' | head -n 1)"
            devil port del udp "$udp_port_to_delete"
            green "已删除 UDP 端口: $udp_port_to_delete"
        fi

        while :; do
            tcp_port="$(random_port 10000 65535)"
            result="$(devil port add tcp "$tcp_port" 2>&1 || true)"
            case "$result" in
                *Ok*)
                    green "已添加 TCP 端口: $tcp_port"
                    MTP_PORT="$tcp_port"
                    break
                    ;;
                *)
                    yellow "端口 $tcp_port 不可用，尝试其他端口..."
                    ;;
            esac
        done
    else
        MTP_PORT="$(printf '%s\n' "$port_list" | awk '/tcp/ {print $1}' | head -n 1)"
    fi

    devil binexec on >/dev/null 2>&1 || true
    green "使用 $MTP_PORT 作为 TG 代理端口"
}

get_serv00_ips() {
    API_URL="https://status.eooce.com/api"
    AVAILABLE_IPS=""

    for ip in $(devil vhost list | awk '/^[0-9]+/ {print $1}'); do
        response="$(curl -s --max-time 2 "$API_URL/$ip" 2>/dev/null || true)"
        if printf '%s\n' "$response" | grep -q '"status"[[:space:]]*:[[:space:]]*"Available"'; then
            AVAILABLE_IPS="$AVAILABLE_IPS $ip"
        fi
    done

    set -- $AVAILABLE_IPS
    IP1="${1:-}"
    IP2="${2:-}"
    IP3="${3:-}"

    if [ -z "$IP1" ]; then
        red "所有 IP 都不可用，请更换服务器安装"
        exit 1
    fi
}

download_mtg_freebsd() {
    if [ -x "$WORKDIR/mtg" ]; then
        chmod +x "$WORKDIR/mtg"
        return 0
    fi

    mtg_url="https://github.com/eooce/test/releases/download/freebsd/mtg-freebsd-amd64"
    yellow "正在下载 mtg: $mtg_url"
    download_file "$mtg_url" "$WORKDIR/mtg"
    chmod +x "$WORKDIR/mtg"
}

show_serv00_links() {
    links=""
    [ -n "$IP1" ] && links="$links
tg://proxy?server=$IP1&port=$MTP_PORT&secret=$SECRET"
    [ -n "$IP2" ] && links="$links
tg://proxy?server=$IP2&port=$MTP_PORT&secret=$SECRET"
    [ -n "$IP3" ] && links="$links
tg://proxy?server=$IP3&port=$MTP_PORT&secret=$SECRET"

    printf '%s\n' "$links" | sed '/^$/d' >"$WORKDIR/link.txt"
    purple "\n分享链接:\n"
    green "$(printf '%s\n' "$links" | sed '/^$/d')\n"
}

install_linux_vps() {
    install_alpine_deps
    download_mtg_linux
    ensure_secret
    MTP_PORT="$(pick_free_port)"
    STATS_PORT="$(pick_stats_port "$MTP_PORT")"
    PUBLIC_IP="$(get_public_ip)"

    green "使用 $MTP_PORT 作为 TG 代理端口"
    start_mtg "$MTP_PORT" "$STATS_PORT"
    write_restart_script "$MTP_PORT" "$STATS_PORT"
    show_link "$PUBLIC_IP" "$MTP_PORT"
}

install_serv00() {
    check_serv00_port
    get_serv00_ips
    download_mtg_freebsd
    ensure_secret
    STATS_PORT="$(pick_stats_port "$MTP_PORT")"

    start_mtg "$MTP_PORT" "$STATS_PORT"
    write_restart_script "$MTP_PORT" "$STATS_PORT"
    show_serv00_links
}

install() {
    purple "正在安装中，请稍等...\n"
    case "$HOSTNAME_VALUE" in
        *serv00.com*|*ct8.pl*|*useruno.com*)
            install_serv00
            ;;
        *)
            install_linux_vps
            ;;
    esac
}

install
