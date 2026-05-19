#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Font="\033[0m"

root_need() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${Red}Error: This script must be run as root!${Font}"
        exit 1
    fi
}

ovz_no() {
    if [[ -d "/proc/vz" ]]; then
        echo -e "${Red}Your VPS is based on OpenVZ, not supported!${Font}"
        exit 1
    fi
}

pause() {
    read -rp "按回车键继续..."
}

get_mem_mb() {
    awk '/MemTotal/ {print int(($2 + 1023) / 1024)}' /proc/meminfo
}

get_recommended_swap_mb() {
    local mem_mb
    mem_mb="$(get_mem_mb)"
    echo $((mem_mb * 2))
}

read_swap_size() {
    local mem_mb
    local recommend_mb
    local input_size

    mem_mb="$(get_mem_mb)"
    recommend_mb="$(get_recommended_swap_mb)"

    echo -e "${Green}当前物理内存约为：${mem_mb} MB${Font}" >&2
    echo -e "${Green}建议 Swap 设置为内存的 2 倍：${recommend_mb} MB${Font}" >&2
    echo -e "${Yellow}如果直接回车，将默认使用建议值：${recommend_mb} MB${Font}" >&2
    echo >&2

    printf "请输入 Swap 数值，单位 MB，默认 %s: " "$recommend_mb" >&2
    read -r input_size

    if [[ -z "$input_size" ]]; then
        input_size="$recommend_mb"
    fi

    if ! valid_size "$input_size"; then
        echo -e "${Red}输入错误，必须是正整数。${Font}" >&2
        return 1
    fi

    echo "$input_size"
    return 0
}

show_swap() {
    echo
    echo -e "${Green}当前内存信息：${Font}"
    free -h
    echo
    echo -e "${Green}当前 Swap 信息：${Font}"
    cat /proc/swaps
    echo
    echo -e "${Green}/etc/fstab 中的 swap 配置：${Font}"
    grep -v '^[[:space:]]*#' /etc/fstab | awk '$3=="swap"{print}'
    echo
}

backup_fstab() {
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
}

valid_size() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

is_swap_active() {
    local swapfile="$1"
    awk -v f="$swapfile" 'NR>1 && $1==f {found=1} END{exit !found}' /proc/swaps
}

is_in_fstab() {
    local swapfile="$1"
    awk -v f="$swapfile" '$1==f && $3=="swap"{found=1} END{exit !found}' /etc/fstab
}

remove_all_swap_from_fstab() {
    backup_fstab

    awk '
    /^[[:space:]]*#/ {print; next}
    NF==0 {print; next}
    $3=="swap" {next}
    {print}
    ' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
}

remove_one_swap_from_fstab() {
    local swapfile="$1"

    backup_fstab

    awk -v f="$swapfile" '
    /^[[:space:]]*#/ {print; next}
    NF==0 {print; next}
    $1==f && $3=="swap" {next}
    {print}
    ' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
}

create_swap_file() {
    local swapfile="$1"
    local swapsize="$2"

    if [[ -e "$swapfile" ]]; then
        echo -e "${Red}文件 $swapfile 已存在，无法创建。${Font}"
        return 1
    fi

    local parent_dir
    parent_dir="$(dirname "$swapfile")"

    if [[ ! -d "$parent_dir" ]]; then
        echo -e "${Red}目录 $parent_dir 不存在。${Font}"
        return 1
    fi

    echo -e "${Green}正在创建 ${swapsize}MB swap 文件：$swapfile${Font}"

    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${swapsize}M" "$swapfile"
        if [[ $? -ne 0 ]]; then
            echo -e "${Yellow}fallocate 创建失败，改用 dd 创建。${Font}"
            dd if=/dev/zero of="$swapfile" bs=1M count="$swapsize" status=progress
        fi
    else
        dd if=/dev/zero of="$swapfile" bs=1M count="$swapsize" status=progress
    fi

    if [[ $? -ne 0 ]]; then
        echo -e "${Red}创建 swap 文件失败。${Font}"
        rm -f "$swapfile"
        return 1
    fi

    chmod 600 "$swapfile"

    mkswap "$swapfile"
    if [[ $? -ne 0 ]]; then
        echo -e "${Red}mkswap 失败。${Font}"
        rm -f "$swapfile"
        return 1
    fi

    swapon "$swapfile"
    if [[ $? -ne 0 ]]; then
        echo -e "${Red}启用 swap 失败。${Font}"
        rm -f "$swapfile"
        return 1
    fi

    return 0
}

create_cleanup_service_after_reboot() {
    local new_swapfile="$1"
    shift
    local old_swaps=("$@")

    local state_dir="/var/lib/swap-manager"
    local old_list="${state_dir}/old_swaps.list"
    local new_file="${state_dir}/new_swap"
    local cleanup_script="/usr/local/sbin/swap_cleanup_after_reboot.sh"
    local service_file="/etc/systemd/system/swap-cleanup-after-reboot.service"

    mkdir -p "$state_dir"

    : > "$old_list"

    for old in "${old_swaps[@]}"; do
        if [[ -n "$old" && "$old" != "$new_swapfile" ]]; then
            echo "$old" >> "$old_list"
        fi
    done

    echo "$new_swapfile" > "$new_file"

    cat > "$cleanup_script" <<'EOF'
#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

STATE_DIR="/var/lib/swap-manager"
OLD_LIST="${STATE_DIR}/old_swaps.list"
NEW_FILE="${STATE_DIR}/new_swap"
LOG_FILE="${STATE_DIR}/cleanup.log"
SERVICE_FILE="/etc/systemd/system/swap-cleanup-after-reboot.service"
SELF="/usr/local/sbin/swap_cleanup_after_reboot.sh"

exec >> "$LOG_FILE" 2>&1

echo "========== $(date) =========="
echo "Start cleanup old swap files after reboot."

is_swap_active() {
    local swapfile="$1"
    awk -v f="$swapfile" 'NR>1 && $1==f {found=1} END{exit !found}' /proc/swaps
}

if [[ ! -f "$OLD_LIST" ]]; then
    echo "Old swap list not found, nothing to cleanup."
else
    while IFS= read -r oldswap; do
        [[ -z "$oldswap" ]] && continue

        echo "Checking old swap: $oldswap"

        if is_swap_active "$oldswap"; then
            echo "Skip $oldswap because it is still active."
            continue
        fi

        if [[ -f "$oldswap" ]]; then
            echo "Deleting old swap file: $oldswap"
            rm -f -- "$oldswap"
        else
            echo "$oldswap is not a regular file or does not exist, skip."
        fi
    done < "$OLD_LIST"
fi

echo
echo "Current swap status:"
cat /proc/swaps
echo
free -h

echo
echo "Disable and remove cleanup service."

systemctl disable swap-cleanup-after-reboot.service >/dev/null 2>&1 || true

rm -f "$SERVICE_FILE"
rm -f "$SELF"
rm -f "$OLD_LIST"
rm -f "$NEW_FILE"

systemctl daemon-reload >/dev/null 2>&1 || true

echo "Cleanup finished."
exit 0
EOF

    chmod +x "$cleanup_script"

    cat > "$service_file" <<EOF
[Unit]
Description=Cleanup old swap files after reboot
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$cleanup_script

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable swap-cleanup-after-reboot.service >/dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        echo -e "${Green}已创建开机自动清理旧 swap 的一次性服务。${Font}"
    else
        echo -e "${Red}创建自动清理服务失败，请重启后手动清理旧 swap。${Font}"
    fi
}

add_swap() {
    show_swap

    if awk 'NR>1 {found=1} END{exit !found}' /proc/swaps; then
        echo -e "${Red}当前系统已经存在启用中的 swap。${Font}"
        echo -e "${Yellow}如果你想扩容或更换 swap，请使用菜单中的【安全更换 swap】。${Font}"
        pause
        return
    fi

    echo -e "${Green}请输入需要添加的 Swap 大小。${Font}"
    echo -e "${Yellow}推荐值为当前内存的 2 倍。${Font}"
    echo

    local swapsize
    swapsize="$(read_swap_size)" || {
        pause
        return
    }

    local swapfile="/swapfile"

    create_swap_file "$swapfile" "$swapsize" || {
        pause
        return
    }

    backup_fstab
    echo "$swapfile none swap defaults 0 0" >> /etc/fstab

    echo -e "${Green}swap 创建成功。${Font}"
    show_swap
    pause
}

replace_swap_safe() {
    show_swap

    echo -e "${Yellow}说明：${Font}"
    echo -e "${Yellow}此功能用于安全扩容或更换 swap。${Font}"
    echo -e "${Yellow}脚本会先创建新的 swap，并立即启用它。${Font}"
    echo -e "${Yellow}然后修改 /etc/fstab，让下次开机只启用新的 swap。${Font}"
    echo -e "${Yellow}旧 swap 不会在线 swapoff，避免内存不足导致系统卡死。${Font}"
    echo -e "${Yellow}脚本还会创建开机后执行一次的清理服务，重启后自动删除旧 swap 文件。${Font}"
    echo

    mapfile -t old_swaps < <(awk 'NR>1 {print $1}' /proc/swaps)

    if [[ ${#old_swaps[@]} -eq 0 ]]; then
        echo -e "${Yellow}当前没有启用中的旧 swap。你也可以直接使用【添加 swap】。${Font}"
    else
        echo -e "${Green}检测到当前启用中的 swap：${Font}"
        printf '%s\n' "${old_swaps[@]}"
    fi

    echo
    echo -e "${Green}请输入新的 Swap 大小。${Font}"
    echo -e "${Yellow}推荐值为当前内存的 2 倍。${Font}"
    echo

    local swapsize
    swapsize="$(read_swap_size)" || {
        pause
        return
    }

    echo
    echo -e "${Green}请输入新 swap 文件路径。${Font}"
    echo -e "${Yellow}建议使用 /swapfile2。${Font}"
    read -rp "请输入路径，默认 /swapfile2: " swapfile

    if [[ -z "$swapfile" ]]; then
        swapfile="/swapfile2"
    fi

    if [[ "$swapfile" != /* ]]; then
        echo -e "${Red}swap 文件路径必须是绝对路径，例如 /swapfile2。${Font}"
        pause
        return
    fi

    if is_swap_active "$swapfile"; then
        echo -e "${Red}$swapfile 已经是启用中的 swap，不能重复创建。${Font}"
        pause
        return
    fi

    create_swap_file "$swapfile" "$swapsize" || {
        pause
        return
    }

    echo
    echo -e "${Green}正在修改 /etc/fstab。${Font}"
    echo -e "${Yellow}会删除原来的 swap 开机配置，只保留新的 $swapfile。${Font}"

    remove_all_swap_from_fstab
    echo "$swapfile none swap defaults 0 0" >> /etc/fstab

    echo
    echo -e "${Green}新的 swap 已经创建并启用。${Font}"
    echo -e "${Green}/etc/fstab 已修改为下次开机只启用：$swapfile${Font}"

    if command -v systemctl >/dev/null 2>&1; then
        create_cleanup_service_after_reboot "$swapfile" "${old_swaps[@]}"
    else
        echo -e "${Red}当前系统未检测到 systemctl，无法创建开机自动清理服务。${Font}"
        echo -e "${Yellow}你需要重启后手动删除旧 swap 文件。${Font}"
    fi

    echo
    show_swap

    echo -e "${Yellow}重要提示：${Font}"
    echo -e "${Yellow}当前旧 swap 可能仍然处于启用状态，这是正常的。${Font}"
    echo -e "${Yellow}为了避免内存不足时 swapoff 卡死，本脚本没有在线关闭旧 swap。${Font}"
    echo
    echo -e "${Green}下一步只需要重启系统。${Font}"
    echo -e "${Green}重启后，旧 swap 文件会自动清理。${Font}"
    echo

    read -rp "是否现在立即重启？直接回车默认重启，[Y/n]: " reboot_confirm

    if [[ -z "$reboot_confirm" || "$reboot_confirm" == "y" || "$reboot_confirm" == "Y" ]]; then
        echo -e "${Green}系统即将重启...${Font}"
        sleep 2
        reboot
    else
        echo -e "${Yellow}你已取消立即重启。${Font}"
        echo -e "${Yellow}你可以稍后手动执行 reboot。${Font}"
        echo -e "${Yellow}只要重启完成，旧 swap 会被自动清理。${Font}"
        pause
    fi
}

cleanup_old_swap_files_manual() {
    show_swap

    echo -e "${Yellow}此功能用于手动清理旧 swap 文件。${Font}"
    echo -e "${Yellow}正常情况下，如果你使用【安全更换 swap】，重启后会自动清理，不需要手动执行。${Font}"
    echo -e "${Yellow}它不会删除当前正在使用的 swap。${Font}"
    echo

    read -rp "请输入要删除的旧 swap 文件路径，例如 /swapfile: " oldswap

    if [[ -z "$oldswap" ]]; then
        echo -e "${Red}路径不能为空。${Font}"
        pause
        return
    fi

    if [[ "$oldswap" != /* ]]; then
        echo -e "${Red}必须输入绝对路径，例如 /swapfile。${Font}"
        pause
        return
    fi

    if is_swap_active "$oldswap"; then
        echo -e "${Red}$oldswap 当前仍然是启用中的 swap，不能删除。${Font}"
        echo -e "${Yellow}请确认已经重启，并且 /proc/swaps 里面没有它。${Font}"
        pause
        return
    fi

    if is_in_fstab "$oldswap"; then
        echo -e "${Yellow}$oldswap 仍然存在于 /etc/fstab，正在移除该配置。${Font}"
        remove_one_swap_from_fstab "$oldswap"
    fi

    if [[ -f "$oldswap" ]]; then
        rm -f -- "$oldswap"
        echo -e "${Green}已删除旧 swap 文件：$oldswap${Font}"
    else
        echo -e "${Yellow}$oldswap 不存在，或不是普通文件，无需删除。${Font}"
    fi

    show_swap
    pause
}

delete_swap_config_safe() {
    show_swap

    echo -e "${Red}警告：你正在尝试删除 swap 配置。${Font}"
    echo -e "${Yellow}为了避免内存不足导致系统卡死，本功能不会执行 swapoff -a。${Font}"
    echo
    echo -e "${Yellow}本功能只会从 /etc/fstab 移除 swap 配置。${Font}"
    echo -e "${Yellow}重启后 swap 将不会自动启用。${Font}"
    echo -e "${Yellow}重启确认 swap 未启用后，再删除 swap 文件。${Font}"
    echo

    read -rp "确认从 /etc/fstab 移除所有 swap 配置？输入 YES 继续: " confirm

    if [[ "$confirm" != "YES" ]]; then
        echo -e "${Yellow}已取消。${Font}"
        pause
        return
    fi

    remove_all_swap_from_fstab

    echo -e "${Green}/etc/fstab 中的 swap 配置已移除。${Font}"
    echo -e "${Yellow}请重启系统后再清理 swap 文件。${Font}"
    show_swap
    pause
}

show_cleanup_log() {
    local log_file="/var/lib/swap-manager/cleanup.log"

    if [[ -f "$log_file" ]]; then
        echo -e "${Green}自动清理日志：${Font}"
        echo
        cat "$log_file"
    else
        echo -e "${Yellow}未发现自动清理日志：$log_file${Font}"
    fi

    pause
}

main() {
    root_need
    ovz_no

    while true; do
        clear
        echo -e "———————————————————————————————————————"
        echo -e "${Green}安全 Swap 管理脚本${Font}"
        echo -e "———————————————————————————————————————"
        echo -e "${Green}1、查看 swap 信息${Font}"
        echo -e "${Green}2、添加 swap，默认推荐内存 2 倍${Font}"
        echo -e "${Green}3、安全更换 swap，默认推荐内存 2 倍${Font}"
        echo -e "${Green}4、手动清理旧 swap 文件，一般不需要${Font}"
        echo -e "${Green}5、删除 swap 配置，重启后生效${Font}"
        echo -e "${Green}6、查看自动清理日志${Font}"
        echo -e "${Green}0、退出${Font}"
        echo -e "———————————————————————————————————————"
        read -rp "请输入数字 [0-6]: " num

        case "$num" in
            1)
                show_swap
                pause
                ;;
            2)
                add_swap
                ;;
            3)
                replace_swap_safe
                ;;
            4)
                cleanup_old_swap_files_manual
                ;;
            5)
                delete_swap_config_safe
                ;;
            6)
                show_cleanup_log
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${Red}请输入正确数字 [0-6]${Font}"
                sleep 2
                ;;
        esac
    done
}

main
