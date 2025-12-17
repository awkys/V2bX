#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
plain='\033[0m'

cur_dir=$(pwd)

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
    arch="amd64"
    arch_alt="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64"
    arch_alt="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
    arch_alt="s390x"
else
    arch="amd64"
    arch_alt="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo -e "${green}系统: ${release}${plain}"
echo -e "${green}架构: ${arch}${plain}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

# GitHub 仓库配置 - 修改为你自己的仓库
GITHUB_REPO="awkys/V2bX"
BINARY_NAME="V2bX"

install_base() {
    echo -e "${blue}安装基础依赖...${plain}"
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat ca-certificates >/dev/null 2>&1
    fi
    echo -e "${green}基础依赖安装完成${plain}"
}

install_golang() {
    echo -e "${blue}检查 Go 环境...${plain}"
    
    if command -v go &> /dev/null; then
        go_version=$(go version | awk '{print $3}' | sed 's/go//')
        echo -e "${green}已安装 Go ${go_version}${plain}"
        # 检查版本是否 >= 1.25
        required_version="1.25"
        if [ "$(printf '%s\n' "$required_version" "$go_version" | sort -V | head -n1)" = "$required_version" ]; then
            echo -e "${green}Go 版本满足要求${plain}"
            return 0
        else
            echo -e "${yellow}Go 版本过低，需要 >= 1.25${plain}"
        fi
    fi
    
    echo -e "${blue}安装 Go 1.25...${plain}"
    
    go_arch="$arch"
    if [[ $arch == "amd64" ]]; then
        go_arch="amd64"
    elif [[ $arch == "arm64" ]]; then
        go_arch="arm64"
    fi
    
    wget -q --show-progress -O /tmp/go.tar.gz "https://go.dev/dl/go1.25.4.linux-${go_arch}.tar.gz"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载 Go 失败${plain}"
        exit 1
    fi
    
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    
    # 设置环境变量
    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi
    export PATH=$PATH:/usr/local/go/bin
    
    echo -e "${green}Go 安装完成: $(go version)${plain}"
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

build_from_source() {
    echo -e "${blue}从源码编译 V2bX (使用官方 sing-box 最新内核)...${plain}"
    
    # 安装 Go
    install_golang
    
    # 克隆仓库
    build_dir="/tmp/V2bX-build"
    rm -rf $build_dir
    mkdir -p $build_dir
    cd $build_dir
    
    echo -e "${blue}克隆仓库...${plain}"
    git clone --depth 1 https://github.com/${GITHUB_REPO}.git .
    if [[ $? -ne 0 ]]; then
        echo -e "${red}克隆仓库失败${plain}"
        exit 1
    fi
    
    # 更新到官方最新 sing-box
    echo -e "${blue}更新 sing-box 到官方最新版本...${plain}"
    
    # 修改 go.mod 中的 replace
    sed -i 's|replace github.com/sagernet/sing-box.*|replace github.com/sagernet/sing-box v1.13.0 => github.com/sagernet/sing-box v1.13.0-alpha.29|' go.mod
    
    # 更新依赖
    echo -e "${blue}更新依赖...${plain}"
    go mod tidy
    if [[ $? -ne 0 ]]; then
        echo -e "${red}更新依赖失败${plain}"
        exit 1
    fi
    
    # 编译
    echo -e "${blue}编译中...${plain}"
    GOEXPERIMENT=jsonv2 CGO_ENABLED=0 go build -ldflags="-s -w" -o V2bX .
    if [[ $? -ne 0 ]]; then
        echo -e "${red}编译失败${plain}"
        exit 1
    fi
    
    echo -e "${green}编译完成${plain}"
    
    # 返回编译目录
    echo $build_dir
}

download_release() {
    echo -e "${blue}下载预编译版本...${plain}"
    
    # 获取最新版本
    last_version=$(curl -Ls "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ ! -n "$last_version" ]]; then
        # 如果获取失败，尝试从 wyx2685 仓库获取
        GITHUB_REPO="wyx2685/V2bX"
        last_version=$(curl -Ls "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    if [[ ! -n "$last_version" ]]; then
        echo -e "${red}获取版本失败，可能是超出 Github API 限制${plain}"
        return 1
    fi
    
    echo -e "${green}检测到最新版本: ${last_version}${plain}"
    
    download_dir="/tmp/V2bX-download"
    rm -rf $download_dir
    mkdir -p $download_dir
    cd $download_dir
    
    wget --no-check-certificate -N --progress=bar -O V2bX-linux.zip "https://github.com/${GITHUB_REPO}/releases/download/${last_version}/V2bX-linux-${arch_alt}.zip"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载失败${plain}"
        return 1
    fi
    
    unzip -q V2bX-linux.zip
    rm V2bX-linux.zip
    
    echo $download_dir
}

install_V2bX() {
    local install_mode=$1
    local source_dir=""
    
    if [[ -e /usr/local/V2bX/ ]]; then
        echo -e "${yellow}检测到已安装 V2bX，将进行升级${plain}"
        rm -rf /usr/local/V2bX/V2bX
    fi

    mkdir -p /usr/local/V2bX/
    mkdir -p /etc/V2bX/
    
    if [[ "$install_mode" == "build" ]]; then
        source_dir=$(build_from_source)
    else
        source_dir=$(download_release)
        if [[ $? -ne 0 ]]; then
            echo -e "${yellow}下载失败，尝试从源码编译...${plain}"
            source_dir=$(build_from_source)
        fi
    fi
    
    cd $source_dir
    
    # 复制文件
    cp V2bX /usr/local/V2bX/
    chmod +x /usr/local/V2bX/V2bX
    
    # 复制 geo 文件
    if [[ -f geoip.dat ]]; then
        cp geoip.dat /etc/V2bX/
    fi
    if [[ -f geosite.dat ]]; then
        cp geosite.dat /etc/V2bX/
    fi
    
    # 创建服务
    if [[ x"${release}" == x"alpine" ]]; then
        cat <<EOF > /etc/init.d/V2bX
#!/sbin/openrc-run

name="V2bX"
description="V2bX - V2board Node"

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
    else
        cat <<EOF > /etc/systemd/system/V2bX.service
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
        systemctl enable V2bX
    fi
    
    # 复制配置文件模板
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
    
    # 复制其他配置文件
    for conf_file in dns.json route.json custom_outbound.json custom_inbound.json; do
        if [[ ! -f /etc/V2bX/$conf_file ]] && [[ -f $conf_file ]]; then
            cp $conf_file /etc/V2bX/
        fi
    done
    
    # 清理
    cd /
    rm -rf /tmp/V2bX-build /tmp/V2bX-download
    
    # 创建管理脚本
    create_management_script
    
    echo -e ""
    echo -e "${green}========================================${plain}"
    echo -e "${green}V2bX 安装完成！${plain}"
    echo -e "${green}使用官方 sing-box v1.13.0-alpha.29 内核${plain}"
    echo -e "${green}========================================${plain}"
    echo -e ""
    
    # 显示版本信息
    /usr/local/V2bX/V2bX version 2>/dev/null || true
    
    echo -e ""
    echo -e "${blue}管理命令:${plain}"
    echo -e "  v2bx start    - 启动服务"
    echo -e "  v2bx stop     - 停止服务"
    echo -e "  v2bx restart  - 重启服务"
    echo -e "  v2bx status   - 查看状态"
    echo -e "  v2bx log      - 查看日志"
    echo -e "  v2bx config   - 编辑配置"
    echo -e ""
    
    if [[ "$first_install" == "true" ]]; then
        echo -e "${yellow}首次安装，请编辑配置文件: /etc/V2bX/config.json${plain}"
        echo -e "${yellow}配置完成后运行: v2bx start${plain}"
    else
        echo -e "${blue}重启服务中...${plain}"
        if [[ x"${release}" == x"alpine" ]]; then
            service V2bX restart
        else
            systemctl restart V2bX
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}V2bX 启动成功${plain}"
        else
            echo -e "${red}V2bX 启动失败，请查看日志: v2bx log${plain}"
        fi
    fi
}

create_default_config() {
    cat <<'EOF' > /etc/V2bX/config.json
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

create_management_script() {
    cat <<'SCRIPT' > /usr/bin/v2bx
#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 检测系统
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" == "alpine" ]]; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="systemd"
    fi
else
    INIT_SYSTEM="systemd"
fi

start() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        service V2bX start
    else
        systemctl start V2bX
    fi
    echo -e "${green}V2bX 已启动${plain}"
}

stop() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        service V2bX stop
    else
        systemctl stop V2bX
    fi
    echo -e "${yellow}V2bX 已停止${plain}"
}

restart() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        service V2bX restart
    else
        systemctl restart V2bX
    fi
    echo -e "${green}V2bX 已重启${plain}"
}

status() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        service V2bX status
    else
        systemctl status V2bX
    fi
}

log() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        tail -f /var/log/V2bX.log 2>/dev/null || echo "日志文件不存在"
    else
        journalctl -u V2bX -f
    fi
}

config() {
    ${EDITOR:-nano} /etc/V2bX/config.json
}

version() {
    /usr/local/V2bX/V2bX version
}

uninstall() {
    echo -e "${yellow}确定要卸载 V2bX 吗? [y/N]${plain}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        stop 2>/dev/null
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            rc-update del V2bX default
            rm -f /etc/init.d/V2bX
        else
            systemctl disable V2bX
            rm -f /etc/systemd/system/V2bX.service
            systemctl daemon-reload
        fi
        rm -rf /usr/local/V2bX
        rm -f /usr/bin/v2bx /usr/bin/V2bX
        echo -e "${green}V2bX 已卸载${plain}"
        echo -e "${yellow}配置文件保留在 /etc/V2bX/${plain}"
    fi
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
${green}6.${plain} 配置
${green}7.${plain} 版本
${green}8.${plain} 卸载
${green}0.${plain} 退出
————————————————
"
    read -p "请输入选项 [0-8]: " choice
    case "$choice" in
        1) start ;;
        2) stop ;;
        3) restart ;;
        4) status ;;
        5) log ;;
        6) config ;;
        7) version ;;
        8) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${red}无效选项${plain}" ;;
    esac
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) restart ;;
    status) status ;;
    log) log ;;
    config) config ;;
    version) version ;;
    uninstall) uninstall ;;
    *) show_menu ;;
esac
SCRIPT

    chmod +x /usr/bin/v2bx
    
    # 创建大写别名
    if [[ ! -L /usr/bin/V2bX ]]; then
        ln -sf /usr/bin/v2bx /usr/bin/V2bX
    fi
}

show_help() {
    echo -e "
${green}V2bX 安装脚本${plain} - 使用官方 sing-box 最新内核

用法: $0 [选项]

选项:
    -h, --help      显示帮助信息
    -b, --build     从源码编译安装 (推荐，使用最新 sing-box)
    -d, --download  下载预编译版本安装
    
不带参数默认尝试下载，失败则从源码编译
"
}

# 主程序
main() {
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -b|--build)
            install_base
            install_V2bX "build"
            ;;
        -d|--download)
            install_base
            install_V2bX "download"
            ;;
        *)
            install_base
            install_V2bX "auto"
            ;;
    esac
}

main "$@"

