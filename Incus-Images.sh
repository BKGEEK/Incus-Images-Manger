#!/bin/bash
# 交互式镜像管理脚本 - 自动下载安装版
# 从 buildct.sh 中提取的镜像相关功能

red() { echo -e "\033[31m\033[01m$@\033[0m"; }
green() { echo -e "\033[32m\033[01m$@\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(green "$1")" "$2"; }

# CDN 检测函数
check_cdn() {
    local o_url=$1
    local cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
    
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        echo "CDN available, using CDN"
    else
        echo "No CDN available, no use CDN"
    fi
}

# 重试下载函数
retry_curl() {
    local url="$1"
    local max_attempts=5
    local delay=1
    _retry_result=""
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        _retry_result=$(curl -slk -m 6 "$url")
        if [ $? -eq 0 ] && [ -n "$_retry_result" ]; then
            return 0
        fi
        sleep "$delay"
        delay=$((delay * 2))
    done
    return 1
}

retry_wget() {
    local url="$1"
    local filename="$2"
    local max_attempts=5
    local delay=1
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        wget -q "$url" -O "$filename" && return 0
        sleep "$delay"
        delay=$((delay * 2))
    done
    return 1
}

# 系统架构检测
detect_arch() {
    sysarch="$(uname -m)"
    case "${sysarch}" in
    "x86_64" | "x86" | "amd64" | "x64") sys_bit="x86_64" ;;
    "i386" | "i686") sys_bit="i686" ;;
    "aarch64" | "armv8" | "armv8l") sys_bit="arm64" ;;
    "armv7l") sys_bit="armv7l" ;;
    "s390x") sys_bit="s390x" ;;
    "ppc64le") sys_bit="ppc64le" ;;
    *) sys_bit="x86_64" ;;
    esac
    echo "$sys_bit"
}

# 镜像导入函数
import_image() {
    local image_name="$1"
    local image_url="$2"
    local cdn_success_url="${3:-}"
    
    green "开始导入镜像: $image_name"
    green "镜像URL: $image_url"
    
    # 下载镜像文件
    yellow "下载镜像中..."
    if ! retry_wget "${cdn_success_url}${image_url}" "$image_name"; then
        red "镜像下载失败: $image_name"
        return 1
    fi
    
    # 解压和处理镜像
    yellow "解压镜像中..."
    chmod 777 "$image_name"
    if ! unzip "$image_name"; then
        red "镜像解压失败: $image_name"
        rm -rf "$image_name"
        return 1
    fi
    
    rm -rf "$image_name"
    
    # 导入到 Incus
    yellow "导入到 Incus 中..."
    if incus image import incus.tar.xz rootfs.squashfs --alias "$image_name"; then
        green "✅ 镜像导入成功: $image_name"
        rm -rf incus.tar.xz rootfs.squashfs
        return 0
    else
        red "❌ 镜像导入失败: $image_name"
        rm -rf incus.tar.xz rootfs.squashfs
        return 1
    fi
}

# 检查自定义镜像
check_custom_images() {
    local system="$1"
    local sys_bit="$2"
    local cdn_success_url="$3"
    
    local a="${system%%[0-9]*}"
    local b="${system##*[!0-9.]}"
    local image_download_url=""
    
    if [[ "$sys_bit" == "x86_64" || "$sys_bit" == "arm64" ]]; then
        retry_curl "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus_images/main/${sys_bit}_all_images.txt"
        local self_fixed_images=(${_retry_result})
        
        for image_name in "${self_fixed_images[@]}"; do
            if [ -z "${b}" ]; then
                if [[ "$image_name" == "${a}"* ]]; then
                    image_download_url="https://github.com/oneclickvirt/incus_images/releases/download/${a}/${image_name}"
                    break
                fi
            else
                if [[ "$image_name" == "${a}_${b}"* ]]; then
                    image_download_url="https://github.com/oneclickvirt/incus_images/releases/download/${a}/${image_name}"
                    break
                fi
            fi
        done
    fi
    
    echo "$image_download_url"
}

# 检查标准镜像库
check_standard_images() {
    local system="$1"
    local sys_bit="$2"
    
    local a="${system%%[0-9]*}"
    local b="${system##*[!0-9.]}"
    local available_image=""
    
    # 检查官方镜像库
    available_image=$(incus image list images:${a}/${b} --format=json | jq -r --arg ARCHITECTURE "$sys_bit" '.[] | select(.type == "container" and .architecture == $ARCHITECTURE) | .aliases[0].name' | head -n 1)
    
    if [ -n "$available_image" ]; then
        echo "images:$available_image"
        return 0
    fi
    
    # 检查清华镜像库
    available_image=$(incus image list opsmaru:${a}/${b} --format=json | jq -r --arg ARCHITECTURE "$sys_bit" '.[] | select(.type == "container" and .architecture == $ARCHITECTURE) | .aliases[0].name' | head -n 1)
    
    if [ -n "$available_image" ]; then
        echo "opsmaru:$available_image"
        return 0
    fi
    
    return 1
}

# 自动下载并安装镜像
auto_download_install() {
    local system="$1"
    local cdn_success_url="$2"
    
    local sys_bit=$(detect_arch)
    green "正在搜索系统镜像: $system (架构: $sys_bit)"
    
    # 首先检查自定义镜像
    yellow "检查自定义镜像..."
    local custom_image_url=$(check_custom_images "$system" "$sys_bit" "$cdn_success_url")
    
    if [ -n "$custom_image_url" ]; then
        green "✅ 找到自定义镜像!"
        local image_name=$(basename "$custom_image_url")
        
        # 检查镜像是否已存在
        if incus image alias list | grep -q "$image_name"; then
            green "✅ 镜像已存在: $image_name"
            return 0
        fi
        
        # 下载并安装自定义镜像
        green "开始下载安装自定义镜像..."
        if import_image "$image_name" "$custom_image_url" "$cdn_success_url"; then
            green "✅ 自定义镜像安装完成: $image_name"
            return 0
        else
            red "❌ 自定义镜像安装失败，尝试标准镜像..."
        fi
    fi
    
    # 检查标准镜像库
    yellow "检查标准镜像库..."
    local standard_image=$(check_standard_images "$system" "$sys_bit")
    
    if [ -n "$standard_image" ]; then
        green "✅ 找到标准镜像: $standard_image"
        
        # 从镜像源获取镜像名称
        local image_source="${standard_image%%:*}"
        local image_alias="${standard_image#*:}"
        
        # 检查镜像是否已存在
        if incus image alias list | grep -q "$image_alias"; then
            green "✅ 镜像已存在: $image_alias"
            return 0
        fi
        
        # 下载标准镜像
        yellow "开始下载标准镜像..."
        if incus image copy "$standard_image" local: --alias "$image_alias" --auto-update; then
            green "✅ 标准镜像下载完成: $image_alias"
            return 0
        else
            red "❌ 标准镜像下载失败"
            return 1
        fi
    fi
    
    red "❌ 未找到匹配的镜像: $system"
    return 1
}

# 列出可用镜像
list_available_images() {
    local sys_bit=$(detect_arch)
    green "可用镜像列表 (架构: $sys_bit):"
    
    # 获取自定义镜像列表
    check_cdn_file
    retry_curl "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus_images/main/${sys_bit}_all_images.txt"
    local custom_images=(${_retry_result})
    
    if [ ${#custom_images[@]} -gt 0 ]; then
        echo ""
        green "=== 自定义镜像 ==="
        for image in "${custom_images[@]}"; do
            echo "  $image"
        done
    fi
    
    # 获取官方镜像列表
    echo ""
    green "=== 官方镜像 ==="
    incus image list images: --format=json | jq -r --arg ARCHITECTURE "$sys_bit" '.[] | select(.type == "container" and .architecture == $ARCHITECTURE) | .aliases[0].name' | head -20
    
    # 获取清华镜像列表
    echo ""
    green "=== 清华镜像 ==="
    incus image list opsmaru: --format=json | jq -r --arg ARCHITECTURE "$sys_bit" '.[] | select(.type == "container" and .architecture == $ARCHITECTURE) | .aliases[0].name' | head -20
}

# 删除镜像
remove_image() {
    local image_name="$1"
    if incus image delete "$image_name"; then
        green "✅ 镜像删除成功: $image_name"
        return 0
    else
        red "❌ 镜像删除失败: $image_name"
        return 1
    fi
}

# 功能1: 搜索并自动安装镜像
function_auto_install() {
    clear
    green "=========================================="
    green "           搜索并自动安装镜像"
    green "=========================================="
    echo ""
    
    reading "请输入要安装的系统名称 (如: debian11, ubuntu20, centos7): " system_name
    
    if [ -z "$system_name" ]; then
        red "系统名称不能为空!"
        sleep 2
        return
    fi
    
    check_cdn_file
    echo ""
    green "开始自动搜索和安装镜像..."
    echo ""
    
    if auto_download_install "$system_name" "$cdn_success_url"; then
        green "🎉 镜像安装成功!"
    else
        red "❌ 镜像安装失败!"
    fi
    
    echo ""
    yellow "按回车键返回主菜单..."
    read -n 1
}

# 功能2: 列出可用镜像
function_list_images() {
    clear
    green "=========================================="
    green "           列出可用镜像"
    green "=========================================="
    echo ""
    
    list_available_images
    
    echo ""
    yellow "按回车键返回主菜单..."
    read -n 1
}

# 功能3: 删除镜像
function_remove_image() {
    clear
    green "=========================================="
    green "           删除镜像"
    green "=========================================="
    echo ""
    
    # 先列出当前镜像
    green "当前已安装的镜像:"
    incus image list --format=csv | awk -F, '{print $1 " | " $2}'
    echo ""
    
    reading "请输入要删除的镜像名称: " image_to_remove
    
    if [ -z "$image_to_remove" ]; then
        red "镜像名称不能为空!"
        sleep 2
        return
    fi
    
    # 确认删除
    reading "确定要删除镜像 '$image_to_remove' 吗? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if remove_image "$image_to_remove"; then
            green "✅ 镜像删除成功!"
        else
            red "❌ 镜像删除失败!"
        fi
    else
        yellow "取消删除操作"
    fi
    
    echo ""
    yellow "按回车键返回主菜单..."
    read -n 1
}

# 功能4: 批量安装常用镜像
function_batch_install() {
    clear
    green "=========================================="
    green "           批量安装常用镜像"
    green "=========================================="
    echo ""
    
    local common_images=("debian11" "ubuntu20" "centos7" "almalinux8" "rockylinux8")
    
    green "将安装以下常用镜像:"
    for image in "${common_images[@]}"; do
        echo "  📦 $image"
    done
    echo ""
    
    reading "确认开始批量安装吗? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        yellow "取消批量安装"
        sleep 2
        return
    fi
    
    check_cdn_file
    echo ""
    
    local success_count=0
    local total_count=${#common_images[@]}
    
    for image in "${common_images[@]}"; do
        green "正在处理: $image"
        if auto_download_install "$image" "$cdn_success_url"; then
            green "✅ $image 安装成功"
            ((success_count++))
        else
            red "❌ $image 安装失败"
        fi
        echo ""
    done
    
    green "批量安装完成!"
    green "成功: $success_count/$total_count"
    
    echo ""
    yellow "按回车键返回主菜单..."
    read -n 1
}

# 显示主菜单
show_menu() {
    clear
    green "=========================================="
    green "    Incus 镜像自动管理工具 by Mike Leone"
    green "=========================================="
    echo ""
    green "系统架构: $(detect_arch)"
    echo ""
    green "请选择操作:"
    echo "1. 🔍 搜索并自动安装镜像"
    echo "2. 📦 批量安装常用镜像"
    echo "3. 📋 列出可用镜像"
    echo "4. 🗑️  删除镜像"
    echo "5. ❌ 退出"
    echo ""
}

# 安装依赖
install_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        yellow "安装 jq..."
        apt-get install jq -y >/dev/null 2>&1 || yum install jq -y >/dev/null 2>&1 || dnf install jq -y >/dev/null 2>&1
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        yellow "安装 unzip..."
        apt-get install unzip -y >/dev/null 2>&1 || yum install unzip -y >/dev/null 2>&1 || dnf install unzip -y >/dev/null 2>&1
    fi
}

# 主循环
main() {
    install_dependencies
    
    while true; do
        show_menu
        reading "请输入选择 (1-5): " choice
        
        case $choice in
            1)
                function_auto_install
                ;;
            2)
                function_batch_install
                ;;
            3)
                function_list_images
                ;;
            4)
                function_remove_image
                ;;
            5)
                green "感谢使用，再见!"
                exit 0
                ;;
            *)
                red "无效选择，请重新输入!"
                sleep 2
                ;;
        esac
    done
}

# 启动脚本
main "$@"
