#!/bin/bash

# 命令失败就退出
#set -e

# 检测当前用户运行该脚本是否使用bash，而不是sh
if readlink /proc/$$/exe | grep -q "dash"; then
    echo '需要使用bash运行脚本，而不是sh'
    exit
fi

# 交互式脚本中，无阻塞地清空标准输入缓冲区，防止用户之前随意按下的按键影响后续行为
read -N 999999 -t 0.001

# 内核版本号是否过低
if [[ $(uname -r | cut -d "." -f 1) -eq 2 ]]; then
    echo "内核版本过低，无法运行脚本"
    exit
fi

# 检测操作系统，系统版本，依赖项和兼容性
os="unknown"
os_version="unknown"
group_name="nogroup"
# 检测操作系统
if grep -qs "ubuntu" /etc/os-release; then
    os="ubuntu"
    os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
    group_name="nogroup"
elif grep -qs "debian" /etc/os-release; then
    os="debian"
    os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
    group_name="nogroup"
elif grep -qs "centos" /etc/os-release; then
    os="centos"
    os_version=$(grep -shoE '[0-9]+' /etc/centos-release | head -1)
    group_name="nobody"
else
    echo "安装程序无法在不受支持的发行版上运行"
    exit
fi
# 检测系统版本
if [[ "$os" == "ubuntu" && "$os_version" -lt 1804 ]]; then
    echo "运行安装程序需要 Ubuntu 18.04 及其以上版本"
    exit
fi
if [[ "$os" == "debian" && "$os_version" -lt 9 ]]; then
    echo "运行安装程序需要 Debian 9 及其以上版本"
    exit
fi
if [[ "$os" == "centos" && "$os_version" -lt 7 ]]; then
    echo "运行安装程序需要 CentOS 7 及其以上版本"
    exit
fi
# 检测环境变量是否包含 sbin 目录
if ! grep -q sbin <<<"$PATH"; then
    echo '$PATH 环境变量没有包含 sbin，切换超级用户 root 尝试使用 "su -" 而不是 "su"'
    exit
fi
# 检测是否有超级用户权限
if [[ "$EUID" -ne 0 ]]; then
    echo "安装程序没有超级用户 root 权限"
    exit
fi
# 检测是否有TUN 虚拟网络设备
if [[ ! -e /dev/net/tun ]] || ! (exec 7<>/dev/net/tun) 2>/dev/null; then
    echo "系统没有 TUN 虚拟网络设备"
    exit
fi
# 自动检测包管理器并确定 expect 的路径
if [ -x "$(command -v apt)" ]; then
    EXPECT_CMD="/usr/bin/expect"
elif [ -x "$(command -v yum)" ]; then
    EXPECT_CMD="/usr/bin/expect"
else
    EXPECT_CMD="/usr/bin/env expect"
fi

# 判断系统版本，根据不同系统选择不同的安装命令
if grep -qs "centos" /etc/os-release; then
    if [[ "$os_version" -eq "7" ]]; then
        PKG_MANAGER="yum"
    else
        PKG_MANAGER="dnf"
    fi
    UPDATE_CMD="$PKG_MANAGER check-update -y"
    INSTALL_CMD="$PKG_MANAGER install -y"
    REINSTALL_CMD="$PKG_MANAGER reinstall -y"
    REMOVE_CMD="$PKG_MANAGER remove -y"
    PURGE_CMD="$PKG_MANAGER remove -y"
    AUTORM_CMD="$PKG_MANAGER remove -y"
elif grep -qs "ubuntu\|debian" /etc/os-release; then
    PKG_MANAGER="apt"
    UPDATE_CMD="$PKG_MANAGER update -y"
    INSTALL_CMD="$PKG_MANAGER install -y"
    REINSTALL_CMD="$PKG_MANAGER install -y --reinstall -o Dpkg::Options::=--force-confmiss"
    REMOVE_CMD="$PKG_MANAGER remove -y"
    PURGE_CMD="$PKG_MANAGER purge -y"
    AUTORM_CMD="$PKG_MANAGER autoremove --purge"
else
    echo "当前系统不受支持！"
    exit
fi


OCSERV="/etc/ocserv"
OCSERV_CONF="$OCSERV/ocserv.conf"
PORT="443"
IPV4="10.10.10.0"


# 配置文件修改函数
# 参数: 配置文件路径 配置项名称 配置项的值
# 行为:
#   1. 存在未注释的配置行 → 替换所有匹配行的值，保留等号前后空白
#   2. 仅有注释行        → 在第一处注释下方插入一行新配置（带相同缩进）
#   3. 完全不存在        → 在文件末尾追加一行配置
set_config_value() {
    local file="$1"
    local key="$2"
    shift 2
    local values=("$@")                     # 所有待赋值的列表
    local num_vals=${#values[@]}

    [[ -f "$file" ]] || { echo "错误：文件 $file 不存在" >&2; return 1; }
    [[ -n "$key" ]]   || { echo "错误：配置项不能为空" >&2; return 1; }

    # 转义 key 中的正则特殊字符
    local key_re
    key_re=$(sed 's/[.[\*^$()+?{|]/\\&/g' <<< "$key")

    # --- 场景1：存在非注释行 → 替换值 ---
    if grep -qE "^\s*${key_re}\s*=" "$file"; then
        if [[ $num_vals -eq 1 ]]; then
            # ---- 单值模式（原有逻辑） ----
            local val_esc
            val_esc=$(sed -e 's/[&\\]/\\&/g' -e 's/|/\\|/g' <<< "${values[0]}")
            sed -i -E "/^\s*#/! s|^([[:space:]]*${key_re}[[:space:]]*=[[:space:]]*)[^[:space:]]*(.*)|\1${val_esc}\2|" "$file"
            echo "已更新所有非注释的「${key}」行。"
        else
            # ---- 多值逐个赋值 ----
            local -a linenums
            mapfile -t linenums < <(grep -nE "^\s*${key_re}\s*=" "$file" | cut -d: -f1)
            local limit=$(( num_vals < ${#linenums[@]} ? num_vals : ${#linenums[@]} ))
            for (( i=0; i<limit; i++ )); do
                local cur_ln="${linenums[$i]}"
                local cur_val="${values[$i]}"
                local val_esc
                val_esc=$(sed -e 's/[&\\]/\\&/g' -e 's/|/\\|/g' <<< "$cur_val")
                sed -i -E "${cur_ln}s|^([[:space:]]*${key_re}[[:space:]]*=[[:space:]]*)[^[:space:]]*(.*)|\1${val_esc}\2|" "$file"
            done
            echo "已按顺序更新前 ${limit} 个「${key}」行。"
        fi
        return 0
    fi

    # --- 场景2：仅有注释行 → 只在第一处注释下方插入新行 ---
    if grep -qE "^\s*#\s*${key_re}\s*=" "$file"; then
        local first_line
        first_line=$(grep -nE "^\s*#\s*${key_re}\s*=" "$file" | head -1 | cut -d: -f1)
        if [[ -n "$first_line" ]]; then
            sed -i "${first_line}a\\${key} = ${values[0]}" "$file"
            echo "已在第 ${first_line} 行注释下方插入「${key} = ${values[0]}」。"
        fi
        return 0
    fi

    # --- 场景3：完全不存在 → 追加到末尾 ---
    echo "" >> "$file"
    echo "${key} = ${values[0]}" >> "$file"
    echo "已在文件末尾追加「${key} = ${values[0]}」。"
}

# 添加用户
function add_user() {
    # 获取 VPN 用户名和组别
    read -p "请输入您的 VPN 用户名（默认为 guest）： " user_name
    user_name=${user_name:-guest}
    read -p "请输入您的 VPN 用户组别（默认为 default）： " user_group
    user_group=${user_group:-default}

    read -s -p "请输入您的密码（默认为 guest）： " user_pass
    echo
    user_pass=${user_pass:-guest}

    $EXPECT_CMD <<-END
    spawn ocpasswd -c /etc/ocserv/ocpasswd -g $user_group $user_name
    expect "Enter password:"
    send "$user_pass\r"
    expect "Re-enter password:"
    send "$user_pass\r"
    expect eof
    exit
END
}

# 移除用户
function remove_user() {
    # 获取要删除用户的用户名
    read -p "请输入您想要删除的用户名: " user_name
    if  [[ -z "$user_name" ]]; then
        echo "您没有输入用户名，请重新执行程序"
        return -1 # 返回非零值表示失败
    fi

    # 使用 ocpasswd 命令删除用户
    if ocpasswd -c $OCSERV/ocpasswd -d $user_name; then
        echo "$user_name 用户已成功删除"
        # 重启 ocserv 服务
        if systemctl restart ocserv.service; then
            echo "ocserv 服务已重启。"
            return 0
        else
            echo "ocserv 服务重启失败，请手动重启。"
            return -1
        fi
    else
        echo "删除 $user_name 用户失败，可能用户不存在。"
        return -1
    fi
}

# 启动或重启 ocserv
function restart_ocserv() {
    if pgrep "ocserv" >/dev/null; then
        echo "正在重启 ocserv ..."
        systemctl restart ocserv
    else
        echo "正在启动 ocserv ..."
        systemctl start ocserv
    fi
}

# 关闭 ocserv
function stop_ocserv() {
    echo "正在关闭 ocserv ..."
    systemctl stop ocserv
}

# 查看ocserv状态
function status_ocserv() {
    systemctl status ocserv
}

# 卸载ocserv
function uninstall_ocserv() {
    echo "卸载 ocserv ..."
    # 停掉当前正在运行的 ocserv 程序
    stop_ocserv
    # 彻底卸载 ocserv，删除所有配置
    #$PURGE_CMD ocserv
    # 仅卸载 ocserv，保留配置
    $REMOVE_CMD ocserv
    # 清除已卸载但未清理的残留包和配置缓存
    #$AUTORM_CMD
    rm -rf $OCSERV
    echo "ocserv 卸载完成！"
}

# 检查并安装 iptables（如果尚未安装）
function install_iptables() {
    if ! command -v iptables &>/dev/null; then
        echo "Installing iptables..."
        if [[ "$os" == "centos" ]]; then
            $UPDATE_CMD && $INSTALL_CMD iptables-services
            systemctl start iptables
            systemctl enable iptables
        elif [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
            $UPDATE_CMD && $INSTALL_CMD iptables
            systemctl start netfilter-persistent
            systemctl enable netfilter-persistent
        else
            echo "不支持的操作系统"
            exit
        fi
    fi
}

# 配置 ipv4防火墙
function config_ipv4_firewall() {
    echo "配置 ipv4防火墙 ..."
    echo "net.ipv4.ip_forward = 1" | tee /etc/sysctl.d/99-custom.conf

    echo "开启bbr ..."
    if [[ "$os" == "centos" ]]; then
        if [[ "$os_version" -eq "8" ]]; then
            echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.d/99-custom.conf
            echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.d/99-custom.conf
        elif [[ "$os_version" -eq "7" ]]; then
            rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
            rpm -Uvh https://www.elrepo.org/elrepo-release-7.0-3.el7.elrepo.noarch.rpm
            yum --enablerepo=elrepo-kernel install kernel-ml -y
            # egrep ^menuentry /etc/grub2.cfg | cut -f 2 -d \'
            # grub2-set-default 0
            # grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
    elif [[ "$os" == "ubuntu" ]]; then
        echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.d/99-custom.conf
        echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.d/99-custom.conf
    elif [[ "$os" == "debian" ]]; then
        echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.d/99-custom.conf
        echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.d/99-custom.conf
    else
        echo "不支持的操作系统"
    fi

    # 配置立即生效
    sysctl -p /etc/sysctl.d/99-custom.conf

    # 获取默认网卡名称
    default_interface=$(ip route show | sed -n 's/^default.* dev \([^ ]*\).*/\1/p')

    # 检查是否成功获取网卡名称
    if [ -z "$default_interface" ]; then
        echo "无法获取默认网络接口。本脚本不支持当前系统配置。"
        exit
    fi

    echo "使用默认网络接口：$default_interface"

    # 检查并安装 iptables（如果尚未安装）
    install_iptables

    # 配置防火墙规则
    echo "配置 iptables 防火墙规则..."
    iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
    iptables -A INPUT -p udp --dport $PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -t nat -A POSTROUTING -s ${IPV4}/24 -o $default_interface -j MASQUERADE
    iptables -A FORWARD -s ${IPV4}/24 -j ACCEPT
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

    # 保存 iptables 规则
    if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
        netfilter-persistent save
    elif [[ "$os" == "centos" ]]; then
        iptables-save >/etc/sysconfig/iptables
    else
        iptables-save >/etc/iptables/rules.v4
    fi

    echo "IPv4 防火墙配置完成，iptables 规则已设置。"
}

function config_server_cert() {
    # 安装 cron
    $INSTALL_CMD cron || {
        echo "安装 socat 失败"
    }
    # 安装 socat
    $INSTALL_CMD socat || {
        echo "安装 socat 失败"
    }

    # 获取公网IP
    public_ip=$(curl -s http://ip1.dynupdate.no-ip.com/ || curl -s http://icanhazip.com/)
    echo "公网 IP: $public_ip"

    # 获取安装路径
    mkdir -p $OCSERV/ssl
    CERT_DIR="$OCSERV/ssl"
    CA_KEY="${CERT_DIR}/ca-key.key"
    CA_CERT="${CERT_DIR}/ca-cert.pem"
    SERVER_KEY="${CERT_DIR}/server-key.key"
    SERVER_CERT="${CERT_DIR}/server-cert.pem"

    # 安装两种类型的证书，长期自签名证书 + 自动续期的受信任IP证书
    # 1. 长期自签名证书
    echo "安装长期自签名证书"
    # ---- 1. 创建 CA 模板 ----
    cat > "${CERT_DIR}/ca.tmpl" <<EOF
cn = "Ocserv Self-Signed CA"
organization = "Personal VPN"
serial = 1
expiration_days = 3650
ca
signing_key
cert_signing_key
crl_signing_key
EOF

    # ---- 2. 创建服务器证书模板 ----
    cat > "${CERT_DIR}/server.tmpl" <<EOF
cn = "$public_ip"
organization = "Personal VPN"
serial = 2
expiration_days = 3650
signing_key
encryption_key
tls_www_server
EOF

    # ---- 3. 生成 CA 私钥并自签 CA 证书 ----
    echo "正在生成 CA 私钥和证书..."
    certtool --generate-privkey --outfile "$CA_KEY"
    certtool --generate-self-signed --load-privkey "$CA_KEY" --template "${CERT_DIR}/ca.tmpl" --outfile "$CA_CERT"

    # ---- 4. 生成服务器私钥并用 CA 签发服务器证书 ----
    echo "正在生成服务器证书..."
    certtool --generate-privkey --outfile "$SERVER_KEY"
    certtool --generate-certificate --load-privkey "$SERVER_KEY" \
        --load-ca-certificate "$CA_CERT" --load-ca-privkey "$CA_KEY" \
        --template "${CERT_DIR}/server.tmpl" --outfile "$SERVER_CERT"

    # ---- 5. 设置安全权限 ----
    chmod 600 "$CA_KEY" "$SERVER_KEY"
    chmod 644 "$CA_CERT" "$SERVER_CERT"

    # ---- 6. 修改 ocserv.conf ----
    echo "正在更新 ocserv 配置..."
    set_config_value $OCSERV_CONF "server-cert" "$SERVER_CERT"
    set_config_value $OCSERV_CONF "server-key" "$SERVER_KEY"

    # 2. 自动续期的受信任IP证书 (acme.sh + Let's Encrypt)
    # 第一步：安装 acme.sh
    echo "安装自动续期的受信任IP证书"
    read -p "请输入您的Email(默认为 912218233@qq.com): " mail_address
    if [ -z "$mail_address" ]; then
        mail_address="912218233@qq.com"
    fi
    curl https://get.acme.sh | sh -s email=$mail_address
    export PATH="$PATH:$HOME/.acme.sh"
    alias acme.sh=$HOME/.acme.sh/acme.sh

    # 第二步：申请 Let's Encrypt IP 证书
    # Standalone 模式 (无Web服务)
    acme.sh --issue --server letsencrypt -d $public_ip --certificate-profile shortlived --standalone
    # Nginx/Apache 模式 (有Web服务)
    #acme.sh --issue --server letsencrypt -d $public_ip --certificate-profile shortlived --nginx #--apache

    # 第三步：在 ocserv 中配置证书
    set_config_value $OCSERV_CONF "server-cert" "$SERVER_CERT"
    set_config_value $OCSERV_CONF "server-key" "$SERVER_KEY"

    # 第四步：设置安装与自动续期
    acme.sh --install-cert -d $public_ip \
        --key-file       $SERVER_KEY     \
        --fullchain-file $SERVER_CERT    \
        --reloadcmd "systemctl restart ocserv"
}

function install_ocserv() {
    # 如果有残存的配置文件，删除干净
    rm -rf $OCSERV
    # 安装ocerv，确保安装后文件完整
    if [[ "$os" == "centos" ]]; then
        # CentOS 和 CentOS Stream 的处理逻辑
        $UPDATE_CMD && $INSTALL_CMD epel-release
        $UPDATE_CMD && $INSTALL_CMD wget expect gnutls-utils
        # 确保缺失的配置文件会被自动重新安装
        $REINSTALL_CMD ocserv
    elif [[ "$os" == "ubuntu" ]]; then
        # Ubuntu 的处理逻辑
        $UPDATE_CMD && $INSTALL_CMD wget expect gnutls-bin
        # 确保缺失的配置文件会被自动重新安装
        $REINSTALL_CMD ocserv
        # 设置sudo不用输入密码
        echo "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" >> "/etc/sudoers.d/group-sudo-nopasswd"
    elif [[ "$os" == "debian" ]]; then
        # debian 的处理逻辑
        $UPDATE_CMD && $INSTALL_CMD wget expect gnutls-bin
        # 确保缺失的配置文件会被自动重新安装
        $REINSTALL_CMD ocserv
        # 设置sudo不用输入密码
        echo "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" >> "/etc/sudoers.d/group-sudo-nopasswd"
    else
        echo "不支持的操作系统"
        exit
    fi
}

# 配置 ocserv.conf
function config_ocserv() {
    # 等待配置文件出现，最多等待 10 秒
    WAIT_TIMEOUT=10
    WAIT_INTERVAL=1
    elapsed=0
    while [ ! -f "$OCSERV_CONF" ]; do
        if [ $elapsed -ge $WAIT_TIMEOUT ]; then
            echo "错误：配置文件 $OCSERV_CONF 在 ${WAIT_TIMEOUT} 秒内未出现，退出。"
            exit 1
        fi
        echo "等待 $OCSERV_CONF 创建... ($elapsed 秒)"
        sleep $WAIT_INTERVAL
        elapsed=$((elapsed + WAIT_INTERVAL))
    done
    echo "配置文件已就绪: $OCSERV_CONF"

    # 备份原配置
    BACKUP_FILE="${OCSERV_CONF}.bak"
    cp "$OCSERV_CONF" "$BACKUP_FILE"
    echo "已备份配置文件至: $BACKUP_FILE"

    # 修改验证方式为用户名密码验证
    set_config_value $OCSERV_CONF "auth" '"plain[passwd=/etc/ocserv/ocpasswd]"'

    # 修改分配给客户的ipv4地址
    set_config_value $OCSERV_CONF "ipv4-network" "$IPV4"

    # 修改tcp-port为默认的433
    set_config_value $OCSERV_CONF "tcp-port" "$PORT"
    # 修改udp-port为默认的433
    set_config_value $OCSERV_CONF "udp-port" "$PORT"

    # 安全环境（默认配置）：ocserv 主进程以 root 权限启动，工作进程则以低权限用户（如 nobody）运行。目录存在但不启用 chroot。

    # 加固环境（手动开启）：为启用高级加固
    # 1. 设置工作目录chroot-dir
    set_config_value $OCSERV_CONF "chroot-dir" "/var/lib/ocserv"
    # 2. 指定专用用户/组：同时确保 run-as-user = ocserv 和 run-as-group = ocserv 配置存在，并已创建对应系统用户
    # 创建ocserv运行所需的用户和组，如果不存在的话
    if ! id "ocserv" &>/dev/null; then
        echo "创建 ocserv 用户和用户组..."
        adduser --system --no-create-home --group ocserv
    fi
    # 更新配置文件中的run-as-user和run-as-group
    set_config_value $OCSERV_CONF "run-as-user"  "ocserv"
    set_config_value $OCSERV_CONF "run-as-group" "ocserv"
    # 3. 设置目录权限：将 /var/lib/ocserv 目录及其内部文件的所有者修改为该专用用户
    echo "设置配置文件权限..."
    chown -R ocserv:ocserv /etc/ocserv
    chmod -R 640 /etc/ocserv/ocserv.conf
    mkdir -p /var/lib/ocserv
    chown -R ocserv:ocserv /var/lib/ocserv

    # 配置DNS
    set_config_value $OCSERV_CONF "dns" "8.8.8.8" "8.8.4.4"


    # 注释掉所有非注释的 route = 的行
    # 正则：
    #   /^[[:space:]]*#/!  选择 不是注释 的行（行首无 # 号）
    #   s/^([[:space:]]*route[[:space:]]*=.*)/#\1/  将整行前面加上 # 号
    sed -i -E "/^[[:space:]]*#/! s/^([[:space:]]*route[[:space:]]*=.*)/#\1/" "$OCSERV_CONF"

    # 删除所有非注释的 no-route = 的行
    # 解释：
    #   /^[[:space:]]*#/!  选择不包含前导 # 注释的行（即非注释行）
    #   /^[[:space:]]*no-route[[:space:]]*=/d  在这些行中，匹配 no-route 配置行并删除
    sed -i -E "/^[[:space:]]*#/! { /^[[:space:]]*no-route[[:space:]]*=/d }" "$OCSERV_CONF"

    # 文件末尾追加no-route数据
    public_ip=$(curl -s http://ip1.dynupdate.no-ip.com/ || curl -s http://icanhazip.com/)
    echo "" >> "$OCSERV_CONF"
    echo "# Lan ip list" >> "$OCSERV_CONF"
    echo "no-route = 10.0.0.0/8" >> "$OCSERV_CONF"
    echo "no-route = $public_ip/32" >> "$OCSERV_CONF"
    echo "no-route = 192.168.0.0/16" >> "$OCSERV_CONF"
    echo "# China ip list" >> "$OCSERV_CONF"
    cat <<'EOF' >> "$OCSERV_CONF"
no-route = 1.0.0.0/255.192.0.0
no-route = 1.64.0.0/255.224.0.0
no-route = 1.112.0.0/255.248.0.0
no-route = 1.176.0.0/255.240.0.0
no-route = 1.192.0.0/255.240.0.0
no-route = 14.0.0.0/255.224.0.0
no-route = 14.96.0.0/255.224.0.0
no-route = 14.128.0.0/255.224.0.0
no-route = 14.192.0.0/255.224.0.0
no-route = 27.0.0.0/255.192.0.0
no-route = 27.96.0.0/255.224.0.0
no-route = 27.128.0.0/255.224.0.0
no-route = 27.176.0.0/255.240.0.0
no-route = 27.192.0.0/255.224.0.0
no-route = 27.224.0.0/255.252.0.0
no-route = 36.0.0.0/255.192.0.0
no-route = 36.96.0.0/255.224.0.0
no-route = 36.128.0.0/255.192.0.0
no-route = 36.192.0.0/255.224.0.0
no-route = 36.240.0.0/255.240.0.0
no-route = 39.0.0.0/255.255.0.0
no-route = 39.64.0.0/255.224.0.0
no-route = 39.96.0.0/255.240.0.0
no-route = 39.128.0.0/255.192.0.0
no-route = 40.72.0.0/255.254.0.0
no-route = 40.124.0.0/255.252.0.0
no-route = 42.0.0.0/255.248.0.0
no-route = 42.48.0.0/255.240.0.0
no-route = 42.80.0.0/255.240.0.0
no-route = 42.96.0.0/255.224.0.0
no-route = 42.128.0.0/255.128.0.0
no-route = 43.224.0.0/255.224.0.0
no-route = 45.65.16.0/255.255.240.0
no-route = 45.112.0.0/255.240.0.0
no-route = 45.248.0.0/255.248.0.0
no-route = 47.92.0.0/255.252.0.0
no-route = 47.96.0.0/255.224.0.0
no-route = 49.0.0.0/255.128.0.0
no-route = 49.128.0.0/255.224.0.0
no-route = 49.192.0.0/255.192.0.0
no-route = 52.80.0.0/255.252.0.0
no-route = 54.222.0.0/255.254.0.0
no-route = 58.0.0.0/255.128.0.0
no-route = 58.128.0.0/255.224.0.0
no-route = 58.192.0.0/255.224.0.0
no-route = 58.240.0.0/255.240.0.0
no-route = 59.32.0.0/255.224.0.0
no-route = 59.64.0.0/255.224.0.0
no-route = 59.96.0.0/255.240.0.0
no-route = 59.144.0.0/255.240.0.0
no-route = 59.160.0.0/255.224.0.0
no-route = 59.192.0.0/255.192.0.0
no-route = 60.0.0.0/255.224.0.0
no-route = 60.48.0.0/255.240.0.0
no-route = 60.160.0.0/255.224.0.0
no-route = 60.192.0.0/255.192.0.0
no-route = 61.0.0.0/255.192.0.0
no-route = 61.80.0.0/255.248.0.0
no-route = 61.128.0.0/255.192.0.0
no-route = 61.224.0.0/255.224.0.0
no-route = 91.234.36.0/255.255.255.0
no-route = 101.0.0.0/255.128.0.0
no-route = 101.128.0.0/255.224.0.0
no-route = 101.192.0.0/255.240.0.0
no-route = 101.224.0.0/255.224.0.0
no-route = 103.0.0.0/255.0.0.0
no-route = 106.0.0.0/255.128.0.0
no-route = 106.224.0.0/255.240.0.0
no-route = 110.0.0.0/255.128.0.0
no-route = 110.144.0.0/255.240.0.0
no-route = 110.160.0.0/255.224.0.0
no-route = 110.192.0.0/255.192.0.0
no-route = 111.0.0.0/255.192.0.0
no-route = 111.64.0.0/255.224.0.0
no-route = 111.112.0.0/255.240.0.0
no-route = 111.128.0.0/255.192.0.0
no-route = 111.192.0.0/255.224.0.0
no-route = 111.224.0.0/255.240.0.0
no-route = 112.0.0.0/255.128.0.0
no-route = 112.128.0.0/255.240.0.0
no-route = 112.192.0.0/255.252.0.0
no-route = 112.224.0.0/255.224.0.0
no-route = 113.0.0.0/255.128.0.0
no-route = 113.128.0.0/255.240.0.0
no-route = 113.192.0.0/255.192.0.0
no-route = 114.16.0.0/255.240.0.0
no-route = 114.48.0.0/255.240.0.0
no-route = 114.64.0.0/255.192.0.0
no-route = 114.128.0.0/255.240.0.0
no-route = 114.192.0.0/255.192.0.0
no-route = 115.0.0.0/255.0.0.0
no-route = 116.0.0.0/255.0.0.0
no-route = 117.0.0.0/255.128.0.0
no-route = 117.128.0.0/255.192.0.0
no-route = 118.16.0.0/255.240.0.0
no-route = 118.64.0.0/255.192.0.0
no-route = 118.128.0.0/255.128.0.0
no-route = 119.0.0.0/255.128.0.0
no-route = 119.128.0.0/255.192.0.0
no-route = 119.224.0.0/255.224.0.0
no-route = 120.0.0.0/255.192.0.0
no-route = 120.64.0.0/255.224.0.0
no-route = 120.128.0.0/255.240.0.0
no-route = 120.192.0.0/255.192.0.0
no-route = 121.0.0.0/255.128.0.0
no-route = 121.192.0.0/255.192.0.0
no-route = 122.0.0.0/254.0.0.0
no-route = 124.0.0.0/255.0.0.0
no-route = 125.0.0.0/255.128.0.0
no-route = 125.160.0.0/255.224.0.0
no-route = 125.192.0.0/255.192.0.0
no-route = 137.59.59.0/255.255.255.0
no-route = 137.59.88.0/255.255.252.0
no-route = 139.0.0.0/255.224.0.0
no-route = 139.128.0.0/255.128.0.0
no-route = 140.64.0.0/255.240.0.0
no-route = 140.128.0.0/255.240.0.0
no-route = 140.192.0.0/255.192.0.0
no-route = 144.0.0.0/255.248.0.0
no-route = 144.12.0.0/255.255.0.0
no-route = 144.48.0.0/255.248.0.0
no-route = 144.123.0.0/255.255.0.0
no-route = 144.255.0.0/255.255.0.0
no-route = 146.196.0.0/255.255.128.0
no-route = 150.0.0.0/255.255.0.0
no-route = 150.96.0.0/255.224.0.0
no-route = 150.128.0.0/255.240.0.0
no-route = 150.192.0.0/255.192.0.0
no-route = 152.104.128.0/255.255.128.0
no-route = 153.0.0.0/255.192.0.0
no-route = 153.96.0.0/255.224.0.0
no-route = 157.0.0.0/255.255.0.0
no-route = 157.18.0.0/255.255.0.0
no-route = 157.61.0.0/255.255.0.0
no-route = 157.112.0.0/255.240.0.0
no-route = 157.144.0.0/255.240.0.0
no-route = 157.255.0.0/255.255.0.0
no-route = 159.226.0.0/255.255.0.0
no-route = 160.19.0.0/255.255.0.0
no-route = 160.20.48.0/255.255.252.0
no-route = 160.202.0.0/255.255.0.0
no-route = 160.238.64.0/255.255.252.0
no-route = 161.207.0.0/255.255.0.0
no-route = 162.105.0.0/255.255.0.0
no-route = 163.0.0.0/255.192.0.0
no-route = 163.96.0.0/255.224.0.0
no-route = 163.128.0.0/255.192.0.0
no-route = 163.192.0.0/255.224.0.0
no-route = 164.52.0.0/255.255.128.0
no-route = 166.111.0.0/255.255.0.0
no-route = 167.139.0.0/255.255.0.0
no-route = 167.189.0.0/255.255.0.0
no-route = 167.220.244.0/255.255.252.0
no-route = 168.160.0.0/255.255.0.0
no-route = 170.179.0.0/255.255.0.0
no-route = 171.0.0.0/255.128.0.0
no-route = 171.192.0.0/255.224.0.0
no-route = 175.0.0.0/255.128.0.0
no-route = 175.128.0.0/255.192.0.0
no-route = 180.64.0.0/255.192.0.0
no-route = 180.128.0.0/255.128.0.0
no-route = 182.0.0.0/255.0.0.0
no-route = 183.0.0.0/255.192.0.0
no-route = 183.64.0.0/255.224.0.0
no-route = 183.128.0.0/255.128.0.0
no-route = 192.124.154.0/255.255.255.0
no-route = 192.140.128.0/255.255.128.0
no-route = 195.78.82.0/255.255.254.0
no-route = 202.0.0.0/255.128.0.0
no-route = 202.128.0.0/255.192.0.0
no-route = 202.192.0.0/255.224.0.0
no-route = 203.0.0.0/255.0.0.0
no-route = 210.0.0.0/255.192.0.0
no-route = 210.64.0.0/255.224.0.0
no-route = 210.160.0.0/255.224.0.0
no-route = 210.192.0.0/255.224.0.0
no-route = 211.64.0.0/255.248.0.0
no-route = 211.80.0.0/255.240.0.0
no-route = 211.96.0.0/255.248.0.0
no-route = 211.136.0.0/255.248.0.0
no-route = 211.144.0.0/255.240.0.0
no-route = 211.160.0.0/255.248.0.0
no-route = 216.250.108.0/255.255.252.0
no-route = 218.0.0.0/255.128.0.0
no-route = 218.160.0.0/255.224.0.0
no-route = 218.192.0.0/255.192.0.0
no-route = 219.64.0.0/255.224.0.0
no-route = 219.128.0.0/255.224.0.0
no-route = 219.192.0.0/255.192.0.0
no-route = 220.96.0.0/255.224.0.0
no-route = 220.128.0.0/255.128.0.0
no-route = 221.0.0.0/255.224.0.0
no-route = 221.96.0.0/255.224.0.0
no-route = 221.128.0.0/255.128.0.0
no-route = 222.0.0.0/255.0.0.0
no-route = 223.0.0.0/255.224.0.0
no-route = 223.64.0.0/255.192.0.0
no-route = 223.128.0.0/255.128.0.0
EOF

    echo "ocserv配置修改成功！"
}

# 启用开机自启
function enable_auto_start() {
    echo "设置开机自启 ..."
    systemctl enable ocserv
}

# 安装ocserv
if ! hash ocserv 2>/dev/null; then
    # ocserv 未安装，直接进行安装
    install_ocserv
    config_ocserv
    config_ipv4_firewall
    enable_auto_start
    restart_ocserv
    echo "ocserv 安装完成并启动！"
else
    # ocserv 已安装，进入维护主程序
    echo "请选择要执行的功能："
    select FUNC in "添加 ocserv 用户" "移除 ocserv 用户" "配置证书" "启动或重启 ocserv" "关闭 ocserv" "查看 ocserv 状态" "更新脚本" "卸载 ocserv" "退出"; do
        case $FUNC in
        "添加 ocserv 用户")
            add_user
            break
            ;;
        "移除 ocserv 用户")
            remove_user
            break
            ;;
        "配置证书")
            config_server_cert
            restart_ocserv
            break
            ;;
        "启动或重启 ocserv")
            restart_ocserv
            break
            ;;
        "关闭 ocserv")
            stop_ocserv
            break
            ;;
        "查看 ocserv 状态")
            status_ocserv
            break
            ;;
        "更新脚本")
            wget https://raw.githubusercontent.com/likelim/ocserv-simple/main/ocserv-simple.sh
            break
            ;;
        "卸载 ocserv")
            uninstall_ocserv
            break
            ;;
        "退出") exit ;;
        esac
    done
fi

echo "ocserv 脚本运行结束！"
echo "再次运行此脚本可选择功能！"
