#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# ========== 配置项 ==========
# 你的 GitHub 仓库（用于编译模式）
GITHUB_REPO="awkys/V2bX"
# 下载源（用于下载模式）
DOWNLOAD_REPO="wyx2685/V2bX"
# 你自己的二进制下载地址（可选，留空则从 GitHub 下载）
CUSTOM_DOWNLOAD_URL=""
# ============================

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
    go_arch="amd64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
    go_arch="arm64"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
    go_arch="s390x"
else
    arch="64"
    go_arch="amd64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    echo -e "${green}安装基础依赖...${plain}"
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates git -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates git >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates git -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates git -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat ca-certificates git >/dev/null 2>&1
    fi
}

install_golang() {
    echo -e "${green}检查 Go 环境...${plain}"
    
    if command -v go &> /dev/null; then
        go_version=$(go version | awk '{print $3}' | sed 's/go//')
        echo -e "已安装 Go ${go_version}"
        required_version="1.24"
        if [ "$(printf '%s\n' "$required_version" "$go_version" | sort -V | head -n1)" = "$required_version" ]; then
            echo -e "${green}Go 版本满足要求${plain}"
            return 0
        fi
    fi
    
    echo -e "${green}安装 Go 1.25...${plain}"
    
    wget -q --show-progress -O /tmp/go.tar.gz "https://go.dev/dl/go1.25.4.linux-${go_arch}.tar.gz"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载 Go 失败${plain}"
        return 1
    fi
    
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    
    export PATH=$PATH:/usr/local/go/bin
    export GOROOT=/usr/local/go
    
    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi
    
    echo -e "${green}Go 安装完成: $(go version)${plain}"
    return 0
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/V2bX/V2bX ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service V2bX status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status V2bX | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

# 从源码编译安装
build_install() {
    echo -e "${green}========================================${plain}"
    echo -e "${green}从源码编译 V2bX (使用官方 sing-box 最新内核)${plain}"
    echo -e "${green}========================================${plain}"
    
    # 安装 Go
    install_golang
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Go 安装失败，尝试下载预编译版本${plain}"
        download_install
        return
    fi
    
    # 准备目录
    if [[ -e /usr/local/V2bX/ ]]; then
        rm -rf /usr/local/V2bX/
    fi
    mkdir -p /usr/local/V2bX/
    mkdir -p /etc/V2bX/
    
    # 克隆仓库
    build_dir="/tmp/V2bX-build-$$"
    rm -rf $build_dir
    
    echo -e "${green}克隆仓库 ${GITHUB_REPO}...${plain}"
    git clone --depth 1 https://github.com/${GITHUB_REPO}.git $build_dir
    if [[ $? -ne 0 ]]; then
        echo -e "${red}克隆仓库失败，尝试下载预编译版本${plain}"
        rm -rf $build_dir
        download_install
        return
    fi
    
    cd $build_dir
    
    # 更新依赖 (仓库已配置使用 wyx2685/sing-box_mod 修改版)
    echo -e "${green}更新依赖...${plain}"
    export PATH=$PATH:/usr/local/go/bin
    go mod tidy
    if [[ $? -ne 0 ]]; then
        echo -e "${red}更新依赖失败${plain}"
        cd /
        rm -rf $build_dir
        exit 1
    fi
    
    # 编译 (需要添加 build tags 来包含各个 core)
    # 注意: hysteria2 tag 暂时有兼容性问题，如需 hy2 请使用内置的 sing core
    echo -e "${green}编译中 (可能需要几分钟)...${plain}"
    GOEXPERIMENT=jsonv2 CGO_ENABLED=0 go build -tags "sing xray" -ldflags="-s -w" -o V2bX .
    if [[ $? -ne 0 ]]; then
        echo -e "${red}编译失败${plain}"
        cd /
        rm -rf $build_dir
        exit 1
    fi
    
    # 验证编译结果
    if [[ ! -f "V2bX" ]]; then
        echo -e "${red}编译产物不存在${plain}"
        cd /
        rm -rf $build_dir
        exit 1
    fi
    
    echo -e "${green}编译完成，开始安装...${plain}"
    
    # 复制文件
    cp -f V2bX /usr/local/V2bX/V2bX
    chmod +x /usr/local/V2bX/V2bX
    
    # 验证复制
    if [[ ! -f /usr/local/V2bX/V2bX ]]; then
        echo -e "${red}复制文件失败${plain}"
        cd /
        rm -rf $build_dir
        exit 1
    fi
    
    # 复制配置文件
    [[ -f geoip.dat ]] && cp geoip.dat /etc/V2bX/
    [[ -f geosite.dat ]] && cp geosite.dat /etc/V2bX/
    
    if [[ ! -f /etc/V2bX/config.json ]]; then
        if [[ -f config.json ]]; then
            cp config.json /etc/V2bX/
        else
            create_default_config
        fi
        first_install=true
    else
        first_install=false
    fi
    
    [[ ! -f /etc/V2bX/dns.json ]] && [[ -f dns.json ]] && cp dns.json /etc/V2bX/
    [[ ! -f /etc/V2bX/route.json ]] && [[ -f route.json ]] && cp route.json /etc/V2bX/
    [[ ! -f /etc/V2bX/custom_outbound.json ]] && [[ -f custom_outbound.json ]] && cp custom_outbound.json /etc/V2bX/
    [[ ! -f /etc/V2bX/custom_inbound.json ]] && [[ -f custom_inbound.json ]] && cp custom_inbound.json /etc/V2bX/
    
    # 清理
    cd /
    rm -rf $build_dir
    
    # 配置服务
    setup_service
    
    echo -e "${green}========================================${plain}"
    echo -e "${green}V2bX 编译安装完成！${plain}"
    echo -e "${green}使用官方 sing-box v1.13.0-alpha.29 内核${plain}"
    echo -e "${green}========================================${plain}"
}

# 下载预编译版本安装
download_install() {
    echo -e "${green}========================================${plain}"
    echo -e "${green}下载预编译版本安装${plain}"
    echo -e "${green}========================================${plain}"
    
    if [[ -e /usr/local/V2bX/ ]]; then
        rm -rf /usr/local/V2bX/
    fi

    mkdir -p /usr/local/V2bX/
    mkdir -p /etc/V2bX/
    cd /usr/local/V2bX/

    # 获取最新版本
    last_version=$(curl -Ls "https://api.github.com/repos/${DOWNLOAD_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ ! -n "$last_version" ]]; then
        echo -e "${red}检测 V2bX 版本失败，可能是超出 Github API 限制，请稍后再试${plain}"
        exit 1
    fi
    
    echo -e "检测到 V2bX 最新版本：${last_version}，开始安装"
    
    if [[ -n "$CUSTOM_DOWNLOAD_URL" ]]; then
        download_url="${CUSTOM_DOWNLOAD_URL}/V2bX-linux-${arch}.zip"
    else
        download_url="https://github.com/${DOWNLOAD_REPO}/releases/download/${last_version}/V2bX-linux-${arch}.zip"
    fi
    
    wget --no-check-certificate -N --progress=bar -O /usr/local/V2bX/V2bX-linux.zip "$download_url"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载 V2bX 失败，请确保你的服务器能够下载 Github 的文件${plain}"
        exit 1
    fi

    unzip -o V2bX-linux.zip
    rm V2bX-linux.zip -f
    chmod +x V2bX
    
    # 验证文件
    if [[ ! -f /usr/local/V2bX/V2bX ]]; then
        echo -e "${red}安装失败：V2bX 文件不存在${plain}"
        exit 1
    fi
    
    [[ -f geoip.dat ]] && cp geoip.dat /etc/V2bX/
    [[ -f geosite.dat ]] && cp geosite.dat /etc/V2bX/
    
    if [[ ! -f /etc/V2bX/config.json ]]; then
        if [[ -f config.json ]]; then
            cp config.json /etc/V2bX/
        else
            create_default_config
        fi
        first_install=true
    else
        first_install=false
    fi
    
    [[ ! -f /etc/V2bX/dns.json ]] && [[ -f dns.json ]] && cp dns.json /etc/V2bX/
    [[ ! -f /etc/V2bX/route.json ]] && [[ -f route.json ]] && cp route.json /etc/V2bX/
    [[ ! -f /etc/V2bX/custom_outbound.json ]] && [[ -f custom_outbound.json ]] && cp custom_outbound.json /etc/V2bX/
    [[ ! -f /etc/V2bX/custom_inbound.json ]] && [[ -f custom_inbound.json ]] && cp custom_inbound.json /etc/V2bX/
    
    setup_service
    
    echo -e "${green}V2bX ${last_version} 安装完成${plain}"
}

create_default_config() {
    cat > /etc/V2bX/config.json << 'EOF'
{
    "Log": {
        "Level": "warning",
        "Output": ""
    },
    "Cores": [
        {
            "Type": "sing",
            "Name": "sing",
            "Log": {
                "Level": "error",
                "Timestamp": true
            },
            "NTP": {
                "Enable": false,
                "Server": "time.apple.com",
                "ServerPort": 123
            },
            "OriginalDest": true
        }
    ],
    "Nodes": [
        {
            "Core": "sing",
            "ApiHost": "https://your-panel.com",
            "ApiKey": "your-api-key",
            "NodeID": 1,
            "NodeType": "V2ray",
            "Timeout": 30,
            "RuleListPath": ""
        }
    ]
}
EOF
}

setup_service() {
    if [[ x"${release}" == x"alpine" ]]; then
        rm -f /etc/init.d/V2bX
        cat > /etc/init.d/V2bX << 'EOF'
#!/sbin/openrc-run

name="V2bX"
description="V2bX"

command="/usr/local/V2bX/V2bX"
command_args="server"
command_user="root"

pidfile="/run/V2bX.pid"
command_background="yes"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/V2bX
        rc-update add V2bX default
        echo -e "${green}已设置开机自启${plain}"
    else
        rm -f /etc/systemd/system/V2bX.service
        cat > /etc/systemd/system/V2bX.service << 'EOF'
[Unit]
Description=V2bX Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/V2bX/
ExecStart=/usr/local/V2bX/V2bX server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop V2bX 2>/dev/null
        systemctl enable V2bX
        echo -e "${green}已设置开机自启${plain}"
    fi
    
    # 创建管理脚本
    curl -o /usr/bin/V2bX -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/V2bX.sh 2>/dev/null
    if [[ $? -ne 0 ]] || [[ ! -f /usr/bin/V2bX ]]; then
        create_management_script
    fi
    chmod +x /usr/bin/V2bX
    
    if [[ ! -L /usr/bin/v2bx ]]; then
        ln -sf /usr/bin/V2bX /usr/bin/v2bx
    fi
    chmod +x /usr/bin/v2bx
    
    # 启动或提示配置
    if [[ "$first_install" == "true" ]]; then
        echo -e ""
        echo -e "${yellow}全新安装，请先编辑配置文件：/etc/V2bX/config.json${plain}"
        echo -e "${yellow}配置完成后运行: V2bX start${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service V2bX start
        else
            systemctl start V2bX
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}V2bX 重启成功${plain}"
        else
            echo -e "${red}V2bX 可能启动失败，请使用 V2bX log 查看日志${plain}"
        fi
    fi
    
    echo -e ""
    echo "V2bX 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "V2bX              - 显示管理菜单"
    echo "V2bX start        - 启动 V2bX"
    echo "V2bX stop         - 停止 V2bX"
    echo "V2bX restart      - 重启 V2bX"
    echo "V2bX status       - 查看 V2bX 状态"
    echo "V2bX log          - 查看 V2bX 日志"
    echo "V2bX update       - 更新 V2bX"
    echo "V2bX uninstall    - 卸载 V2bX"
    echo "V2bX version      - 查看 V2bX 版本"
    echo "------------------------------------------"
}

create_management_script() {
    cat > /usr/bin/V2bX << 'SCRIPT'
#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    [[ "$ID" == "alpine" ]] && INIT="openrc" || INIT="systemd"
else
    INIT="systemd"
fi

check_status() {
    if [[ ! -f /usr/local/V2bX/V2bX ]]; then
        return 2
    fi
    if [[ "$INIT" == "openrc" ]]; then
        [[ "$(service V2bX status | awk '{print $3}')" == "started" ]] && return 0 || return 1
    else
        [[ "$(systemctl status V2bX | grep Active | awk '{print $3}' | cut -d'(' -f2 | cut -d')' -f1)" == "running" ]] && return 0 || return 1
    fi
}

start() {
    check_status
    [[ $? == 0 ]] && echo -e "${yellow}V2bX 已在运行${plain}" && return
    [[ "$INIT" == "openrc" ]] && service V2bX start || systemctl start V2bX
    sleep 2
    check_status
    [[ $? == 0 ]] && echo -e "${green}V2bX 启动成功${plain}" || echo -e "${red}V2bX 启动失败，请查看日志${plain}"
}

stop() {
    check_status
    [[ $? != 0 ]] && echo -e "${yellow}V2bX 未运行${plain}" && return
    [[ "$INIT" == "openrc" ]] && service V2bX stop || systemctl stop V2bX
    echo -e "${green}V2bX 已停止${plain}"
}

restart() {
    [[ "$INIT" == "openrc" ]] && service V2bX restart || systemctl restart V2bX
    sleep 2
    check_status
    [[ $? == 0 ]] && echo -e "${green}V2bX 重启成功${plain}" || echo -e "${red}V2bX 重启失败${plain}"
}

status() {
    check_status
    case $? in
        0) echo -e "${green}V2bX 运行中${plain}" ;;
        1) echo -e "${yellow}V2bX 未运行${plain}" ;;
        2) echo -e "${red}V2bX 未安装${plain}" ;;
    esac
    [[ "$INIT" == "openrc" ]] && service V2bX status || systemctl status V2bX
}

log() {
    [[ "$INIT" == "openrc" ]] && tail -f /var/log/V2bX.log || journalctl -u V2bX -f
}

version() {
    /usr/local/V2bX/V2bX version
}

uninstall() {
    read -rp "确定要卸载 V2bX? [y/n]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    stop 2>/dev/null
    [[ "$INIT" == "openrc" ]] && { rc-update del V2bX default; rm -f /etc/init.d/V2bX; } || { systemctl disable V2bX; rm -f /etc/systemd/system/V2bX.service; systemctl daemon-reload; }
    rm -rf /usr/local/V2bX
    rm -f /usr/bin/V2bX /usr/bin/v2bx
    echo -e "${green}V2bX 已卸载，配置保留在 /etc/V2bX/${plain}"
}

update() {
    wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh && bash install.sh $1
}

show_menu() {
    echo -e "
${green}V2bX 管理脚本${plain}
————————————————
${green}1.${plain} 启动
${green}2.${plain} 停止  
${green}3.${plain} 重启
${green}4.${plain} 状态
${green}5.${plain} 日志
${green}6.${plain} 版本
${green}7.${plain} 更新
${green}8.${plain} 卸载
${green}0.${plain} 退出
————————————————"
    read -rp "请输入选项 [0-8]: " choice
    case "$choice" in
        1) start ;; 2) stop ;; 3) restart ;; 4) status ;;
        5) log ;; 6) version ;; 7) update ;; 8) uninstall ;;
        0) exit 0 ;; *) echo -e "${red}无效选项${plain}" ;;
    esac
}

case "$1" in
    start) start ;; stop) stop ;; restart) restart ;; status) status ;;
    log) log ;; version) version ;; update) update $2 ;; uninstall) uninstall ;;
    *) show_menu ;;
esac
SCRIPT
}

show_help() {
    echo -e "
${green}V2bX 安装脚本${plain}

用法: $0 [选项]

选项:
    无参数          下载预编译版本安装
    -b, --build    从源码编译安装 (使用最新 sing-box 内核)
    -h, --help     显示帮助信息

示例:
    bash $0           # 下载安装
    bash $0 -b        # 编译安装 (推荐，可解决 anytls 断流)
"
}

# 交互式生成配置文件
generate_config() {
    echo -e "${green}========================================${plain}"
    echo -e "${green}       V2bX 节点配置生成向导${plain}"
    echo -e "${green}========================================${plain}"
    echo -e ""
    
    # 输入 API 信息
    read -rp "请输入面板地址 (如 https://panel.example.com): " ApiHost
    read -rp "请输入面板 API Key: " ApiKey
    
    # 节点列表
    nodes_config=""
    cores_xray=false
    cores_sing=false
    
    while true; do
        echo -e ""
        echo -e "${green}添加节点配置${plain}"
        
        # 选择核心类型
        echo -e "${yellow}请选择节点核心类型：${plain}"
        echo -e "  ${green}1.${plain} sing (支持 anytls/vless/vmess/trojan/ss/hysteria/hysteria2/tuic)"
        echo -e "  ${green}2.${plain} xray (支持 vless/vmess/trojan/ss)"
        read -rp "请输入 [1-2]: " core_choice
        
        case "$core_choice" in
            1) core="sing"; cores_sing=true ;;
            2) core="xray"; cores_xray=true ;;
            *) core="sing"; cores_sing=true ;;
        esac
        
        # 输入节点 ID
        while true; do
            read -rp "请输入节点 Node ID: " NodeID
            if [[ "$NodeID" =~ ^[0-9]+$ ]]; then
                break
            else
                echo -e "${red}错误：请输入正确的数字${plain}"
            fi
        done
        
        # 选择节点类型
        echo -e "${yellow}请选择节点协议类型：${plain}"
        echo -e "  ${green}1.${plain} vmess"
        echo -e "  ${green}2.${plain} vless"
        echo -e "  ${green}3.${plain} trojan"
        echo -e "  ${green}4.${plain} shadowsocks"
        if [ "$core" == "sing" ]; then
            echo -e "  ${green}5.${plain} hysteria"
            echo -e "  ${green}6.${plain} hysteria2"
            echo -e "  ${green}7.${plain} tuic"
            echo -e "  ${green}8.${plain} anytls"
        fi
        read -rp "请输入 [1-8]: " type_choice
        
        case "$type_choice" in
            1) NodeType="vmess" ;;
            2) NodeType="vless" ;;
            3) NodeType="trojan" ;;
            4) NodeType="shadowsocks" ;;
            5) NodeType="hysteria" ;;
            6) NodeType="hysteria2" ;;
            7) NodeType="tuic" ;;
            8) NodeType="anytls" ;;
            *) NodeType="vmess" ;;
        esac
        
        # 证书配置
        certmode="none"
        certdomain=""
        
        if [[ "$NodeType" == "vless" ]]; then
            read -rp "是否为 Reality 节点? [y/n]: " isreality
            if [[ "$isreality" != "y" && "$isreality" != "Y" ]]; then
                read -rp "是否配置 TLS? [y/n]: " istls
            fi
        elif [[ "$NodeType" == "hysteria" || "$NodeType" == "hysteria2" || "$NodeType" == "tuic" || "$NodeType" == "anytls" ]]; then
            istls="y"
        else
            read -rp "是否配置 TLS? [y/n]: " istls
        fi
        
        if [[ "$istls" == "y" || "$istls" == "Y" ]] && [[ "$isreality" != "y" && "$isreality" != "Y" ]]; then
            echo -e "${yellow}请选择证书模式：${plain}"
            echo -e "  ${green}1.${plain} http - HTTP 自动申请 (域名需解析到本机)"
            echo -e "  ${green}2.${plain} dns  - DNS API 申请 (需配置 DNS 服务商 API)"
            echo -e "  ${green}3.${plain} self - 自签证书或已有证书"
            read -rp "请输入 [1-3]: " cert_choice
            
            case "$cert_choice" in
                1) certmode="http" ;;
                2) certmode="dns" ;;
                3) certmode="self" ;;
                *) certmode="http" ;;
            esac
            
            read -rp "请输入证书域名: " certdomain
        fi
        
        # 生成节点配置
        if [ -n "$nodes_config" ]; then
            nodes_config="${nodes_config},"
        fi
        
        node_json="{
            \"Core\": \"$core\",
            \"ApiHost\": \"$ApiHost\",
            \"ApiKey\": \"$ApiKey\",
            \"NodeID\": $NodeID,
            \"NodeType\": \"$NodeType\",
            \"Timeout\": 30,
            \"ListenIP\": \"0.0.0.0\",
            \"SendIP\": \"0.0.0.0\""
        
        if [ "$certmode" != "none" ]; then
            node_json="$node_json,
            \"CertConfig\": {
                \"CertMode\": \"$certmode\",
                \"CertDomain\": \"$certdomain\",
                \"CertFile\": \"/etc/V2bX/fullchain.cer\",
                \"KeyFile\": \"/etc/V2bX/cert.key\",
                \"Email\": \"v2bx@github.com\"
            }"
        fi
        
        node_json="$node_json
        }"
        
        nodes_config="${nodes_config}
        ${node_json}"
        
        echo -e "${green}节点配置已添加！${plain}"
        read -rp "是否继续添加节点? [y/n]: " continue_add
        if [[ "$continue_add" != "y" && "$continue_add" != "Y" ]]; then
            break
        fi
    done
    
    # 生成 Cores 配置
    cores_config=""
    if [ "$cores_sing" = true ]; then
        cores_config='{
            "Type": "sing",
            "Name": "sing",
            "Log": {
                "Level": "error",
                "Timestamp": true
            },
            "NTP": {
                "Enable": false,
                "Server": "time.apple.com",
                "ServerPort": 123
            },
            "OriginalDest": true
        }'
    fi
    
    if [ "$cores_xray" = true ]; then
        if [ -n "$cores_config" ]; then
            cores_config="${cores_config},"
        fi
        cores_config="${cores_config}
        {
            \"Type\": \"xray\",
            \"Name\": \"xray\",
            \"Log\": {
                \"Level\": \"warning\"
            }
        }"
    fi
    
    # 写入配置文件
    cat > /etc/V2bX/config.json << EOF
{
    "Log": {
        "Level": "warning",
        "Output": ""
    },
    "Cores": [
        $cores_config
    ],
    "Nodes": [
        $nodes_config
    ]
}
EOF
    
    echo -e ""
    echo -e "${green}========================================${plain}"
    echo -e "${green}配置文件已生成: /etc/V2bX/config.json${plain}"
    echo -e "${green}========================================${plain}"
    echo -e ""
    
    # 显示配置
    echo -e "${yellow}配置内容:${plain}"
    cat /etc/V2bX/config.json
    echo -e ""
    
    # 重启服务
    read -rp "是否立即启动 V2bX? [y/n]: " start_now
    if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
        if [[ -f /etc/init.d/V2bX ]]; then
            service V2bX restart
        else
            systemctl restart V2bX
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}V2bX 启动成功！${plain}"
        else
            echo -e "${red}V2bX 启动失败，请查看日志: V2bX log${plain}"
        fi
    fi
}

# 主程序
echo -e "${green}开始安装${plain}"

case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
    -b|--build)
        install_base
        build_install
        ;;
    *)
        install_base
        download_install
        ;;
esac

# 首次安装询问是否生成配置
if [[ "$first_install" == "true" ]]; then
    echo -e ""
    read -rp "检测到首次安装，是否现在配置节点? [y/n]: " if_generate
    if [[ "$if_generate" == "y" || "$if_generate" == "Y" ]]; then
        generate_config
    fi
fi

cd $cur_dir
rm -f install.sh v2bx.sh
