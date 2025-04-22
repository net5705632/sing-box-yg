#!/bin/bash
export LANG=en_US.UTF-8
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
bblue='\033[0;34m'
plain='\033[0m'
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}

# 检查root权限
[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit

# 自动检测系统
if [[ -f /etc/redhat-release ]]; then
    release="Centos"
elif grep -q -E -i "alpine" /etc/issue; then
    release="alpine"
elif grep -q -E -i "debian" /etc/issue; then
    release="Debian"
elif grep -q -E -i "ubuntu" /etc/issue; then
    release="Ubuntu"
elif grep -q -E -i "centos|red hat|redhat" /etc/issue; then
    release="Centos"
elif grep -q -E -i "arch" /etc/issue; then
    red "脚本不支持Arch系统" && exit
else 
    red "不支持的系统" && exit
fi

# 自动安装依赖
install_dependencies() {
    if [[ x"${release}" == x"alpine" ]]; then
        apk update
        apk add wget curl tar jq tzdata openssl git socat iproute2 iptables grep qrencode
    else
        if [[ $release = Centos ]]; then
            yum install -y epel-release
            yum install -y wget curl tar jq openssl socat iptables-services iproute grep qrencode
        else
            apt update -y
            apt install -y wget curl tar jq openssl socat iptables-persistent iproute2 grep qrencode
        fi
    fi
}

# 生成随机端口
generate_port() {
    port=$(shuf -i 10000-65535 -n 1)
    while ss -tunlp | grep -q ":$port "; do
        port=$(shuf -i 10000-65535 -n 1)
    done
    echo $port
}

# 自动生成配置参数
generate_config() {
    # 生成UUID
    uuid=$(/etc/s-box/sing-box generate uuid)
    
    # 生成Reality密钥对
    key_pair=$(/etc/s-box/sing-box generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    
    # 生成端口
    port_vl_re=$(generate_port)
    port_vm_ws=$(generate_port)
    port_hy2=$(generate_port)
    port_tu=$(generate_port)
    
    # 自动获取域名
    ym_vl_re="www.yahoo.com"
    ym_vm_ws="www.bing.com"
    
    # 生成自签名证书
    openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key
    openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com"
}

# 安装Sing-box
install_singbox() {
    cpu=$(uname -m)
    case $cpu in
        x86_64) cpu=amd64 ;;
        aarch64) cpu=arm64 ;;
        *) red "不支持的CPU架构" && exit 1 ;;
    esac

    sbcore=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/v//')
    sbname="sing-box-${sbcore}-linux-${cpu}"
    wget -O /etc/s-box/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${sbcore}/${sbname}.tar.gz"
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv /etc/s-box/${sbname}/sing-box /etc/s-box/
    chmod +x /etc/s-box/sing-box
}

# 配置Argo隧道
setup_argo() {
    cloudflared tunnel --url http://localhost:${port_vm_ws} --no-autoupdate --protocol http2 > /etc/s-box/argo.log 2>&1 &
    argo_domain=$(grep -o 'https://[^/]*' /etc/s-box/argo.log | head -n 1 | sed 's/https:\/\///')
}

# 生成配置文件
generate_config_file() {
    cat > /etc/s-box/sb.json <<EOF
{
    "log": {"level": "info"},
    "inbounds": [
        {
            "type": "vless",
            "listen": "::",
            "listen_port": ${port_vl_re},
            "users": [{"uuid": "${uuid}", "flow": "xtls-rprx-vision"}],
            "tls": {
                "enabled": true,
                "server_name": "${ym_vl_re}",
                "reality": {
                    "enabled": true,
                    "handshake": {"server": "${ym_vl_re}", "server_port": 443},
                    "private_key": "${private_key}",
                    "short_id": ["${short_id}"]
                }
            }
        },
        {
            "type": "vmess",
            "listen": "::",
            "listen_port": ${port_vm_ws},
            "users": [{"uuid": "${uuid}", "alterId": 0}],
            "transport": {
                "type": "ws",
                "path": "/${uuid}-vm",
                "max_early_data": 2048
            },
            "tls": {
                "enabled": false,
                "server_name": "${ym_vm_ws}",
                "certificate_path": "/etc/s-box/cert.pem",
                "key_path": "/etc/s-box/private.key"
            }
        }
    ],
    "outbounds": [{"type": "direct"}]
}
EOF
}

# 配置systemd服务
setup_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl enable sing-box
    systemctl start sing-box
}

# 显示配置信息
show_config() {
    echo -e "${green}=== 安装完成 ===${plain}"
    echo -e "${blue}VLESS+Reality 配置：${plain}"
    echo -e "地址: $(curl -s4m5 icanhazip.com)\n端口: ${port_vl_re}\nUUID: ${uuid}\n公钥: ${public_key}\nSNI: ${ym_vl_re}\n短ID: ${short_id}"
    
    echo -e "\n${blue}VMess+WS 配置：${plain}"
    echo -e "地址: ${argo_domain}\n端口: 443\nUUID: ${uuid}\n路径: /${uuid}-vm\nTLS: 关闭"
    
    echo -e "\n${green}二维码：${plain}"
    qrencode -t ANSIUTF8 "vless://${uuid}@$(curl -s4m5 icanhazip.com):${port_vl_re}?security=reality&sni=${ym_vl_re}&pbk=${public_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#Reality"
}

# 主执行流程
main() {
    install_dependencies
    generate_config
    install_singbox
    generate_config_file
    setup_service
    setup_argo
    show_config
}

# 执行主函数
main
