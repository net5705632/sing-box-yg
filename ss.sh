#!/bin/bash
export LANG=en_US.UTF-8

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 系统检测
check_system() {
    if [[ -f /etc/redhat-release ]]; then
        release="Centos"
    elif cat /etc/issue | grep -q -E -i "debian"; then
        release="Debian"
    elif cat /etc/issue | grep -q -E -i "ubuntu"; then
        release="Ubuntu"
    elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
        release="Centos"
    elif cat /proc/version | grep -q -E -i "debian"; then
        release="Debian"
    elif cat /proc/version | grep -q -E -i "ubuntu"; then
        release="Ubuntu"
    elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
        release="Centos"
    else
        echo -e "${red}系统检测失败，请使用支持的系统！${plain}"
        exit 1
    fi
}

# 依赖安装
install_dependencies() {
    echo -e "${green}正在安装依赖...${plain}"
    if [[ x"${release}" == x"Centos" ]]; then
        yum install -y wget curl tar jq openssl
    else
        apt update -y
        apt install -y wget curl tar jq openssl
    fi
}

# 安装Sing-box
install_singbox() {
    echo -e "${green}正在安装Sing-box...${plain}"
    LATEST_VERSION=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        *)
            echo -e "${red}不支持的架构：${ARCH}${plain}"
            exit 1
            ;;
    esac
    
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${LATEST_VERSION#v}-linux-${ARCH}.tar.gz"
    
    wget -O sing-box.tar.gz ${DOWNLOAD_URL}
    tar -xzf sing-box.tar.gz
    cp sing-box-${LATEST_VERSION#v}-linux-${ARCH}/sing-box /usr/local/bin/
    mkdir -p /etc/sing-box
}

# 生成配置文件
generate_config() {
    echo -e "${green}生成配置文件...${plain}"
    UUID=$(uuidgen)
    PORT=$((RANDOM % 10000 + 20000))
    ARGO_DOMAIN=$(curl -s https://temp.xxooxxoo.xyz)

    cat > /etc/sing-box/config.json <<EOF
{
    "log": {
        "level": "info"
    },
    "inbounds": [
        {
            "type": "vmess",
            "listen": "0.0.0.0",
            "port": ${PORT},
            "protocol": "vmess",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "alterId": 0
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "/argo"
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom"
        }
    ]
}
EOF
}

# 配置Argo隧道
setup_argo() {
    echo -e "${green}配置Argo隧道...${plain}"
    wget -O cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(uname -m)
    chmod +x cloudflared
    nohup ./cloudflared tunnel --url http://localhost:${PORT} > argo.log 2>&1 &
}

# 配置服务
setup_service() {
    echo -e "${green}配置系统服务...${plain}"
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
}

# 显示配置信息
show_info() {
    echo -e "${green}安装完成！配置信息如下：${plain}"
    echo -e "${yellow}协议: VMESS${plain}"
    echo -e "${yellow}地址: ${ARGO_DOMAIN}${plain}"
    echo -e "${yellow}端口: 443${plain}"
    echo -e "${yellow}用户ID: ${UUID}${plain}"
    echo -e "${yellow}传输协议: WS${plain}"
    echo -e "${yellow}路径: /argo${plain}"
    echo -e "${yellow}TLS: 自动${plain}"
}

# 主函数
main() {
    check_system
    install_dependencies
    install_singbox
    generate_config
    setup_argo
    setup_service
    show_info
}

main
