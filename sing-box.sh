#!/bin/bash

# 定义颜色
re='\033[0m'
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple='\e[1;35m'
skybule="\e[1;36m"

# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
nginx_dir="/etc/nginx/nginx.conf"
log_dir="/var/log/singbox.log"

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && echo -e "${red}请在root用户下运行脚本${re}" && exit 1

# 检查 sing-box 是否已安装
check_singbox() {
if [ -f "${work_dir}/${server_name}" ]; then
    if [ -f /etc/alpine-release ]; then
        rc-service sing-box status | grep -q "started" && echo -e "${green}running${re}" && return 0 || echo -e "${yellow}not running${re}" && return 1
    else 
        [ "$(systemctl is-active sing-box)" = "active" ] && echo -e "${green}running${re}" && return 0 || echo -e "${yellow}not running${re}" && return 1
    fi
else
    echo -e "${red}not installed${re}"
    return 2
fi
}

# 检查 argo 是否已安装
check_argo() {
if [ -f "${work_dir}/argo" ]; then
    if [ -f /etc/alpine-release ]; then
        rc-service argo status | grep -q "started" && echo -e "${green}running${re}" && return 0 || echo -e "${yellow}not running${re}" && return 1
    else 
        [ "$(systemctl is-active argo)" = "active" ] && echo -e "${green}running${re}" && return 0 || echo -e "${ywllow}not running${re}" && return 1
    fi
else
    echo -e "${red}not installed${re}"
    return 2
fi
}

#根据系统类型安装、卸载依赖
manage_packages() {
    if [ $# -lt 2 ]; then
        echo -e "${red}Unspecified package name or action${re}" 
        return 1
    fi

    action=$1
    shift

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command -v "$package" &>/dev/null; then
                echo -e "${green}${package} already installed${re}"
                continue
            fi
            echo -e "${yellow}正在安装 ${package}...${re}"
            if command -v apt &>/dev/null; then
                apt install -y "$package"
            elif command -v dnf &>/dev/null; then
                dnf install -y "$package"
            elif command -v yum &>/dev/null; then
                yum install -y "$package"
            elif command -v apk &>/dev/null; then
                apk update
                apk add "$package"
            else
                echo -e "${red}Unknown system!${re}"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command -v "$package" &>/dev/null; then
                echo -e "${green}${package} is not installed${re}"
                continue
            fi
            echo -e "${yellow}正在卸载 ${package}...${re}"
            if command -v apt &>/dev/null; then
                apt remove -y "$package"
            elif command -v dnf &>/dev/null; then
                dnf remove -y "$package"
            elif command -v yum &>/dev/null; then
                yum remove -y "$package"
            elif command -v apk &>/dev/null; then
                apk del "$package"
            else
                echo -e "${red}Unknown system!${re}"
                return 1
            fi
        else
            echo -e "${red}Unknown action: $action${re}"
            return 1
        fi
    done

    return 0
}

# 下载并安装 sing-box,cloudflared
install_singbox() {
    clear
    echo -e "${purple}正在安装sing-box中，请稍后...${re}"
    # 判断系统架构
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l') ARCH='armv7' ;;
        's390x') ARCH='s390x' ;;
        *) echo -e"${red}不支持的架构: ${ARCH_RAW}${re}"; exit 1 ;;
    esac

    # 下载sing-box,cloudflared
    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}"
    latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[] | select(.prerelease==false)][0].tag_name | sub("^v"; "")')
    curl -sLo "${work_dir}/${server_name}.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${ARCH}.tar.gz"
    curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
    tar -xzf "${work_dir}/${server_name}.tar.gz" -C "${work_dir}/" && \
    mv "${work_dir}/sing-box-${latest_version}-linux-${ARCH}/sing-box" "${work_dir}/" && \
    rm -rf "${work_dir}/${server_name}.tar.gz" "${work_dir}/sing-box-${latest_version}-linux-${ARCH}"
    chown root:root ${work_dir} && chmod +x ${work_dir}/${server_name} ${work_dir}/argo

   # 生成随机端口和密码
    vless_port=$(shuf -i 1000-65535 -n 1) 
    vless_bru_port=$(($vless_port + 1)) 
    tuic_port=$(($vless_port + 2))
    hy2_port=$(($vless_port + 3)) 
    uuid=$(cat /proc/sys/kernel/random/uuid)
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
    output=$(/etc/sing-box/sing-box generate reality-keypair)
    private_key=$(echo "${output}" | grep -oP 'PrivateKey:\s*\K.*')
    public_key=$(echo "${output}" | grep -oP 'PublicKey:\s*\K.*')

    iptables -A INPUT -p tcp --dport 8088 -j ACCEPT
    iptables -A INPUT -p tcp --dport $vless_port -j ACCEPT
    iptables -A INPUT -p tcp --dport $vless_bru_port -j ACCEPT
    iptables -A INPUT -p udp --dport $hy2_port -j ACCEPT
    iptables -A INPUT -p udp --dport $tuic_port -j ACCEPT

    # 生成自签名证书
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

   # 生成配置文件
cat > "${config_dir}" << EOF
{
  "log": {
    "output": "${log_dir}",
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "address": "8.8.8.8",
        "address_resolver": "local"
      },
      {
        "tag": "local",
        "address": "local"
      }
    ]
  },
    "inbounds": [
    {
     "tag": "vless-tcp-vesion",
     "type": "vless",
     "listen": "::",
     "listen_port": ${vless_port},
     "users": [
         {
             "uuid": "${uuid}",
             "flow": "xtls-rprx-vision"
         }
     ],
     "tls": {
         "enabled": true,
         "server_name": "www.yahoo.com",
         "reality": {
             "enabled": true,
             "handshake": {
                 "server": "www.yahoo.com",
                 "server_port": 443
             },
             "private_key": "${private_key}",
             "short_id": [
                 ""
                ]
            }
        }
    },

    {
      "tag": "VLESS-Reality+Padding+Brutal",
      "type": "vless",
      "listen": "::",
      "listen_port": ${vless_bru_port},
      "sniff": true,
      "sniff_override_destination": false,
      "users": [
        {
          "uuid": "${uuid}",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "itunes.apple.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "itunes.apple.com",
            "server_port": 443
          },
          "private_key": "${private_key}",
          "short_id": [
            ""
          ]
        }
      },
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": 1000,
          "down_mbps": 500
        }
      }
    },

    {
      "tag": "vmess-ws",
      "type": "vmess",
      "listen": "::",
      "listen_port": 8088,
      "users": [
      {
        "uuid": "${uuid}"
      }
    ],
    "transport": {
      "type": "ws",
      "path": "/vmess",
      "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },

    {
       "tag": "hysteria2",
       "type": "hysteria2",
       "listen": "::",
       "listen_port": ${hy2_port},
       "users": [
         {
             "password": "${uuid}"
         }
     ],
     "masquerade": "https://bing.com",
     "tls": {
         "enabled": true,
         "alpn": [
             "h3"
         ],
         "certificate_path": "${work_dir}/cert.pem",
         "key_path": "${work_dir}/private.key"
        }
    },

    {
      "tag": "tuic",
      "type": "tuic",
      "listen": "::",
      "listen_port": ${tuic_port},
      "users": [
        {
          "uuid": "${uuid}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "${work_dir}/cert.pem",
        "key_path": "${work_dir}/private.key"
      }
    }

 ],
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct"
    },
    {
      "tag": "block",
      "type": "block"
    },
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "server": "engage.cloudflareclient.com",
      "server_port": 2408,
      "local_address": [
        "172.16.0.2/32",
        "2606:4700:110:812a:4929:7d2a:af62:351c/128"
      ],
      "private_key": "gBthRjevHDGyV0KvYwYE52NIPy29sSrVr6rcQtYNcXA=",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": [
        6,
        146,
        6
      ]
    }
  ],
  "route": {
    "geosite": {
      "download_url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/release/geosite.db",
      "download_detour": "direct"
    },
    "geoip": {
      "download_url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/release/geoip.db",
      "download_detour": "direct"
    },
    "rules": [
      {
        "geosite": [
          "netflix",
          "openai"
        ],
        "outbound": "wireguard-out"
      },
      {
        "geosite": ["geolocation-cn", "tld-cn"],
        "outbound": "wireguard-out"
      },
      {
        "geoip": "cn",
        "outbound": "wireguard-out"
      }
    ],
    "final": "direct"
  }
}
EOF
}
# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --url http://localhost:8088 --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl enable argo
    systemctl start argo
}
# 适配alpine 守护进程
alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run

description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    cat > /etc/init.d/argo << 'EOF'
#!/sbin/openrc-run

description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/sing-box/argo tunnel --url http://localhost:8088 --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1'"
command_background=true
pidfile="/var/run/argo.pid"
EOF

    chmod +x /etc/init.d/sing-box
    chmod +x /etc/init.d/argo

    rc-update add sing-box default
    rc-update add argo default

}

get_info() {  
  server_ip=$(curl -s ipv4.ip.sb || curl -s --max-time 1 ipv6.ip.sb)

  isp=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')

  argodomain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${work_dir}/argo.log" | sed 's@https://@@')

  echo -e "${green}ArgoDomain：${re}${purple}$argodomain${re}"

  VMESS="{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"www.visa.com.sg\", \"port\": \"443\", \"id\": \"${uuid}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess?ed=2048\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"randomized\", \"allowlnsecure\": \"flase\"}"

  cat > ${work_dir}/url.txt <<EOF
vless://${uuid}@${server_ip}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.yahoo.com&fp=chrome&pbk=${public_key}&type=tcp&headerType=none#${isp}

vless://${uuid}@${server_ip}:${vless_bru_port}?encryption=none&security=reality&sni=itunes.apple.com&fp=chrome&pbk=${public_key}&type=tcp&headerType=none&host=itunes.apple.com#${isp}

vmess://$(echo "$VMESS" | base64 -w0)

hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=www.bing.com&alpn=h3&insecure=1#${isp}

tuic://${uuid}:@${server_ip}:${tuic_port}?sni=www.bing.com&alpn=h3&insecure=1&congestion_control=bbr#${isp}
EOF
echo ""
while IFS= read -r line; do echo -e "${purple}$line${re}"; done < ${work_dir}/url.txt
base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt
echo ""
echo -e "${green}节点订阅链接：http://${server_ip}/${password}\n适用于V2rayN,Nekbox,Sterisand,小火箭,圈X等\n${re}"
qrencode -t ANSIUTF8 -m 2 "http://${server_ip}/${password}"
echo ""
}

# 修复nginx因host无法安装的问题
fix_nginx() {
    HOSTNAME=$(hostname)
    NGINX_CONFIG_FILE="/etc/nginx/nginx.conf"
    grep -q "127.0.1.1 $HOSTNAME" /etc/hosts || echo "127.0.1.1 $HOSTNAME" | tee -a /etc/hosts >/dev/null
    id -u nginx >/dev/null 2>&1 || useradd -r -d /var/www -s /sbin/nologin nginx >/dev/null 2>&1
    grep -q "^user nginx;" $NGINX_CONFIG_FILE || sed -i "s/^user .*/user nginx;/" $NGINX_CONFIG_FILE >/dev/null 2>&1
}

# nginx订阅配置
add_nginx_conf() {
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    cat > /etc/nginx/nginx.conf << EOF
# nginx_conf
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    server {
	listen 80;

        location /$password {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        }
    }
}
EOF

nginx -t

if [ $? -eq 0 ]; then
    if [ -f /etc/alpine-release ]; then
        nginx -s reload
        rc-service nginx restart
    else
        rm /run/nginx.pid
        systemctl daemon-reload
        systemctl restart nginx
    fi
fi
}

# 启动 sing-box
start_singbox() {
if [ ${check_singbox} -eq 1 ]; then
    echo -e "${yellow}正在启动 ${server_name} 服务\n${re}"
    if [ -f /etc/alpine-release ]; then
        rc-service sing-box start
    else
        systemctl daemon-reload
        systemctl start "${server_name}"
    fi
   if [ $? -eq 0 ]; then
       echo -e "${green}${server_name} 服务已成功启动\n${re}"
   else
       echo -e "${red}${server_name} 服务启动失败\n${re}"
   fi
elif [ ${check_singbox} -eq 0 ]; then
    echo -e "${yellow}sing-box 正在运行\n${re}"
    sleep 1
    menu
else
    echo -e "${yellow}sing-box 尚未安装！\n${re}"
    sleep 1
    menu
fi
}

# 停止 sing-box
stop_singbox() {
if [ ${check_singbox} -eq 0 ]; then
   echo -e "${yellow}正在停止 ${server_name} 服务\n${re}"
    if [ -f /etc/alpine-release ]; then
        rc-service sing-box stop
    else
        systemctl stop "${server_name}"
    fi
   if [ $? -eq 0 ]; then
       echo -e "${green}${server_name} 服务已成功停止\n${re}"
   else
       echo -e "${red}${server_name} 服务停止失败\n${re}"
   fi

elif [ ${check_singbox} -eq 1 ]; then
    echo -e "${yellow}sing-box 未运行\n${re}"
    sleep 1
    menu
else
    echo -e "${yellow}sing-box 尚未安装！\n${re}"
    sleep 1
    menu
fi
}

# 重启 sing-box
restart_singbox() {
if [ ${check_singbox} -eq 0 ]; then
   echo -e "${yellow}正在重启 ${server_name} 服务\n${re}"
    if [ -f /etc/alpine-release ]; then
        rc-service ${server_name} restart
    else
        systemctl daemon-reload
        systemctl restart "${server_name}"
    fi
    if [ $? -eq 0 ]; then
        echo -e "${green}${server_name} 服务已成功重启\n${re}"
    else
        echo -e "${red}${server_name} 服务重启失败\n${re}"
    fi
elif [ ${check_singbox} -eq 1 ]; then
    echo -e "${yellow}sing-box 未运行\n${re}"
    sleep 1
    menu
else
    echo -e "${yellow}sing-box 尚未安装！\n${re}"
    sleep 1
    menu
fi
}

# 重启 argo
restart_argo() {
if [ ${check_argo} -eq 0 ]; then
    echo -e "${yellow}正在重启 Argo 服务\n${re}"
    if [ -f /etc/alpine-release ]; then
        rc-service argo restart
    else
        systemctl daemon-reload
        systemctl restart argo
    fi
    if [ $? -eq 0 ]; then
        echo -e "${green}Argo 服务已成功重启\n${re}"
    else
        echo -e "${red}Argo 服务重启失败\n${re}"
    fi
elif [ ${check_argo} -eq 1 ]; then
    echo -e "${yellow}Argo 服务未运行\n${re}"
    sleep 1
    menu
else
    echo -e "${yellow}Argo 尚未安装！\n${re}"
    sleep 1
    menu
fi
}

# 启动 nginx
start_nginx() {
if command -v nginx &>/dev/null; then
    echo -e "${yellow}正在启动 nginx 服务\n${re}"
    if [ -f /etc/alpine-release ]; then
        rc-service nginx start
    else
        systemctl daemon-reload
        systemctl start nginx
    fi
    if [ $? -eq 0 ]; then
        echo -e "${green}Nginx 服务已成功启动\n${re}"
    else
        echo -e "${red}Nginx 启动失败\n${re}"
    fi
else
    echo -e "${yellow}Nginx 尚未安装！\n${re}"
    sleep 1
    menu
fi
}

# 卸载 sing-box
uninstall_singbox() {
   read -p "$(echo -e "${red}确定要卸载 sing-box 吗? (y/n) ${re}")" choice
   case "${choice}" in
       y|Y)
           echo -e "${yellow}正在卸载 sing-box${re}"
           if [ -f /etc/alpine-release ]; then
                rc-service sing-box stop
                rc-service argo stop
                rm /etc/init.d/sing-box /etc/init.d/argo
                rc-update del sing-box default
                rc-update del argo default
           else
                # 停止 sing-box和 argo 服务
                systemctl stop "${server_name}"
                systemctl stop argo
                # 禁用 sing-box 服务
                systemctl disable "${server_name}"
                systemctl disable argo

                # 重新加载 systemd
                systemctl daemon-reload || true
            fi
           # 删除配置文件和日志
           rm -rf "${work_dir}" || true
           rm -f "${log_dir}" || true
           
           # 卸载Nginx
           read -p "$(echo -e "${red}\n是否卸载 Nginx？(回车跳过卸载Nginx) (y/n) ${re}")" choice
            case "${choice}" in
                y|Y)
                    manage_packages uninstall nginx
                    ;;
                 *)
                    echo -e "${yellow}取消卸载Nginx\n${re}"
                    ;;
            esac

            echo -e "${green}\nsing-box 卸载成功\n${re}"
           ;;
       *)
           echo -e "${yellow}已取消卸载操作\n${re}"
           ;;
   esac
}

# 创建快捷指令
create_shortcut() {
  cat > "$work_dir/sb.sh" << EOF
#!/usr/bin/env bash

bash <(curl -Ls https://raw.githubusercontent.com/eooce/sing-box/main/sing-box.sh) \$1
EOF
  chmod +x "$work_dir/sb.sh"
  sudo ln -sf "$work_dir/sb.sh" /usr/bin/sb
  if [ -s /usr/bin/sb ]; then
    echo -e "${green}\nsb 快捷指令创建成功\n${re}"
  else
    echo -e "${red}\nsb 快捷指令创建失败\n${re}"
  fi
}

# 适配alpine运行argo报错用户组和dns的问题
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# 变更配置
change_config() {
if [ ${check_singbox} -eq 0 ]; then
    clear
    echo ""
    echo -e "${green}1. 修改端口${re}"
    echo "------------"
    echo -e "${green}2. 修改UUID${re}"
    echo "------------"
    echo -e "${green}3. 修改Reality伪装域名${re}"
    echo "------------"
    echo -e "${purple}4. 返回主菜单${re}"
    echo "------------"
    read -p $'\033[1;91m请输入选择: \033[0m' choice
    case "${choice}" in
        1)
            echo ""
            echo -e "${green}1. 修改vless-reality端口${re}"
            echo "------------"
            echo -e "${green}2. 修改hysteria2端口${re}"
            echo "------------"
            echo -e "${green}3. 修改tuic端口${re}"
            echo "------------"
            echo -e "${purple}4. 返回上一级菜单${re}"
            read -p $'\033[1;91m请输入选择: \033[0m' choice
            case "${choice}" in
                1)
                    read -p $'\033[1;35m请输入vless-reality端口 (回车跳过将使用随机端口): \033[0m' new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    sed -i '/"type": "vless"/,/listen_port/ s/"listen_port": [0-9]\+/"listen_port": '"$new_port"'/' $config_dir
                    restart_singbox
                    sed -i 's/\(vless:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt
                    while IFS= read -r line; do echo -e "${yellow}$line${re}"; done < ${work_dir}/url.txt
                    echo -e "${green}\nvless-reality端口已修改成：${purple}$new_port${re}${green} 请更新订阅或手动更改vless-reality端口\n${re}"
                    ;;
                2)
                    read -p $'\033[1;35m请输入hysteria2端口 (回车跳过将使用随机端口): \033[0m' new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    sed -i '/"type": "hysteria2"/,/listen_port/ s/"listen_port": [0-9]\+/"listen_port": '"$new_port"'/' $config_dir
                    restart_singbox
                    sed -i 's/\(hysteria2:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    base64 -w0 $client_dir > /etc/sing-box/sub.txt
                    while IFS= read -r line; do echo -e "${yellow}$line${re}"; done < ${work_dir}/url.txt
                    echo -e "${green}\nhysteria2端口已修改为：${purple}${new_port}${re}${green} 请更新订阅或手动更改hysteria2端口\n${re}"
                    ;;
                3)
                    read -p $'\033[1;35m请输入tuic端口 (回车跳过将使用随机端口): \033[0m' new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    sed -i '/"type": "tuic"/,/listen_port/ s/"listen_port": [0-9]\+/"listen_port": '"$new_port"'/' $config_dir
                    restart_singbox
                    sed -i 's/\(tuic:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    base64 -w0 $client_dir > /etc/sing-box/sub.txt
                    while IFS= read -r line; do echo -e "${yellow}$line${re}"; done < ${work_dir}/url.txt
                    echo -e "${green}\ntuic端口已修改为：${purple}${new_port}${re}${green} 请更新订阅或手动更改tuic端口\n${re}"
                    ;;
                4)
                    change_config
                    ;;
                *)
                    echo -e "${red}无效的选项，请输入 1 到 4${re}"
                    ;;
            esac
            ;;
        2)
            read -p $'\033[1;35m请输入新的UUID: \033[0m' new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            sed -i -E '
                s/"uuid": "([a-f0-9-]+)"/"uuid": "'"$new_uuid"'"/g;
                s/"uuid": "([a-f0-9-]+)"$/\"uuid\": \"'$new_uuid'\"/g;
                s/"password": "([a-f0-9-]+)"/"password": "'"$new_uuid"'"/g
            ' $config_dir

            restart_singbox
            sed -i -E 's/(vless:\/\/|hysteria2:\/\/)[^@]*(@.*)/\1'"$new_uuid"'\2/' $client_dir
            sed -i "s/tuic:\/\/[0-9a-f\-]\{36\}/tuic:\/\/$new_uuid/" /etc/sing-box/url.txt
            isp=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')
            argodomain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${work_dir}/argo.log" | sed 's@https://@@')
            VMESS="{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"www.visa.com.sg\", \"port\": \"443\", \"id\": \"${new_uuid}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess?ed=2048\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"randomized\", \"allowlnsecure\": \"flase\"}"
            encoded_vmess=$(echo "$VMESS" | base64 -w0)
            sed -i -E '/vmess:\/\//{s@vmess://.*@vmess://'"$encoded_vmess"'@}' $client_dir
            base64 -w0 $client_dir > /etc/sing-box/sub.txt
            while IFS= read -r line; do echo -e "${yellow}$line${re}"; done < ${work_dir}/url.txt
            echo -e "${green}\nUUID已修改为：${re}${purple}${new_uuid}${re}${green} 请更新订阅或手动更改所有节点的UUID\n${re}"
            ;;
        3)  
            clear
            echo -e "${green}1. itunes.apple.com\n2. addons.mozilla.org${re}"
            read -p $'\033[1;35m请输入新的Reality伪装域名(可自定义输入,回车留空将使用默认1): \033[0m' new_sni
                if [ -z "$new_sni" ]; then    
                    new_sni="itunes.apple.com"
                elif [[ "$new_sni" == "1" ]]; then
                    new_sni="itunes.apple.com"
                elif [[ "$new_sni" == "2" ]]; then
                    new_sni="addons.mozilla.org"
                else
                    new_sni="$new_sni"
                fi
                jq --arg new_sni "$new_sni" '
                (.inbounds[] | select(.type == "vless") | .tls.server_name) = $new_sni |
                (.inbounds[] | select(.type == "vless") | .tls.reality.handshake.server) = $new_sni
                ' "$config_dir" > "$config_file.tmp" && mv "$config_file.tmp" "$config_dir"
                restart_singbox
                sed -i "s/\(vless:\/\/[^\?]*\?\([^\&]*\&\)*sni=\)[^&]*/\1$new_sni/" $client_dir
                base64 -w0 $client_dir > /etc/sing-box/sub.txt
                while IFS= read -r line; do echo -e "${yellow}$line${re}"; done < ${work_dir}/url.txt
                echo ""
                echo -e "${green}\nReality sni已修改为：${re}${purple}${new_sni}${re}${green} 请更新订阅或手动更改reality节点的sni域名\n${re}"
            ;; 
        4)
            menu
            ;; 
        *)
            echo -e "${red}无效的选项！${re}"
            ;; 
    esac
else
    echo -e "${yellow}sing-box 尚未安装！${re}"
    sleep 1
    menu
fi
}

disable_open_sub() {
if [ ${check_singbox} -eq 0 ]; then
    clear
    echo ""
    echo -e "${green}1. 关闭节点订阅${re}"
    echo "------------"
    echo -e "${green}2. 开启节点订阅${re}"
    echo "------------"
    echo -e "${purple}3. 返回主菜单${re}"
    echo "------------"
    read -p $'\033[1;91m请输入选择: \033[0m' choice
    case "${choice}" in
        1)
            if command -v nginx &>/dev/null; then
                if [ -f /etc/alpine-release ]; then
                    rc-service argo status | grep -q "started" && rc-service nginx stop || echo -e "${red}nginx not running${re}"
                else 
                    [ "$(systemctl is-active argo)" = "active" ] && systemctl stop nginx || echo -e "${red}ngixn not running${re}"
                fi
            else
                echo -e "${red}Nginx is not installed${re}"
            fi

            echo -e "${green}\n已关闭节点订阅\n${re}"     
            ;; 
        2)
            echo -e "${green}\n已开启节点订阅\n${re}"
            server_ip=$(curl -s ipv4.ip.sb || curl -s --max-time 1 ipv6.ip.sb)
            password=$(tr -dc A-Za-z < /dev/urandom | head -c 32) 
            sed -i -E "s/(location \/)[^ ]+/\1${password//\//\\/}/" /etc/nginx/nginx.conf
            start_nginx
            echo -e "${green}\n新的节点订阅链接：http://${server_ip}/${password}\n${re}"
            ;; 
        3)
            menu
            ;; 
        *)
            echo -e "${red}无效的选项！${re}"
            ;; 
    esac
else
    echo -e "${yellow}sing-box 尚未安装！${re}"
    sleep 1
    menu
fi
}

# 主菜单
menu() {
   check_singbox &>/dev/null; check_singbox=$?
   check_argo &>/dev/null; check_argo=$?
   check_singbox_status=$(check_singbox)
   check_argo_status=$(check_argo)
   clear
   echo ""
   echo -e "${purple}=== 老王sing-box一键安装脚本 ===${re}"
   echo -e "${green}sing-box 状态: ${check_singbox_status}${re}   ${green}Argo 状态: ${check_argo_status}${re}"
   echo ""
   echo -e "${green}1. 安装 sing-box${re}"
   echo -e "${red}2. 卸载 sing-box${re}"
   echo -e "${green}=================${re}"
   echo -e "${green}3. 启动 sing-box${re}"
   echo -e "${yellow}4. 停止 sing-box${re}"
   echo -e "${green}5. 重启 sing-box${re}"
   echo -e "${green}=================${re}"
   echo -e "${green}6. 查看节点信息${re}"
   echo -e "${green}7. 修改节点配置${re}"
   echo -e "${green}8. 重新获取Argo域名${re}"
   echo -e "${green}=================${re}"
   echo -e "${green}9. 管理节点订阅${re}"
   echo -e "${purple}w. ssh综合工具箱${re}"
   echo -e "${green}=================${re}"
   echo -e "${red}0. 退出脚本${re}"
   echo -e "${green}=================${re}"
   read -p $'\033[1;91m请输入选择(0-w): \033[0m' choice
   echo ""
}

# 捕获 Ctrl+C 信号
trap 'echo "已取消操作"; exit' INT

# 主循环
while true; do
   menu
   case "${choice}" in
        1)  
            if [ ${check_singbox} -eq 0 ]; then
                echo -e "${green}sing-box 已经安装！${re}"
            else
                fix_nginx
                manage_packages install nginx jq tar iptables openssl coreutils qrencode
                install_singbox

                if [ -x "$(command -v systemctl)" ]; then
                    main_systemd_services
                elif [ -x "$(command -v rc-update)" ]; then
                    alpine_openrc_services
                    change_hosts
                    rc-service sing-box restart
                    rc-service argo restart
                else
                    echo "Unsupported init system"
                    exit 1 
                fi

                sleep 2
                get_info
                add_nginx_conf
                create_shortcut
            fi
           ;;
        2) uninstall_singbox ;;
        3) start_singbox ;;
        4) stop_singbox ;;
        5) restart_singbox ;;
        6)
           if [ ${check_singbox} -eq 0 ]; then
               while IFS= read -r line; do echo -e "${purple}$line${re}"; done < ${work_dir}/url.txt
               echo ""
           else 
               echo -e "${yellow}sing-box 尚未安装！${re}"
               sleep 1
               menu
           fi
           ;;
        7) change_config ;;
        8)
           clear
            restart_argo
            echo -e "${yellow}获取argo域名中，请稍等...\n${re}"
            sleep 3
            get_argodomain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${work_dir}/argo.log" | sed 's@https://@@')
            echo -e "${green}ArgoDomain：${re}${purple}$get_argodomain${re}"
            ArgoDomain=$get_argodomain
            content=$(cat "$client_dir")
            vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir")
            vmess_prefix="vmess://"
            encoded_vmess="${vmess_url#"$vmess_prefix"}"
            decoded_vmess=$(echo "$encoded_vmess" | base64 --decode)
            updated_vmess=$(echo "$decoded_vmess" | jq --arg new_domain "$ArgoDomain" '.host = $new_domain | .sni = $new_domain')
            encoded_updated_vmess=$(echo "$updated_vmess" | base64 | tr -d '\n')
            new_vmess_url="$vmess_prefix$encoded_updated_vmess"
            new_content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
            echo "$new_content" > "$client_dir"
            base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt
            echo -e "${green}\nvmess已更新到节点文件中,更新订阅或手动复制以下vmess-argo节点\n${re}"
            echo -e "${yellow}$new_vmess_url\n${re}"              
           ;;
        9)
           disable_open_sub
           ;;
        w|W)
           clear
           curl -fsSL https://raw.githubusercontent.com/eooce/ssh_tool/main/ssh_tool.sh -o ssh_tool.sh && chmod +x ssh_tool.sh && ./ssh_tool.sh
           ;;           
        0)
           exit 0
           ;;
        *)
           echo -e "${red}无效的选项，请输入 0 到 w${re}"
           ;;
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m' 
done
