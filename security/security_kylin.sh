#!/bin/bash
###############################################################################
# 全员人口信息系统 - Linux安全基线加固脚本
# 适配系统: Kylin Linux Advanced Server V10 (Halberd)
# 等保要求: GB/T 22239-2019 第三级
# 依据文档: 宁夏回族自治区卫生健康委员会全员人口信息系统网络安全等级保护差距分析小结报告
# 版本: 2.0
# 日期: 2026-04-16
###############################################################################

set -u
# 注意: 不使用 set -e / set -o pipefail
# 安全加固脚本中许多检测命令(grep/id/systemctl/tr|head等)
# 返回非零退出码是正常行为，set -e 和 pipefail 会导致脚本意外中断

# ========================= 全局变量 =========================
SCRIPT_VERSION="2.0"
BACKUP_DIR="/root/security_backup/$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/security_harden.log"

# 颜色定义
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Cyan="\033[36m"
Font="\033[0m"
Bold="\033[1m"

# 日志前缀
_INFO="[${Green}INFO${Font}]"
_ERROR="[${Red}ERROR${Font}]"
_WARN="[${Yellow}WARN${Font}]"
_OK="[${Green} OK ${Font}]"
_FAIL="[${Red}FAIL${Font}]"

# ========================= 基础函数 =========================
log_info()  { echo -e "${_INFO} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${_ERROR} $1" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${_WARN} $1" | tee -a "$LOG_FILE"; }
log_ok()    { echo -e "${_OK} $1" | tee -a "$LOG_FILE"; }
log_fail()  { echo -e "${_FAIL} $1" | tee -a "$LOG_FILE"; }

# 分隔线
separator() {
    echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${Font}"
}

# 小节标题
section() {
    echo ""
    separator
    echo -e "${Bold}${Cyan}  ▶ $1${Font}"
    separator
}

# root权限检查
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 身份运行！"
        exit 1
    fi
}

# 系统检查 - 确认是麒麟V10
check_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "${ID:-}" != "kylin" ]]; then
            log_warn "当前系统为 ${PRETTY_NAME:-未知}，非麒麟系统，部分配置可能不兼容"
            read -rp "是否继续? [y/N]: " ans
            [[ "${ans,,}" != "y" ]] && exit 0
        else
            log_info "检测到系统: ${PRETTY_NAME:-Kylin Linux}"
        fi
    else
        log_warn "无法读取 /etc/os-release，跳过系统检查"
    fi
}

# 备份文件（修改前必须调用）
# 保留完整目录结构以便 restore 时精确恢复
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a --parents "$file" "$BACKUP_DIR/"
        log_info "已备份: $file"
    fi
}

# 安全地设置配置项（key value 形式）
set_config() {
    local file="$1" key="$2" value="$3" delimiter="${4:- }"
    if grep -qE "^\s*${key}\s*${delimiter}" "$file" 2>/dev/null; then
        sed -i "s|^\s*${key}\s*${delimiter}.*|${key}${delimiter}${value}|" "$file"
    elif grep -qE "^\s*#\s*${key}\s*${delimiter}" "$file" 2>/dev/null; then
        sed -i "s|^\s*#\s*${key}\s*${delimiter}.*|${key}${delimiter}${value}|" "$file"
    else
        echo "${key}${delimiter}${value}" >> "$file"
    fi
}

# ========================= 1. 密码策略加固 =========================
# 对应报告: 身份鉴别a - PASS_MAX_DAYS/PASS_MIN_LEN/pam_pwquality
harden_password_policy() {
    section "1. 密码策略加固 (身份鉴别a)"

    local login_defs="/etc/login.defs"
    backup_file "$login_defs"

    # PASS_MAX_DAYS: 密码最大有效期90天
    set_config "$login_defs" "PASS_MAX_DAYS" "90" "	"
    log_info "PASS_MAX_DAYS = $(grep '^PASS_MAX_DAYS' $login_defs | awk '{print $2}')"

    # PASS_MIN_DAYS: 密码最小使用天数2天（防止频繁修改绕过历史检查）
    set_config "$login_defs" "PASS_MIN_DAYS" "2" "	"
    log_info "PASS_MIN_DAYS = $(grep '^PASS_MIN_DAYS' $login_defs | awk '{print $2}')"

    # PASS_MIN_LEN: 密码最小长度8位
    set_config "$login_defs" "PASS_MIN_LEN" "8" "	"
    log_info "PASS_MIN_LEN  = $(grep '^PASS_MIN_LEN' $login_defs | awk '{print $2}')"

    # PASS_WARN_AGE: 密码过期前7天警告
    set_config "$login_defs" "PASS_WARN_AGE" "7" "	"
    log_info "PASS_WARN_AGE = $(grep '^PASS_WARN_AGE' $login_defs | awk '{print $2}')"

    # pam_pwquality.so 密码复杂度
    local pam_sysauth="/etc/pam.d/system-auth"
    backup_file "$pam_sysauth"

    local pwquality_line="password    requisite     pam_pwquality.so retry=3 minlen=12 difok=3 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1"
    if grep -q 'pam_pwquality.so' "$pam_sysauth"; then
        sed -i "/pam_pwquality.so/c\\${pwquality_line}" "$pam_sysauth"
    else
        # 在password段首行前插入
        sed -i "/^password/i\\${pwquality_line}" "$pam_sysauth"
    fi
    log_ok "密码复杂度策略已配置: minlen=12 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1"

    # pwquality.conf 同步配置
    local pwquality_conf="/etc/security/pwquality.conf"
    if [[ -f "$pwquality_conf" ]]; then
        backup_file "$pwquality_conf"
        set_config "$pwquality_conf" "minlen" "12" " = "
        set_config "$pwquality_conf" "dcredit" "-1" " = "
        set_config "$pwquality_conf" "ucredit" "-1" " = "
        set_config "$pwquality_conf" "lcredit" "-1" " = "
        set_config "$pwquality_conf" "ocredit" "-1" " = "
        set_config "$pwquality_conf" "difok" "3" " = "
        set_config "$pwquality_conf" "retry" "3" " = "
        log_ok "pwquality.conf 已同步配置"
    fi

    # 密码历史记录（防止重复使用最近5个密码）
    if ! grep -q 'pam_pwhistory.so' "$pam_sysauth"; then
        sed -i "/pam_pwquality.so/a\\password    required      pam_pwhistory.so remember=5 use_authtok" "$pam_sysauth"
        log_ok "密码历史记录策略已配置: remember=5"
    else
        log_info "pam_pwhistory.so 已存在"
    fi
}

# ========================= 2. 登录失败处理 + 会话超时 =========================
# 对应报告: 身份鉴别b - 登录失败锁定 + TMOUT
harden_login_policy() {
    section "2. 登录失败处理与会话超时 (身份鉴别b)"

    # ---- 登录失败锁定 ----
    # 麒麟V10使用 pam_faillock（pam_tally2 已废弃）
    local pam_sysauth="/etc/pam.d/system-auth"
    local pam_password_auth="/etc/pam.d/password-auth"
    backup_file "$pam_sysauth"
    [[ -f "$pam_password_auth" ]] && backup_file "$pam_password_auth"

    # 检查系统是否有 pam_faillock.so
    if [[ -f /usr/lib64/security/pam_faillock.so ]] || [[ -f /lib64/security/pam_faillock.so ]]; then
        local faillock_module="pam_faillock.so"
        log_info "使用 pam_faillock.so 配置登录失败锁定"

        for pam_file in "$pam_sysauth" "$pam_password_auth"; do
            [[ ! -f "$pam_file" ]] && continue

            # 移除旧的 pam_tally2 配置
            sed -i '/pam_tally2\.so/d' "$pam_file"

            # 添加 pam_faillock 配置（如果不存在）
            if ! grep -q 'pam_faillock.so' "$pam_file"; then
                # auth 段：preauth + authfail
                sed -i '/^auth\s\+required\s\+pam_env\.so/a\auth        required      pam_faillock.so preauth silent audit deny=5 unlock_time=600 even_deny_root root_unlock_time=600\nauth        [default=die]  pam_faillock.so authfail audit deny=5 unlock_time=600 even_deny_root root_unlock_time=600' "$pam_file"
                # account 段
                if ! grep 'pam_faillock.so' "$pam_file" | grep -q 'account'; then
                    sed -i '/^account\s\+required\s\+pam_unix\.so/i\account     required      pam_faillock.so' "$pam_file"
                fi
                log_ok "pam_faillock 已配置于 $pam_file (deny=5 unlock_time=600)"
            else
                log_info "pam_faillock.so 已存在于 $pam_file"
            fi
        done

        # 配置 faillock.conf（麒麟V10推荐方式）
        local faillock_conf="/etc/security/faillock.conf"
        if [[ -f "$faillock_conf" ]]; then
            backup_file "$faillock_conf"
            set_config "$faillock_conf" "deny" "5" " = "
            set_config "$faillock_conf" "unlock_time" "600" " = "
            set_config "$faillock_conf" "even_deny_root" "" ""
            set_config "$faillock_conf" "root_unlock_time" "600" " = "
            set_config "$faillock_conf" "audit" "" ""
            log_ok "faillock.conf 已配置"
        fi
    else
        # 降级使用 pam_tally2（极少数情况）
        log_warn "pam_faillock.so 不存在，尝试使用 pam_tally2.so"
        local pam_login="/etc/pam.d/login"
        backup_file "$pam_login"
        if ! grep -q 'pam_tally2.so' "$pam_login"; then
            sed -i '/^#%PAM-1.0/a\auth required pam_tally2.so deny=5 unlock_time=600 even_deny_root root_unlock_time=600' "$pam_login"
            log_ok "pam_tally2 已配置于 $pam_login"
        fi
    fi

    # ---- 登录连接超时 TMOUT ----
    local profile="/etc/profile"
    backup_file "$profile"
    if grep -qE '^\s*TMOUT=' "$profile"; then
        sed -i 's/^\s*TMOUT=.*/TMOUT=300/' "$profile"
    else
        cat >> "$profile" << 'EOF'

# 安全基线: 登录连接超时自动退出 (300秒=5分钟)
TMOUT=300
export TMOUT
readonly TMOUT
EOF
    fi
    log_ok "TMOUT=300 已配置 (readonly，防止用户修改)"

    # ---- SSH 登录超时 ----
    local sshd_config="/etc/ssh/sshd_config"
    if [[ -f "$sshd_config" ]]; then
        backup_file "$sshd_config"
        set_config "$sshd_config" "ClientAliveInterval" "300"
        set_config "$sshd_config" "ClientAliveCountMax" "0"
        log_ok "SSH超时已配置: ClientAliveInterval=300 ClientAliveCountMax=0"
    fi
}

# ========================= 3. SSH安全加固 =========================
# 对应报告: 远程管理安全 + 身份鉴别
harden_ssh() {
    section "3. SSH安全加固 (远程管理安全)"

    local sshd_config="/etc/ssh/sshd_config"
    [[ ! -f "$sshd_config" ]] && { log_error "sshd_config 不存在"; return; }
    backup_file "$sshd_config"

    # 禁用SSH协议v1（仅使用v2）
    set_config "$sshd_config" "Protocol" "2"

    # 禁止root直接SSH登录（三权分立要求，管理员通过普通用户登录后su/sudo）
    set_config "$sshd_config" "PermitRootLogin" "no"

    # 禁止空密码登录
    set_config "$sshd_config" "PermitEmptyPasswords" "no"

    # 最大认证尝试次数
    set_config "$sshd_config" "MaxAuthTries" "5"

    # 登录宽限时间
    set_config "$sshd_config" "LoginGraceTime" "60"

    # 禁用不安全的认证方式
    set_config "$sshd_config" "HostbasedAuthentication" "no"
    set_config "$sshd_config" "IgnoreRhosts" "yes"

    # 启用严格模式
    set_config "$sshd_config" "StrictModes" "yes"

    # 显示上次登录信息
    set_config "$sshd_config" "PrintLastLog" "yes"

    # SSH Banner 警告
    if [[ ! -f /etc/ssh/banner ]]; then
        cat > /etc/ssh/banner << 'BANNER'
*********************************************************************
*                         WARNING                                    *
*  This system is for authorized users only.                        *
*  All activities on this system are monitored and recorded.        *
*  Unauthorized access will be prosecuted to the full extent of law.*
*  本系统仅供授权用户使用，所有操作均被审计记录。                     *
*********************************************************************
BANNER
    fi
    set_config "$sshd_config" "Banner" "/etc/ssh/banner"

    # 禁用X11转发
    set_config "$sshd_config" "X11Forwarding" "no"

    # 禁用Telnet服务（与SSH加固归为同一类高危操作）
    _disable_telnet

    # 禁用telnet.socket（systemd管理的）
    if systemctl is-enabled --quiet telnet.socket 2>/dev/null; then
        systemctl stop telnet.socket 2>/dev/null
        systemctl disable telnet.socket 2>/dev/null
        log_ok "已停止并禁用: telnet.socket"
    fi

    # 重启SSH服务
    if systemctl is-active --quiet sshd; then
        systemctl restart sshd
        log_ok "SSH服务已重启，配置生效"
    fi

    log_ok "SSH安全加固完成"
}

# 禁用Telnet（内部辅助函数）
_disable_telnet() {
    local telnet_config="/etc/xinetd.d/telnet"
    if [[ -f "$telnet_config" ]]; then
        backup_file "$telnet_config"
        sed -i 's/^\(\s*disable\s*=\s*\).*/\1yes/' "$telnet_config"
        systemctl restart xinetd 2>/dev/null || true
        log_ok "Telnet服务已禁用"
    else
        log_info "Telnet未安装，无需处理"
    fi

    # 确保telnet客户端也被移除
    if rpm -q telnet &>/dev/null; then
        log_warn "检测到telnet客户端已安装，建议移除: yum remove telnet"
    fi
}

# ========================= 4. 访问控制 - hosts.allow/deny =========================
# 对应报告: 安全计算环境c - 限制管理终端网络地址范围
harden_hosts_access() {
    section "4. 网络访问控制 (管理终端限制)"

    local hosts_allow="/etc/hosts.allow"
    local hosts_deny="/etc/hosts.deny"

    backup_file "$hosts_allow"
    backup_file "$hosts_deny"

    log_warn "请根据实际网络环境配置允许访问的IP地址段"
    log_info "当前 hosts.allow 内容:"
    cat "$hosts_allow" 2>/dev/null || echo "(空)"
    echo ""

    # 交互式配置
    read -rp "是否配置SSH访问控制白名单? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
        read -rp "请输入允许SSH访问的IP/网段 (多个用逗号分隔, 如 10.50.0.0/16,10.60.0.0/16): " allowed_ips
        if [[ -n "$allowed_ips" ]]; then
            # 备份后写入
            if ! grep -q "sshd:" "$hosts_allow" 2>/dev/null; then
                echo "sshd: $allowed_ips" >> "$hosts_allow"
            else
                sed -i "s|^sshd:.*|sshd: $allowed_ips|" "$hosts_allow"
            fi
            log_ok "hosts.allow 已配置: sshd: $allowed_ips"

            # hosts.deny 拒绝所有其他
            if ! grep -q "sshd:ALL" "$hosts_deny" 2>/dev/null; then
                echo "sshd:ALL" >> "$hosts_deny"
            fi
            log_ok "hosts.deny 已配置: sshd:ALL"
        fi
    else
        log_warn "跳过hosts访问控制配置（差距报告要求配置，请后续手动完成）"
    fi
}

# ========================= 5. 三权分立用户配置 =========================
# 对应报告: 访问控制d - 管理用户权限分离
harden_separation_of_duties() {
    section "5. 三权分立用户配置 (访问控制d)"

    # 用户定义（不再硬编码密码，改为随机生成）
    local ADMIN_USER="sysadmin"        # 系统管理员
    local AUDITOR_USER="shenjiadmin"   # 审计管理员
    local SECURITY_USER="anquanadmin"  # 安全管理员

    _create_role_user "$ADMIN_USER" "系统管理员" "admin"
    _create_role_user "$AUDITOR_USER" "审计管理员" "auditor"
    _create_role_user "$SECURITY_USER" "安全管理员" "security"

    log_ok "三权分立用户配置完成"
    log_warn "请妥善保存上述密码信息，并在首次登录后立即修改密码"
}

# 创建角色用户（内部辅助函数）
_create_role_user() {
    local username="$1" role_name="$2" role_type="$3"
    local password_file="$BACKUP_DIR/passwords.txt"
    mkdir -p "$BACKUP_DIR"

    if id "$username" &>/dev/null; then
        log_info "${role_name} ($username) 已存在，跳过创建"
        return
    fi

    # 生成随机密码（16位，含大小写字母、数字、特殊字符）
    local password
    password=$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*()' | head -c 16 || true)

    useradd -m "$username"
    echo "$username:$password" | chpasswd
    # 强制首次登录修改密码
    chage -d 0 "$username"

    case "$role_type" in
        admin)
            # 系统管理员：sudoers
            if ! grep -q "^${username}" /etc/sudoers 2>/dev/null; then
                echo "${username} ALL=(ALL:ALL) ALL" >> /etc/sudoers
            fi
            log_ok "创建${role_name}: $username (sudo权限)"
            ;;
        auditor)
            # 审计管理员：审计日志只读权限
            setfacl -R -m u:"$username":rx /var/log/audit/ 2>/dev/null || true
            setfacl -R -m u:"$username":r /var/log/messages 2>/dev/null || true
            setfacl -R -m u:"$username":r /var/log/secure 2>/dev/null || true
            log_ok "创建${role_name}: $username (审计日志只读权限)"
            ;;
        security)
            # 安全管理员：安全配置管理权限
            log_ok "创建${role_name}: $username (安全配置权限)"
            ;;
    esac

    # 密码保存到安全文件
    echo "${role_name} - 用户名: $username  密码: $password" >> "$password_file"
    chmod 600 "$password_file"
}

# ========================= 6. umask 加固 =========================
# 对应报告: 访问控制a - umask值设置为0027或0077
harden_umask() {
    section "6. umask 权限掩码加固 (访问控制a)"

    local target_umask="0027"

    # /etc/profile
    local profile="/etc/profile"
    backup_file "$profile"
    if grep -qE '^\s*umask\s+' "$profile"; then
        sed -i "s/^\s*umask\s\+.*/umask $target_umask/" "$profile"
    else
        echo "umask $target_umask" >> "$profile"
    fi
    log_ok "/etc/profile umask = $target_umask"

    # /etc/bashrc
    local bashrc="/etc/bashrc"
    if [[ -f "$bashrc" ]]; then
        backup_file "$bashrc"
        if grep -qE '^\s*umask\s+' "$bashrc"; then
            sed -i "s/^\s*umask\s\+.*/umask $target_umask/" "$bashrc"
        fi
        log_ok "/etc/bashrc umask = $target_umask"
    fi

    # login.defs
    local login_defs="/etc/login.defs"
    set_config "$login_defs" "UMASK" "$target_umask" "		"
    log_ok "/etc/login.defs UMASK = $target_umask"
}

# ========================= 7. 审计服务加固 =========================
# 对应报告: 安全审计 + 审计记录保护
harden_audit() {
    section "7. 安全审计加固 (安全审计a/c)"

    # 启动auditd
    _ensure_service_running "auditd"
    # 启动rsyslog
    _ensure_service_running "rsyslog"

    # ---- 审计规则配置 ----
    local audit_rules="/etc/audit/rules.d/security_harden.rules"
    backup_file "$audit_rules" 2>/dev/null || true

    cat > "$audit_rules" << 'EOF'
# 全员人口信息系统安全审计规则
# 等保三级要求：审计覆盖每个用户，对重要用户行为和安全事件进行审计

# 监控用户认证相关文件
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/sudoers.d/ -p wa -k identity

# 监控登录相关配置
-w /etc/login.defs -p wa -k login_config
-w /etc/pam.d/ -p wa -k pam_config
-w /etc/ssh/sshd_config -p wa -k sshd_config

# 监控系统启动和关机
-w /sbin/shutdown -p x -k power
-w /sbin/reboot -p x -k power
-w /sbin/halt -p x -k power

# 监控cron任务
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /var/spool/cron/ -p wa -k cron

# 监控网络配置变更
-w /etc/hosts -p wa -k network
-w /etc/sysconfig/network -p wa -k network
-w /etc/sysconfig/network-scripts/ -p wa -k network

# 监控时间变更
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time_change
-a always,exit -F arch=b64 -S clock_settime -k time_change

# 监控用户/组修改命令
-w /usr/sbin/useradd -p x -k user_mgmt
-w /usr/sbin/userdel -p x -k user_mgmt
-w /usr/sbin/usermod -p x -k user_mgmt
-w /usr/sbin/groupadd -p x -k user_mgmt
-w /usr/sbin/groupdel -p x -k user_mgmt
-w /usr/sbin/groupmod -p x -k user_mgmt

# 监控 su/sudo 使用
-w /bin/su -p x -k su_usage
-w /usr/bin/sudo -p x -k sudo_usage

# 监控内核模块加载
-w /sbin/insmod -p x -k kernel_modules
-w /sbin/rmmod -p x -k kernel_modules
-w /sbin/modprobe -p x -k kernel_modules

# 审计日志不可变（放在最后）
# -e 2
EOF

    # 重新加载审计规则
    augenrules --load 2>/dev/null || auditctl -R "$audit_rules" 2>/dev/null || true
    log_ok "审计规则已配置并加载"

    # ---- 审计日志轮转与保护 ----
    local auditd_conf="/etc/audit/auditd.conf"
    if [[ -f "$auditd_conf" ]]; then
        backup_file "$auditd_conf"
        # 日志文件大小上限 (MB)
        set_config "$auditd_conf" "max_log_file" "50" " = "
        # 达到上限时的动作：轮转
        set_config "$auditd_conf" "max_log_file_action" "ROTATE" " = "
        # 保留日志文件数量
        set_config "$auditd_conf" "num_logs" "10" " = "
        # 空间不足时的动作
        set_config "$auditd_conf" "space_left_action" "SYSLOG" " = "
        set_config "$auditd_conf" "admin_space_left_action" "SINGLE" " = "
        log_ok "审计日志轮转策略已配置: 50MB x 10份"
    fi

    # ---- 日志保留策略 (rsyslog) ----
    local logrotate_syslog="/etc/logrotate.d/syslog"
    if [[ -f "$logrotate_syslog" ]]; then
        backup_file "$logrotate_syslog"
        # 确保至少保留180天(约26周)的日志
        sed -i 's/^\s*rotate\s\+.*/    rotate 26/' "$logrotate_syslog"
        log_ok "系统日志轮转策略: 保留26周(约180天)"
    fi

    # 保护审计日志权限
    chmod 600 /var/log/audit/audit.log 2>/dev/null || true
    chmod 700 /var/log/audit/ 2>/dev/null || true
    log_ok "审计日志文件权限已加固"
}

# 确保服务运行且开机启动
_ensure_service_running() {
    local svc="$1"
    if systemctl is-active --quiet "$svc"; then
        log_info "服务 $svc 正在运行"
    else
        systemctl start "$svc" 2>/dev/null && log_ok "服务 $svc 已启动" || log_error "启动 $svc 失败"
    fi
    systemctl enable "$svc" 2>/dev/null && log_info "服务 $svc 已设置开机自启" || true
}

# ========================= 8. 历史命令限制 =========================
# 对应报告: 剩余信息保护b - HISTSIZE=0
harden_histsize() {
    section "8. 历史命令清除 (剩余信息保护)"

    local profile="/etc/profile"
    backup_file "$profile"

    # 设置 HISTSIZE=0
    if grep -qE '^\s*HISTSIZE=' "$profile"; then
        sed -i 's/^\s*HISTSIZE=.*/HISTSIZE=0/' "$profile"
    else
        echo "HISTSIZE=0" >> "$profile"
    fi

    # 设置 HISTFILESIZE=0
    if grep -qE '^\s*HISTFILESIZE=' "$profile"; then
        sed -i 's/^\s*HISTFILESIZE=.*/HISTFILESIZE=0/' "$profile"
    else
        echo "HISTFILESIZE=0" >> "$profile"
    fi

    # 防止用户修改
    if ! grep -q 'export HISTSIZE' "$profile"; then
        cat >> "$profile" << 'EOF'
export HISTSIZE
export HISTFILESIZE
readonly HISTSIZE
readonly HISTFILESIZE
EOF
    fi

    log_ok "HISTSIZE=0 HISTFILESIZE=0 已配置 (readonly)"
}

# ========================= 9. 关键文件权限加固 =========================
# 对应报告: 访问控制 - 关键文件权限
harden_file_permissions() {
    section "9. 关键文件权限加固 (访问控制)"

    # passwd / shadow / group / gshadow
    chmod 644 /etc/passwd   && log_ok "/etc/passwd  -> 644"
    chmod 000 /etc/shadow   && log_ok "/etc/shadow  -> 000"
    chmod 644 /etc/group    && log_ok "/etc/group   -> 644"
    chmod 000 /etc/gshadow  && log_ok "/etc/gshadow -> 000"

    # SSH相关
    chmod 600 /etc/ssh/sshd_config 2>/dev/null && log_ok "/etc/ssh/sshd_config -> 600"
    chmod 700 /root/.ssh 2>/dev/null || true
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

    # crontab
    chmod 600 /etc/crontab 2>/dev/null && log_ok "/etc/crontab -> 600"

    # grub 引导配置
    if [[ -f /boot/grub2/grub.cfg ]]; then
        chmod 600 /boot/grub2/grub.cfg && log_ok "/boot/grub2/grub.cfg -> 600"
    fi
    if [[ -f /boot/efi/EFI/kylin/grub.cfg ]]; then
        chmod 600 /boot/efi/EFI/kylin/grub.cfg && log_ok "EFI grub.cfg -> 600"
    fi
}

# ========================= 10. 内核安全参数加固 =========================
# 对应报告: 入侵防范 + 网络安全
harden_kernel_params() {
    section "10. 内核安全参数加固 (入侵防范)"

    local sysctl_file="/etc/sysctl.d/99-security-harden.conf"

    cat > "$sysctl_file" << 'EOF'
# 全员人口信息系统 - 内核安全参数加固
# 等保三级要求

# 禁止IP转发（非路由器设备）
net.ipv4.ip_forward = 0

# 禁止ICMP重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 防止SYN Flood攻击
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# 禁止源路由
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# 启用反向路径过滤（防IP欺骗）
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# 忽略ICMP广播请求（防Smurf攻击）
net.ipv4.icmp_echo_ignore_broadcasts = 1

# 忽略伪造的ICMP错误
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 记录可疑数据包
net.ipv4.conf.all.log_martians = 1

# 禁止core dump（防止敏感信息泄露）
fs.suid_dumpable = 0

# 地址空间布局随机化 (ASLR)
kernel.randomize_va_space = 2

# 限制dmesg访问
kernel.dmesg_restrict = 1

# 限制内核指针泄露
kernel.kptr_restrict = 2
EOF

    sysctl -p "$sysctl_file" 2>/dev/null && log_ok "内核安全参数已加载" || log_warn "部分参数可能不支持"

    # 禁用core dump (limits.conf)
    local limits_conf="/etc/security/limits.conf"
    backup_file "$limits_conf"
    if ! grep -q 'hard.*core.*0' "$limits_conf"; then
        echo "* hard core 0" >> "$limits_conf"
        log_ok "core dump 已禁用 (limits.conf)"
    fi
}

# ========================= 11. 不安全服务检查 =========================
# 对应报告: 入侵防范 + 安全通信
harden_disable_services() {
    section "11. 不安全服务检查与关闭"

    # 注意: telnet 相关(telnet.socket/xinetd)归入 SSH加固(第3项)，
    #       all 一键执行时不会触及，防止远程断连
    local unsafe_services=("rsh.socket" "rlogin.socket" "rexec.socket"
                           "tftp.socket" "vsftpd" "avahi-daemon"
                           "cups" "nfs" "rpcbind")

    for svc in "${unsafe_services[@]}"; do
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            log_ok "已停止并禁用: $svc"
        elif systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
            log_info "$svc 已禁用"
        fi
    done

    # 检查监听端口中的不安全服务
    log_info "当前监听端口:"
    ss -tlnp 2>/dev/null | tee -a "$LOG_FILE"
}

# ========================= 12. 完整性校验工具 (AIDE) =========================
# 对应报告: 数据完整性b - 校验技术保证数据完整性
# 只监控关键系统文件，不全盘扫描，初始化通常 < 30秒
harden_integrity_check() {
    section "12. 完整性校验工具 (数据完整性)"

    if ! command -v aide &>/dev/null; then
        log_warn "AIDE 未安装，正在安装..."
        yum install -y aide 2>/dev/null || dnf install -y aide 2>/dev/null || {
            log_error "AIDE 安装失败，请手动安装: yum install aide"
            return
        }
    fi

    # ---- 自定义精简配置 ----
    local aide_conf="/etc/aide.conf"
    backup_file "$aide_conf"

    # 先写固定头部（兼容麒麟V10 AIDE，不使用 file: 前缀）
    cat > "$aide_conf" << 'AIDEEOF'
# 全员人口信息系统 - AIDE 精简配置
# 仅监控关键系统文件，初始化/检查速度快（通常 < 30秒）
# 如需增加监控目录，在末尾 "自定义监控" 区域添加即可

# 数据库位置
@@define DBDIR /var/lib/aide
database=@@{DBDIR}/aide.db.gz
database_out=@@{DBDIR}/aide.db.new.gz

# 日志
report_url=stdout

# 检查规则定义
NORMAL = p+i+n+u+g+s+m+c+sha256
PERMS  = p+i+u+g

# ============ 全局排除（不监控，放在监控规则之前） ============
!/etc/mtab
!/etc/resolv.conf
!/etc/adjtime
!/var
!/tmp
!/run
!/proc
!/sys
!/dev
!/home
!/opt
!/usr/share
!/usr/lib
!/usr/lib64

# ============ 监控关键系统文件 ============
AIDEEOF

    # 动态写入：只添加实际存在的文件/目录，避免 AIDE 报错
    local monitor_normal=(
        /etc/passwd /etc/shadow /etc/group /etc/gshadow
        /etc/sudoers /etc/sudoers.d /etc/login.defs
        /etc/pam.d /etc/security
        /etc/ssh/sshd_config /etc/ssh/ssh_config
        /etc/hosts.allow /etc/hosts.deny /etc/hosts
        /etc/profile /etc/bashrc /etc/environment
        /etc/crontab /etc/cron.d /etc/systemd/system
        /etc/sysctl.conf /etc/sysctl.d
        /boot/grub2/grub.cfg
        /usr/bin/su /usr/bin/sudo /usr/bin/passwd
        /usr/sbin/useradd /usr/sbin/userdel /usr/sbin/usermod
        /usr/sbin/groupadd /usr/sbin/sshd
        /etc/audit /etc/rsyslog.conf
    )
    local monitor_perms=(
        /var/log/audit /var/log/secure /var/log/messages
    )

    local added=0
    for f in "${monitor_normal[@]}"; do
        if [[ -e "$f" ]]; then
            echo "$f NORMAL" >> "$aide_conf"
            added=$((added + 1))
        else
            echo "# 跳过(不存在): $f" >> "$aide_conf"
        fi
    done
    for f in "${monitor_perms[@]}"; do
        if [[ -e "$f" ]]; then
            echo "$f PERMS" >> "$aide_conf"
            added=$((added + 1))
        else
            echo "# 跳过(不存在): $f" >> "$aide_conf"
        fi
    done

    # 追加自定义区域
    cat >> "$aide_conf" << 'AIDEEOF'

# ============ 自定义监控 ============
# 如需增加监控文件或目录，在此处添加，格式:
#   /path/to/file   NORMAL    # 完整校验（权限+哈希）
#   /path/to/dir    PERMS     # 仅监控权限变化
AIDEEOF

    log_ok "AIDE 精简配置已写入 (监控 ${added} 个文件/目录)"

    # ---- 清理旧的不完整数据库 ----
    rm -f /var/lib/aide/aide.db.new.gz 2>/dev/null || true

    # ---- 初始化 AIDE 数据库 ----
    if [[ ! -f /var/lib/aide/aide.db.gz ]]; then
        log_info "正在初始化 AIDE 数据库（精简模式，约 10-30 秒）..."
        mkdir -p /var/log/aide
        if aide --init 2>/dev/null; then
            if [[ -f /var/lib/aide/aide.db.new.gz ]]; then
                mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
                log_ok "AIDE 数据库已初始化"
            fi
        else
            log_warn "AIDE 初始化返回警告（可能部分文件不存在），检查数据库..."
            if [[ -f /var/lib/aide/aide.db.new.gz ]]; then
                mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
                log_ok "AIDE 数据库已生成（部分文件跳过）"
            else
                log_error "AIDE 数据库生成失败"
            fi
        fi
    else
        log_info "AIDE 数据库已存在"
        log_info "如需重建: aide --init && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz"
    fi

    # ---- 配置定期检查 (每天凌晨3点) ----
    local aide_cron="/etc/cron.d/aide_check"
    cat > "$aide_cron" << 'EOF'
# AIDE 完整性检查 - 每天凌晨3点
0 3 * * * root /usr/sbin/aide --check >> /var/log/aide/aide_check.log 2>&1
# AIDE 数据库更新 - 每周日凌晨4点（如有合法变更后需更新基线）
# 0 4 * * 0 root /usr/sbin/aide --update && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
EOF
    mkdir -p /var/log/aide
    chmod 600 "$aide_cron"
    log_ok "AIDE 定期检查已配置: 每天凌晨3点"
    log_info "数据库大小: $(ls -lh /var/lib/aide/aide.db.gz 2>/dev/null | awk '{print $5}' || echo 'N/A')"
}

# ========================= 13. 多余/过期账户清理 =========================
# 对应报告: 访问控制c - 删除或停用多余过期账户
harden_cleanup_accounts() {
    section "13. 多余/过期账户清理 (访问控制c)"

    # 检查可登录的系统用户
    log_info "可登录的用户列表:"
    awk -F: '($7 !~ /nologin|false|sync|shutdown|halt/) && ($3 >= 1000 || $3 == 0) {print $1, $3, $7}' /etc/passwd | tee -a "$LOG_FILE"
    echo ""

    # 检查空密码用户
    local empty_pw_users
    empty_pw_users=$(awk -F: '($2 == "" || $2 == "!!" || $2 == "!") {print $1}' /etc/shadow 2>/dev/null)
    if [[ -n "$empty_pw_users" ]]; then
        log_warn "以下用户密码为空或未设置:"
        echo "$empty_pw_users" | tee -a "$LOG_FILE"
        # 锁定空密码用户（不含root）
        while IFS= read -r user; do
            if [[ "$user" != "root" ]]; then
                passwd -l "$user" 2>/dev/null
                log_ok "已锁定空密码用户: $user"
            fi
        done <<< "$empty_pw_users"
    else
        log_ok "未发现空密码用户"
    fi

    # 检查UID=0的用户（除root外不应有）
    local uid0_users
    uid0_users=$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd)
    if [[ -n "$uid0_users" ]]; then
        log_warn "发现非root的UID=0用户（高危）: $uid0_users"
    else
        log_ok "未发现非root的UID=0用户"
    fi

    # 锁定不需要的系统默认账户
    local lock_users=("adm" "lp" "sync" "shutdown" "halt" "news" "uucp" "operator" "games" "gopher" "ftp")
    for user in "${lock_users[@]}"; do
        if id "$user" &>/dev/null; then
            usermod -s /sbin/nologin "$user" 2>/dev/null
            passwd -l "$user" 2>/dev/null
        fi
    done
    log_ok "已锁定不必要的系统默认账户"
}

# ========================= 14. 配置数据备份 =========================
# 对应报告: 数据备份恢复a - 重要配置数据备份
harden_config_backup() {
    section "14. 重要配置数据备份 (数据备份恢复)"

    local backup_script="/usr/local/bin/security_config_backup.sh"

    cat > "$backup_script" << 'SCRIPT'
#!/bin/bash
# 重要配置文件自动备份脚本
BACKUP_BASE="/opt/config_backup"
BACKUP_DATE=$(date +%Y%m%d)
BACKUP_PATH="${BACKUP_BASE}/${BACKUP_DATE}"
mkdir -p "$BACKUP_PATH"

# 备份关键配置文件
FILES=(
    "/etc/passwd" "/etc/shadow" "/etc/group" "/etc/gshadow"
    "/etc/login.defs" "/etc/profile" "/etc/bashrc"
    "/etc/ssh/sshd_config"
    "/etc/pam.d/system-auth" "/etc/pam.d/password-auth" "/etc/pam.d/login"
    "/etc/security/pwquality.conf" "/etc/security/limits.conf"
    "/etc/audit/auditd.conf" "/etc/audit/rules.d/"
    "/etc/rsyslog.conf"
    "/etc/hosts.allow" "/etc/hosts.deny"
    "/etc/sysctl.conf" "/etc/sysctl.d/"
    "/etc/fstab" "/etc/crontab"
    "/etc/sudoers"
)

for f in "${FILES[@]}"; do
    if [[ -e "$f" ]]; then
        cp -a --parents "$f" "$BACKUP_PATH/" 2>/dev/null
    fi
done

# 备份网络配置
cp -a --parents /etc/sysconfig/network-scripts/ "$BACKUP_PATH/" 2>/dev/null
# 备份防火墙规则
iptables-save > "$BACKUP_PATH/iptables.rules" 2>/dev/null
firewall-cmd --list-all > "$BACKUP_PATH/firewalld.txt" 2>/dev/null

# 记录系统信息
uname -a > "$BACKUP_PATH/system_info.txt"
cat /etc/os-release >> "$BACKUP_PATH/system_info.txt"
rpm -qa > "$BACKUP_PATH/installed_packages.txt"
ss -tlnp > "$BACKUP_PATH/listening_ports.txt"

# 打包压缩
cd "$BACKUP_BASE"
tar czf "${BACKUP_DATE}.tar.gz" "$BACKUP_DATE/" && rm -rf "$BACKUP_DATE/"

# 保留最近30天的备份
find "$BACKUP_BASE" -name "*.tar.gz" -mtime +30 -delete

echo "[$(date)] 配置备份完成: ${BACKUP_BASE}/${BACKUP_DATE}.tar.gz"
SCRIPT

    chmod 700 "$backup_script"
    log_ok "备份脚本已创建: $backup_script"

    # 配置每周自动备份
    local backup_cron="/etc/cron.d/config_backup"
    echo "0 2 * * 0 root $backup_script >> /var/log/config_backup.log 2>&1" > "$backup_cron"
    chmod 600 "$backup_cron"
    log_ok "自动备份已配置: 每周日凌晨2点"

    # 立即执行一次备份
    bash "$backup_script"
    log_ok "首次备份已完成"
}

# ========================= 15. 安全检查报告 =========================
# 支持输出格式: txt(默认) / md / docx / all
# 用法: bash security_kylin.sh report [txt|md|docx|all]
security_check_report() {
    section "15. 安全状态检查报告"

    local format="${1:-all}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local report_dir="/root/security_reports"
    mkdir -p "$report_dir"

    # ---- 采集数据 ----
    local sys_name
    sys_name=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    local host_name
    host_name=$(hostname)
    local report_date
    report_date=$(date '+%Y-%m-%d %H:%M:%S')

    # [1] 密码策略
    local pw_max pw_min pw_len pw_warn pw_quality
    pw_max=$(grep '^PASS_MAX_DAYS' /etc/login.defs 2>/dev/null | awk '{print $2}')
    pw_min=$(grep '^PASS_MIN_DAYS' /etc/login.defs 2>/dev/null | awk '{print $2}')
    pw_len=$(grep '^PASS_MIN_LEN' /etc/login.defs 2>/dev/null | awk '{print $2}')
    pw_warn=$(grep '^PASS_WARN_AGE' /etc/login.defs 2>/dev/null | awk '{print $2}')
    pw_quality=$(grep 'pam_pwquality' /etc/pam.d/system-auth 2>/dev/null | head -1 || echo '未配置')

    # [2] 登录失败锁定
    local faillock tmout_val
    faillock=$(grep 'pam_faillock' /etc/pam.d/system-auth 2>/dev/null | head -1 || echo '未配置')
    tmout_val=$(grep '^TMOUT' /etc/profile 2>/dev/null | head -1 || echo '未配置')

    # [3] SSH配置
    local ssh_items=""
    for key in PermitRootLogin MaxAuthTries PermitEmptyPasswords Protocol ClientAliveInterval Banner; do
        local val
        val=$(grep -i "^${key}" /etc/ssh/sshd_config 2>/dev/null | head -1 || echo '未配置')
        ssh_items="${ssh_items}${key}|${val}"$'\n'
    done

    # [4] 用户账户
    local login_users uid0_users
    login_users=$(awk -F: '($7 !~ /nologin|false/) && ($3 >= 1000 || $3 == 0) {printf "%s (UID=%s, Shell=%s)\n", $1, $3, $7}' /etc/passwd)
    uid0_users=$(awk -F: '$3==0{print $1}' /etc/passwd | tr '\n' ' ')

    # [5] umask
    local umask_val
    umask_val=$(grep '^umask' /etc/profile 2>/dev/null | head -1 || echo '未配置')

    # [6] 审计服务
    local auditd_status rsyslog_status histsize_val
    auditd_status=$(systemctl is-active auditd 2>/dev/null || echo 'N/A')
    rsyslog_status=$(systemctl is-active rsyslog 2>/dev/null || echo 'N/A')
    histsize_val=$(grep '^HISTSIZE' /etc/profile 2>/dev/null | head -1 || echo '未配置')

    # [7] 文件权限
    local file_perms=""
    for f in /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/ssh/sshd_config; do
        if [[ -f "$f" ]]; then
            file_perms="${file_perms}$(stat -c '%a' "$f")|${f}"$'\n'
        fi
    done

    # [8] 内核参数
    local kernel_params=""
    for param in net.ipv4.ip_forward net.ipv4.tcp_syncookies kernel.randomize_va_space \
                 net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.rp_filter fs.suid_dumpable; do
        local kval
        kval=$(sysctl -n "$param" 2>/dev/null || echo 'N/A')
        kernel_params="${kernel_params}${param}|${kval}"$'\n'
    done

    # [9] 监听端口
    local listen_ports
    listen_ports=$(ss -tlnp 2>/dev/null || echo 'N/A')

    # [10] AIDE
    local aide_installed aide_db
    aide_installed=$(command -v aide &>/dev/null && echo '是' || echo '否')
    aide_db=$(ls /var/lib/aide/aide.db.gz 2>/dev/null && echo '已初始化' || echo '未初始化')

    # [11] hosts.allow/deny
    local hosts_allow_content hosts_deny_content
    hosts_allow_content=$(grep -v '^#' /etc/hosts.allow 2>/dev/null | grep -v '^$' || echo '(空)')
    hosts_deny_content=$(grep -v '^#' /etc/hosts.deny 2>/dev/null | grep -v '^$' || echo '(空)')

    # ---- 判定函数 ----
    _judge() {
        # 用法: _judge 当前值 期望值
        local current="$1" expected="$2"
        if [[ "$current" == "$expected" ]]; then echo "✅ 达标"; else echo "❌ 不达标(期望:$expected)"; fi
    }

    # ---- 输出 TXT ----
    _gen_txt() {
        local txt_file="$report_dir/security_check_${timestamp}.txt"
        {
            echo "================================================================"
            echo "  全员人口信息系统 - 安全基线检查报告"
            echo "  系统: $sys_name"
            echo "  主机名: $host_name"
            echo "  日期: $report_date"
            echo "================================================================"
            echo ""

            echo "[1] 密码策略"
            printf "  %-18s %-10s %s\n" "PASS_MAX_DAYS" "${pw_max:-N/A}" "$(_judge "${pw_max:-}" "90")"
            printf "  %-18s %-10s %s\n" "PASS_MIN_DAYS" "${pw_min:-N/A}" "$(_judge "${pw_min:-}" "2")"
            printf "  %-18s %-10s %s\n" "PASS_MIN_LEN"  "${pw_len:-N/A}" "$(_judge "${pw_len:-}" "8")"
            printf "  %-18s %-10s %s\n" "PASS_WARN_AGE" "${pw_warn:-N/A}" "$(_judge "${pw_warn:-}" "7")"
            echo "  pam_pwquality: $pw_quality"
            echo ""

            echo "[2] 登录失败锁定"
            echo "  pam_faillock: $faillock"
            echo "  TMOUT: $tmout_val"
            echo ""

            echo "[3] SSH配置"
            while IFS='|' read -r k v; do
                [[ -z "$k" ]] && continue
                printf "  %-24s %s\n" "$k" "$v"
            done <<< "$ssh_items"
            echo ""

            echo "[4] 用户账户"
            echo "  可登录用户:"
            echo "$login_users" | sed 's/^/    /'
            echo "  UID=0用户: $uid0_users"
            echo ""

            echo "[5] umask"
            echo "  $umask_val"
            echo ""

            echo "[6] 审计服务"
            printf "  %-12s %s\n" "auditd:" "$auditd_status"
            printf "  %-12s %s\n" "rsyslog:" "$rsyslog_status"
            echo "  HISTSIZE: $histsize_val"
            echo ""

            echo "[7] 文件权限"
            while IFS='|' read -r perm path; do
                [[ -z "$perm" ]] && continue
                printf "  %-6s %s\n" "$perm" "$path"
            done <<< "$file_perms"
            echo ""

            echo "[8] 内核安全参数"
            while IFS='|' read -r p v; do
                [[ -z "$p" ]] && continue
                printf "  %-45s = %s\n" "$p" "$v"
            done <<< "$kernel_params"
            echo ""

            echo "[9] 监听端口"
            echo "$listen_ports"
            echo ""

            echo "[10] AIDE完整性校验"
            echo "  安装: $aide_installed   数据库: $aide_db"
            echo ""

            echo "[11] hosts.allow/deny"
            echo "  hosts.allow: $hosts_allow_content"
            echo "  hosts.deny:  $hosts_deny_content"
            echo ""

            echo "================================================================"
            echo "  检查完成"
            echo "================================================================"
        } | tee "$txt_file"
        log_ok "TXT 报告: $txt_file"
    }

    # ---- 输出 Markdown ----
    _gen_md() {
        local md_file="$report_dir/security_check_${timestamp}.md"
        cat > "$md_file" << MDEOF
# 安全基线检查报告

| 项目 | 值 |
|------|------|
| **系统** | $sys_name |
| **主机名** | $host_name |
| **日期** | $report_date |

---

## 1. 密码策略

| 配置项 | 当前值 | 期望值 | 状态 |
|--------|--------|--------|------|
| PASS_MAX_DAYS | ${pw_max:-N/A} | 90 | $(_judge "${pw_max:-}" "90") |
| PASS_MIN_DAYS | ${pw_min:-N/A} | 2 | $(_judge "${pw_min:-}" "2") |
| PASS_MIN_LEN | ${pw_len:-N/A} | 8 | $(_judge "${pw_len:-}" "8") |
| PASS_WARN_AGE | ${pw_warn:-N/A} | 7 | $(_judge "${pw_warn:-}" "7") |

**pam_pwquality**: \`$pw_quality\`

## 2. 登录失败锁定

| 配置项 | 当前值 |
|--------|--------|
| pam_faillock | \`$faillock\` |
| TMOUT | \`$tmout_val\` |

## 3. SSH配置

| 配置项 | 当前值 |
|--------|--------|
MDEOF
        while IFS='|' read -r k v; do
            [[ -z "$k" ]] && continue
            echo "| $k | \`$v\` |" >> "$md_file"
        done <<< "$ssh_items"

        cat >> "$md_file" << MDEOF

## 4. 用户账户

**可登录用户:**
\`\`\`
$login_users
\`\`\`

**UID=0 用户:** \`$uid0_users\`

## 5. umask

当前值: \`$umask_val\`

## 6. 审计服务

| 服务 | 状态 |
|------|------|
| auditd | $auditd_status |
| rsyslog | $rsyslog_status |

**HISTSIZE:** \`$histsize_val\`

## 7. 文件权限

| 权限 | 文件路径 | 期望值 |
|------|----------|--------|
MDEOF
        local expect_perm
        while IFS='|' read -r perm path; do
            [[ -z "$perm" ]] && continue
            case "$path" in
                */shadow|*/gshadow) expect_perm="000" ;;
                */passwd|*/group)   expect_perm="644" ;;
                */sshd_config)      expect_perm="600" ;;
                *) expect_perm="-" ;;
            esac
            echo "| $perm | \`$path\` | $expect_perm |" >> "$md_file"
        done <<< "$file_perms"

        cat >> "$md_file" << MDEOF

## 8. 内核安全参数

| 参数 | 当前值 | 期望值 |
|------|--------|--------|
MDEOF
        while IFS='|' read -r p v; do
            [[ -z "$p" ]] && continue
            local expected
            case "$p" in
                *ip_forward|*accept_redirects|*suid_dumpable) expected="0" ;;
                *tcp_syncookies|*rp_filter) expected="1" ;;
                *randomize_va_space) expected="2" ;;
                *) expected="-" ;;
            esac
            echo "| \`$p\` | $v | $expected |" >> "$md_file"
        done <<< "$kernel_params"

        cat >> "$md_file" << MDEOF

## 9. 监听端口

\`\`\`
$listen_ports
\`\`\`

## 10. AIDE完整性校验

| 项目 | 状态 |
|------|------|
| 安装 | $aide_installed |
| 数据库 | $aide_db |

## 11. hosts.allow/deny

- **hosts.allow:** \`$hosts_allow_content\`
- **hosts.deny:** \`$hosts_deny_content\`

---

> 报告由 security_kylin.sh v${SCRIPT_VERSION} 自动生成
MDEOF
        log_ok "Markdown 报告: $md_file"
    }

    # ---- 输出 DOCX (通过 Node.js docx库) ----
    _gen_docx() {
        # 检查 node 和 docx 模块
        if ! command -v node &>/dev/null; then
            log_error "Node.js 未安装，无法生成 DOCX 报告。请安装: yum install nodejs"
            log_info "可使用 md 格式替代: bash security_kylin.sh report md"
            return 1
        fi

        # 尝试加载 docx 模块，不存在则安装
        if ! node -e "require('docx')" 2>/dev/null; then
            log_info "正在安装 docx 模块..."
            npm install -g docx 2>/dev/null || {
                log_error "docx 模块安装失败。请手动安装: npm install -g docx"
                return 1
            }
        fi

        local docx_file="$report_dir/security_check_${timestamp}.docx"
        local js_file="/tmp/gen_security_report_$$.js"

        # 将采集的数据导出为JSON供Node.js使用
        local data_file="/tmp/security_data_$$.json"
        cat > "$data_file" << JSONEOF
{
  "sysName": "$(echo "$sys_name" | sed 's/"/\\"/g')",
  "hostName": "$host_name",
  "reportDate": "$report_date",
  "version": "$SCRIPT_VERSION",
  "password": {
    "maxDays": "${pw_max:-N/A}", "minDays": "${pw_min:-N/A}",
    "minLen": "${pw_len:-N/A}", "warnAge": "${pw_warn:-N/A}",
    "pwquality": "$(echo "$pw_quality" | sed 's/"/\\"/g')"
  },
  "login": {
    "faillock": "$(echo "$faillock" | sed 's/"/\\"/g')",
    "tmout": "$(echo "$tmout_val" | sed 's/"/\\"/g')"
  },
  "ssh": [
$(idx=0; while IFS='|' read -r k v; do
    [[ -z "$k" ]] && continue
    [[ $idx -gt 0 ]] && echo ","
    printf '    {"key":"%s","value":"%s"}' "$k" "$(echo "$v" | sed 's/"/\\"/g')"
    idx=$((idx+1))
done <<< "$ssh_items")
  ],
  "users": {
    "loginUsers": "$(echo "$login_users" | tr '\n' ';' | sed 's/"/\\"/g')",
    "uid0": "$(echo "$uid0_users" | sed 's/"/\\"/g')"
  },
  "umask": "$(echo "$umask_val" | sed 's/"/\\"/g')",
  "audit": {
    "auditd": "$auditd_status", "rsyslog": "$rsyslog_status",
    "histsize": "$(echo "$histsize_val" | sed 's/"/\\"/g')"
  },
  "filePerms": [
$(idx=0; while IFS='|' read -r perm path; do
    [[ -z "$perm" ]] && continue
    [[ $idx -gt 0 ]] && echo ","
    local ep
    case "$path" in
        */shadow|*/gshadow) ep="000" ;;
        */passwd|*/group)   ep="644" ;;
        */sshd_config)      ep="600" ;;
        *) ep="-" ;;
    esac
    printf '    {"perm":"%s","path":"%s","expected":"%s"}' "$perm" "$path" "$ep"
    idx=$((idx+1))
done <<< "$file_perms")
  ],
  "kernel": [
$(idx=0; while IFS='|' read -r p v; do
    [[ -z "$p" ]] && continue
    [[ $idx -gt 0 ]] && echo ","
    local exp
    case "$p" in
        *ip_forward|*accept_redirects|*suid_dumpable) exp="0" ;;
        *tcp_syncookies|*rp_filter) exp="1" ;;
        *randomize_va_space) exp="2" ;;
        *) exp="-" ;;
    esac
    printf '    {"param":"%s","value":"%s","expected":"%s"}' "$p" "$v" "$exp"
    idx=$((idx+1))
done <<< "$kernel_params")
  ],
  "ports": "$(echo "$listen_ports" | head -30 | tr '\n' ';' | sed 's/"/\\"/g')",
  "aide": { "installed": "$aide_installed", "db": "$aide_db" },
  "hosts": {
    "allow": "$(echo "$hosts_allow_content" | tr '\n' ';' | sed 's/"/\\"/g')",
    "deny": "$(echo "$hosts_deny_content" | tr '\n' ';' | sed 's/"/\\"/g')"
  }
}
JSONEOF

        # 生成Node.js脚本
        cat > "$js_file" << 'JSEOF'
const fs = require("fs");
const { Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
        Header, Footer, AlignmentType, HeadingLevel, BorderStyle, WidthType,
        ShadingType, VerticalAlign, PageNumber, PageBreak, LevelFormat } = require("docx");

const data = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const outFile = process.argv[3];

const border = { style: BorderStyle.SINGLE, size: 1, color: "999999" };
const borders = { top: border, bottom: border, left: border, right: border };
const hdrShading = { fill: "2B579A", type: ShadingType.CLEAR };
const altShading = { fill: "F2F2F2", type: ShadingType.CLEAR };
const passShading = { fill: "E8F5E9", type: ShadingType.CLEAR };
const failShading = { fill: "FFEBEE", type: ShadingType.CLEAR };

function hdrCell(text, width) {
  return new TableCell({ borders, width: { size: width, type: WidthType.DXA }, shading: hdrShading, verticalAlign: VerticalAlign.CENTER,
    children: [new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 60, after: 60 },
      children: [new TextRun({ text, bold: true, color: "FFFFFF", size: 20, font: "Arial" })] })] });
}
function cell(text, width, shading) {
  const opts = { borders, width: { size: width, type: WidthType.DXA }, verticalAlign: VerticalAlign.CENTER,
    children: [new Paragraph({ spacing: { before: 40, after: 40 },
      children: [new TextRun({ text: text || "", size: 20, font: "Arial" })] })] };
  if (shading) opts.shading = shading;
  return new TableCell(opts);
}
function judge(cur, exp) { return cur === exp ? "达标" : "不达标"; }
function statusShading(cur, exp) { return cur === exp ? passShading : failShading; }

function heading(text, level) {
  return new Paragraph({ heading: level || HeadingLevel.HEADING_1,
    spacing: { before: 240, after: 120 },
    children: [new TextRun({ text, font: "Arial" })] });
}

// -- Build sections --
const children = [];

// Title
children.push(new Paragraph({ heading: HeadingLevel.TITLE, alignment: AlignmentType.CENTER,
  spacing: { before: 400, after: 200 },
  children: [new TextRun({ text: "安全基线检查报告", bold: true, size: 44, font: "Arial" })] }));

// Info table
children.push(new Table({ columnWidths: [2400, 6960],
  rows: [
    new TableRow({ children: [ hdrCell("项目", 2400), hdrCell("信息", 6960) ] }),
    new TableRow({ children: [ cell("系统", 2400), cell(data.sysName, 6960) ] }),
    new TableRow({ children: [ cell("主机名", 2400, altShading), cell(data.hostName, 6960, altShading) ] }),
    new TableRow({ children: [ cell("日期", 2400), cell(data.reportDate, 6960) ] }),
  ]
}));
children.push(new Paragraph({ children: [] }));

// 1. Password
children.push(heading("1. 密码策略"));
const pwRows = [
  ["PASS_MAX_DAYS", data.password.maxDays, "90"],
  ["PASS_MIN_DAYS", data.password.minDays, "2"],
  ["PASS_MIN_LEN",  data.password.minLen,  "8"],
  ["PASS_WARN_AGE", data.password.warnAge, "7"],
];
children.push(new Table({ columnWidths: [2400, 2000, 2000, 2960],
  rows: [
    new TableRow({ children: [hdrCell("配置项",2400), hdrCell("当前值",2000), hdrCell("期望值",2000), hdrCell("状态",2960)] }),
    ...pwRows.map((r, i) => new TableRow({ children: [
      cell(r[0], 2400, i%2?altShading:undefined), cell(r[1], 2000, i%2?altShading:undefined),
      cell(r[2], 2000, i%2?altShading:undefined), cell(judge(r[1],r[2]), 2960, statusShading(r[1],r[2]))
    ]}))
  ]
}));
children.push(new Paragraph({ spacing: { before: 80 }, children: [
  new TextRun({ text: "pam_pwquality: ", bold: true, size: 20, font: "Arial" }),
  new TextRun({ text: data.password.pwquality, size: 18, font: "Courier New" })
]}));

// 2. Login
children.push(heading("2. 登录失败锁定"));
children.push(new Table({ columnWidths: [2400, 6960],
  rows: [
    new TableRow({ children: [hdrCell("配置项",2400), hdrCell("当前值",6960)] }),
    new TableRow({ children: [cell("pam_faillock",2400), cell(data.login.faillock,6960)] }),
    new TableRow({ children: [cell("TMOUT",2400,altShading), cell(data.login.tmout,6960,altShading)] }),
  ]
}));

// 3. SSH
children.push(heading("3. SSH配置"));
const sshTableRows = [new TableRow({ children: [hdrCell("配置项",3600), hdrCell("当前值",5760)] })];
data.ssh.forEach((s,i) => sshTableRows.push(new TableRow({ children: [
  cell(s.key, 3600, i%2?altShading:undefined), cell(s.value, 5760, i%2?altShading:undefined)
]})));
children.push(new Table({ columnWidths: [3600, 5760], rows: sshTableRows }));

// 4. Users
children.push(heading("4. 用户账户"));
children.push(new Paragraph({ spacing:{before:80}, children: [new TextRun({ text: "可登录用户:", bold: true, size: 20, font: "Arial" })] }));
data.users.loginUsers.split(";").filter(Boolean).forEach(u => {
  children.push(new Paragraph({ indent: { left: 360 }, children: [new TextRun({ text: u.trim(), size: 20, font: "Courier New" })] }));
});
children.push(new Paragraph({ spacing:{before:80}, children: [
  new TextRun({ text: "UID=0 用户: ", bold: true, size: 20, font: "Arial" }),
  new TextRun({ text: data.users.uid0, size: 20, font: "Arial" })
]}));

// 5. umask
children.push(heading("5. umask"));
children.push(new Paragraph({ children: [
  new TextRun({ text: "当前值: ", bold: true, size: 20, font: "Arial" }),
  new TextRun({ text: data.umask, size: 20, font: "Courier New" })
]}));

// 6. Audit
children.push(heading("6. 审计服务"));
children.push(new Table({ columnWidths: [3120, 3120, 3120],
  rows: [
    new TableRow({ children: [hdrCell("服务",3120), hdrCell("状态",3120), hdrCell("判定",3120)] }),
    new TableRow({ children: [cell("auditd",3120), cell(data.audit.auditd,3120),
      cell(data.audit.auditd==="active"?"达标":"不达标",3120,data.audit.auditd==="active"?passShading:failShading)] }),
    new TableRow({ children: [cell("rsyslog",3120,altShading), cell(data.audit.rsyslog,3120,altShading),
      cell(data.audit.rsyslog==="active"?"达标":"不达标",3120,data.audit.rsyslog==="active"?passShading:failShading)] }),
  ]
}));
children.push(new Paragraph({ spacing:{before:80}, children: [
  new TextRun({ text: "HISTSIZE: ", bold: true, size: 20, font: "Arial" }),
  new TextRun({ text: data.audit.histsize, size: 20, font: "Courier New" })
]}));

// 7. File perms
children.push(heading("7. 文件权限"));
const fpRows = [new TableRow({ children: [hdrCell("权限",1800), hdrCell("文件路径",4200), hdrCell("期望值",1800), hdrCell("状态",1560)] })];
data.filePerms.forEach((fp,i) => {
  const st = fp.expected==="-" || fp.perm===fp.expected ? "达标" : "不达标";
  const sh = st==="达标" ? passShading : failShading;
  fpRows.push(new TableRow({ children: [
    cell(fp.perm,1800,i%2?altShading:undefined), cell(fp.path,4200,i%2?altShading:undefined),
    cell(fp.expected,1800,i%2?altShading:undefined), cell(st,1560,sh)
  ]}));
});
children.push(new Table({ columnWidths: [1800, 4200, 1800, 1560], rows: fpRows }));

// 8. Kernel
children.push(heading("8. 内核安全参数"));
const kRows = [new TableRow({ children: [hdrCell("参数",4200), hdrCell("当前值",1800), hdrCell("期望值",1800), hdrCell("状态",1560)] })];
data.kernel.forEach((k,i) => {
  const st = k.expected==="-" || k.value===k.expected ? "达标" : "不达标";
  const sh = st==="达标" ? passShading : failShading;
  kRows.push(new TableRow({ children: [
    cell(k.param,4200,i%2?altShading:undefined), cell(k.value,1800,i%2?altShading:undefined),
    cell(k.expected,1800,i%2?altShading:undefined), cell(st,1560,sh)
  ]}));
});
children.push(new Table({ columnWidths: [4200, 1800, 1800, 1560], rows: kRows }));

// 9. Ports
children.push(heading("9. 监听端口"));
data.ports.split(";").filter(Boolean).forEach(line => {
  children.push(new Paragraph({ spacing:{before:20,after:20}, children: [new TextRun({ text: line.trim(), size: 18, font: "Courier New" })] }));
});

// 10. AIDE
children.push(heading("10. AIDE完整性校验"));
children.push(new Table({ columnWidths: [4680, 4680],
  rows: [
    new TableRow({ children: [hdrCell("项目",4680), hdrCell("状态",4680)] }),
    new TableRow({ children: [cell("AIDE安装",4680), cell(data.aide.installed,4680, data.aide.installed==="是"?passShading:failShading)] }),
    new TableRow({ children: [cell("数据库",4680,altShading), cell(data.aide.db,4680,data.aide.db==="已初始化"?passShading:failShading)] }),
  ]
}));

// 11. hosts
children.push(heading("11. hosts.allow/deny"));
children.push(new Paragraph({ children: [new TextRun({ text: "hosts.allow: ", bold: true, size: 20, font: "Arial" }), new TextRun({ text: data.hosts.allow, size: 20, font: "Courier New" })] }));
children.push(new Paragraph({ children: [new TextRun({ text: "hosts.deny: ", bold: true, size: 20, font: "Arial" }), new TextRun({ text: data.hosts.deny, size: 20, font: "Courier New" })] }));

// Footer
children.push(new Paragraph({ children: [] }));
children.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 400 },
  children: [new TextRun({ text: "报告由 security_kylin.sh v" + data.version + " 自动生成", italics: true, size: 18, color: "999999", font: "Arial" })] }));

const doc = new Document({
  styles: {
    default: { document: { run: { font: "Arial", size: 22 } } },
    paragraphStyles: [
      { id: "Title", name: "Title", basedOn: "Normal",
        run: { size: 44, bold: true, font: "Arial" },
        paragraph: { spacing: { before: 400, after: 200 }, alignment: AlignmentType.CENTER } },
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 28, bold: true, color: "2B579A", font: "Arial" },
        paragraph: { spacing: { before: 300, after: 120 }, outlineLevel: 0 } },
    ]
  },
  sections: [{
    properties: { page: { margin: { top: 1200, right: 1200, bottom: 1200, left: 1200 } } },
    headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
      children: [new TextRun({ text: "全员人口信息系统 - 安全基线检查", size: 16, color: "999999", font: "Arial" })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
      children: [new TextRun({ text: "第 ", size: 16, font: "Arial" }), new TextRun({ children: [PageNumber.CURRENT], size: 16, font: "Arial" }),
               new TextRun({ text: " 页 / 共 ", size: 16, font: "Arial" }), new TextRun({ children: [PageNumber.TOTAL_PAGES], size: 16, font: "Arial" }),
               new TextRun({ text: " 页", size: 16, font: "Arial" })] })] }) },
    children
  }]
});

Packer.toBuffer(doc).then(buf => { fs.writeFileSync(outFile, buf); process.exit(0); })
  .catch(e => { console.error(e); process.exit(1); });
JSEOF

        log_info "正在生成 DOCX 报告..."
        if node "$js_file" "$data_file" "$docx_file"; then
            log_ok "DOCX 报告: $docx_file"
        else
            log_error "DOCX 生成失败，请检查 Node.js 和 docx 模块"
        fi

        # 清理临时文件
        rm -f "$js_file" "$data_file"
    }

    # ---- 根据格式输出 ----
    case "$format" in
        txt)
            _gen_txt
            ;;
        md)
            _gen_md
            ;;
        docx)
            _gen_docx
            ;;
        all)
            _gen_txt
            echo ""
            _gen_md
            _gen_docx
            ;;
        *)
            log_error "不支持的格式: $format (可选: txt / md / docx / all)"
            return 1
            ;;
    esac

    echo ""
    log_info "所有报告保存在: $report_dir/"
    ls -lh "$report_dir"/security_check_${timestamp}.* 2>/dev/null | tee -a "$LOG_FILE"
}

# ========================= 菜单系统 =========================
show_menu() {
    clear
    echo -e "${Bold}${Cyan}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║     全员人口信息系统 - 安全基线加固脚本 v${SCRIPT_VERSION}               ║"
    echo "║     适配: Kylin Linux Advanced Server V10 (Halberd)          ║"
    echo "║     等保: GB/T 22239-2019 第三级                              ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║                                                              ║"
    echo "║   1.  密码策略加固 (复杂度/有效期/历史)                        ║"
    echo "║   2.  登录失败处理 + 会话超时 (faillock/TMOUT)                ║"
    echo "║   3.  SSH安全加固 (禁root登录/协议/Banner)  ⚠ 可能断连        ║"
    echo "║   4.  网络访问控制 (hosts.allow/deny)      ⚠ 可能断连        ║"
    echo "║   5.  三权分立用户配置 (sysadmin/审计/安全)                    ║"
    echo "║   6.  umask权限掩码加固 (0027)                                ║"
    echo "║   7.  安全审计加固 (auditd规则/日志保护)                       ║"
    echo "║   8.  历史命令清除 (HISTSIZE=0)                               ║"
    echo "║   9.  关键文件权限加固                                        ║"
    echo "║  10.  内核安全参数加固 (sysctl)                               ║"
    echo "║  11.  不安全服务检查与关闭                                     ║"
    echo "║  12.  完整性校验工具 (AIDE)                                   ║"
    echo "║  13.  多余/过期账户清理                                       ║"
    echo "║  14.  配置数据备份                                            ║"
    echo "║  15.  安全状态检查报告 (支持 txt/md/docx/all)                  ║"
    echo "║                                                              ║"
    echo "║  all  一键全部执行 (自动跳过 3/4 防止断连)                     ║"
    echo "║   r   恢复配置 (从备份还原)                                    ║"
    echo "║   0   退出                                                    ║"
    echo "║                                                              ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${Font}"

    read -rp "请输入编号: " num
    case "$num" in
        1)  harden_password_policy ;;
        2)  harden_login_policy ;;
        3)  log_warn "⚠ SSH加固将修改 PermitRootLogin=no 并重启sshd，可能导致当前SSH断连!"
            log_warn "  请确保已有普通用户(如 sysadmin)可通过SSH登录后再执行"
            read -rp "  确认执行? [y/N]: " _ssh_ans
            [[ "${_ssh_ans,,}" == "y" ]] && harden_ssh || log_info "已跳过SSH加固"
            ;;
        4)  log_warn "⚠ hosts.allow/deny 配置不当将导致所有SSH连接被拒绝!"
            log_warn "  请提前确认要放行的IP/网段"
            read -rp "  确认执行? [y/N]: " _host_ans
            [[ "${_host_ans,,}" == "y" ]] && harden_hosts_access || log_info "已跳过hosts访问控制"
            ;;
        5)  harden_separation_of_duties ;;
        6)  harden_umask ;;
        7)  harden_audit ;;
        8)  harden_histsize ;;
        9)  harden_file_permissions ;;
        10) harden_kernel_params ;;
        11) harden_disable_services ;;
        12) harden_integrity_check ;;
        13) harden_cleanup_accounts ;;
        14) harden_config_backup ;;
        15) read -rp "  报告格式 [txt/md/docx/all](默认all): " _fmt
            security_check_report "${_fmt:-all}" ;;
        all|ALL) run_all ;;
        r|R|restore) restore_config ;;
        0)  echo -e "\n"; exit 0 ;;
        *)  log_error "请输入有效编号 [0-15, all, r]"; sleep 1 ;;
    esac

    return_to_menu
}

return_to_menu() {
    echo ""
    log_info "是否返回菜单继续配置 [Y/n]"
    local answer="" t=60
    while [[ -z "$answer" && $t -gt 0 ]]; do
        printf "\r%2d 秒后将自动退出脚本: " "$t"
        read -r -t 1 -n 1 answer || true
        t=$((t - 1))
    done
    [[ -z "$answer" ]] && answer="n"
    if [[ "${answer,,}" == "y" ]]; then
        show_menu
    else
        echo -e "\n"
        exit 0
    fi
}

# 一键全部执行
# 默认跳过 SSH加固(3)、hosts访问控制(4)，防止远程SSH断连
# 如需执行这些高危项，请从菜单中单独选择 3 或 4
run_all() {
    section "一键执行全部安全加固"

    echo ""
    log_warn "以下高危项将被 ⚠ 跳过（可能导致SSH断连）:"
    log_warn "  [3] SSH安全加固 (PermitRootLogin=no / 重启sshd)"
    log_warn "  [4] 网络访问控制 (hosts.allow/hosts.deny)"
    echo ""
    log_info "如需执行以上项目，请一键加固完成后从菜单单独选择"
    echo ""
    read -rp "确认继续? [y/N]: " ans
    [[ "${ans,,}" != "y" ]] && return

    mkdir -p "$BACKUP_DIR"
    echo "备份目录: $BACKUP_DIR" | tee -a "$LOG_FILE"

    harden_password_policy           # 1.  密码策略
    harden_login_policy              # 2.  登录失败处理 + 会话超时
    # ---- 跳过 3. SSH加固 ----
    # ---- 跳过 4. hosts访问控制 ----
    harden_separation_of_duties      # 5.  三权分立用户
    harden_umask                     # 6.  umask
    harden_audit                     # 7.  审计服务
    harden_histsize                  # 8.  历史命令
    harden_file_permissions          # 9.  文件权限
    harden_kernel_params             # 10. 内核参数
    harden_disable_services          # 11. 不安全服务
    harden_integrity_check           # 12. AIDE
    harden_cleanup_accounts          # 13. 账户清理
    harden_config_backup             # 14. 配置备份
    security_check_report            # 15. 检查报告

    separator
    echo ""
    log_ok "安全加固执行完成! (共执行 13 项)"
    log_info "备份目录: $BACKUP_DIR"
    log_info "日志文件: $LOG_FILE"
    echo ""
    log_warn "═══════════════════════════════════════════════════════════"
    log_warn "  以下 2 项未执行，需要从菜单手动选择:"
    log_warn "  [3] SSH安全加固  — 执行前请确保已有普通用户可登录"
    log_warn "  [4] hosts访问控制 — 执行前请确认允许访问的IP白名单"
    log_warn "═══════════════════════════════════════════════════════════"
    separator
}

# ========================= 配置恢复 =========================
# 从备份目录恢复所有配置文件到原始位置
# 用法: bash security_kylin.sh restore [备份目录]
restore_config() {
    section "配置恢复"

    local backup_root="/root/security_backup"
    local target_dir="${1:-}"

    # 列出可用备份
    if [[ ! -d "$backup_root" ]]; then
        log_error "备份目录不存在: $backup_root"
        log_info "没有可恢复的备份"
        return 1
    fi

    local backups=()
    while IFS= read -r d; do
        [[ -d "$d" ]] && backups+=("$d")
    done < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [[ ${#backups[@]} -eq 0 ]]; then
        log_error "未找到任何备份"
        return 1
    fi

    # 如果没有指定备份目录，交互式选择
    if [[ -z "$target_dir" ]]; then
        echo ""
        log_info "可用备份列表 (按时间倒序):"
        echo ""
        local i=1
        for b in "${backups[@]}"; do
            local bname
            bname=$(basename "$b")
            local fcount
            fcount=$(find "$b" -type f | wc -l)
            printf "  ${Cyan}%2d${Font})  %s  (%d 个文件)\n" "$i" "$bname" "$fcount"
            # 列出备份中的文件
            find "$b" -type f | while read -r f; do
                local relpath="${f#$b}"
                printf "       └─ %s\n" "$relpath"
            done
            echo ""
            i=$((i + 1))
        done

        read -rp "请选择要恢复的备份编号 (1-${#backups[@]}) 或输入 0 取消: " choice

        if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
            log_info "已取消恢复"
            return 0
        fi

        if [[ "$choice" -lt 1 || "$choice" -gt ${#backups[@]} ]] 2>/dev/null; then
            log_error "无效选择: $choice"
            return 1
        fi

        target_dir="${backups[$((choice - 1))]}"
    fi

    # 验证备份目录
    if [[ ! -d "$target_dir" ]]; then
        # 可能传入的是备份名而非完整路径
        if [[ -d "$backup_root/$target_dir" ]]; then
            target_dir="$backup_root/$target_dir"
        else
            log_error "备份目录不存在: $target_dir"
            return 1
        fi
    fi

    local bname
    bname=$(basename "$target_dir")
    log_info "选中备份: $bname"
    echo ""

    # 列出将要恢复的文件
    log_info "将要恢复以下文件:"
    local restore_files=()
    while IFS= read -r f; do
        local restore_to="${f#$target_dir}"
        restore_files+=("$f|$restore_to")
        if [[ -f "$restore_to" ]]; then
            printf "  ${Yellow}覆盖${Font}  %s\n" "$restore_to"
        else
            printf "  ${Green}新建${Font}  %s\n" "$restore_to"
        fi
    done < <(find "$target_dir" -type f)
    echo ""

    if [[ ${#restore_files[@]} -eq 0 ]]; then
        log_error "备份目录为空"
        return 1
    fi

    # 二次确认
    log_warn "⚠ 恢复操作将覆盖当前系统配置文件！"
    read -rp "确认恢复? [y/N]: " ans
    if [[ "${ans,,}" != "y" ]]; then
        log_info "已取消恢复"
        return 0
    fi

    # 恢复前先备份当前状态（防止恢复出问题还能再恢复）
    local pre_restore_dir="${backup_root}/pre_restore_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$pre_restore_dir"

    local restored=0
    local failed=0
    for entry in "${restore_files[@]}"; do
        local src="${entry%%|*}"
        local dst="${entry##*|}"

        # 备份当前文件
        if [[ -f "$dst" ]]; then
            cp -a --parents "$dst" "$pre_restore_dir/" 2>/dev/null || true
        fi

        # 恢复
        local dst_dir
        dst_dir=$(dirname "$dst")
        mkdir -p "$dst_dir" 2>/dev/null || true

        if cp -a "$src" "$dst" 2>/dev/null; then
            log_ok "已恢复: $dst"
            restored=$((restored + 1))
        else
            log_error "恢复失败: $dst"
            failed=$((failed + 1))
        fi
    done

    echo ""
    separator
    log_ok "恢复完成: 成功 $restored 个, 失败 $failed 个"
    log_info "恢复前的配置已备份到: $pre_restore_dir"
    echo ""

    # 提示重启服务
    log_warn "以下服务可能需要重启以使恢复的配置生效:"
    echo "  systemctl restart sshd      # SSH配置"
    echo "  systemctl restart auditd    # 审计配置"
    echo "  systemctl restart rsyslog   # 日志配置"
    echo "  source /etc/profile         # 环境变量(TMOUT/umask/HISTSIZE)"
    echo "  sysctl --system             # 内核参数"
    echo ""
    read -rp "是否立即重启以上服务? [y/N]: " restart_ans
    if [[ "${restart_ans,,}" == "y" ]]; then
        systemctl restart sshd 2>/dev/null && log_ok "sshd 已重启" || log_warn "sshd 重启失败"
        systemctl restart auditd 2>/dev/null && log_ok "auditd 已重启" || log_warn "auditd 重启失败"
        systemctl restart rsyslog 2>/dev/null && log_ok "rsyslog 已重启" || log_warn "rsyslog 重启失败"
        sysctl --system 2>/dev/null && log_ok "内核参数已重载" || log_warn "内核参数重载失败"
        source /etc/profile 2>/dev/null || true
        log_ok "所有服务已重启"
    else
        log_info "请手动重启相关服务"
    fi
}

# ========================= 帮助信息 =========================
show_help() {
    echo ""
    echo "用法: bash $(basename "$0") [命令]"
    echo ""
    echo "不带参数启动交互式菜单。支持以下命令直接执行："
    echo ""
    echo "  一键执行:"
    echo "    all                一键执行全部加固（自动跳过 ssh/hosts 防断连）"
    echo ""
    echo "  单项执行:"
    echo "    password           1.  密码策略加固 (复杂度/有效期/历史)"
    echo "    login              2.  登录失败处理 + 会话超时 (faillock/TMOUT)"
    echo "    ssh                3.  SSH安全加固 (禁root登录/协议/Banner)  ⚠"
    echo "    hosts              4.  网络访问控制 (hosts.allow/deny)       ⚠"
    echo "    users              5.  三权分立用户配置 (sysadmin/审计/安全)"
    echo "    umask              6.  umask权限掩码加固 (0027)"
    echo "    audit              7.  安全审计加固 (auditd规则/日志保护)"
    echo "    history            8.  历史命令清除 (HISTSIZE=0)"
    echo "    fileperm           9.  关键文件权限加固"
    echo "    kernel            10.  内核安全参数加固 (sysctl)"
    echo "    services          11.  不安全服务检查与关闭"
    echo "    aide              12.  完整性校验工具 (AIDE)"
    echo "    accounts          13.  多余/过期账户清理"
    echo "    backup            14.  配置数据备份"
    echo "    report [格式]     15.  安全状态检查报告 (格式: txt/md/docx/all, 默认all)"
    echo ""
    echo "  ⚠ 标记项可能导致SSH断连，请确保有备用登录方式后再执行"
    echo ""
    echo "  恢复:"
    echo "    restore [备份目录]  从备份恢复所有配置文件 (交互式选择或指定目录)"
    echo ""
    echo "示例:"
    echo "    bash $(basename "$0")               # 交互式菜单"
    echo "    bash $(basename "$0") all            # 一键加固（安全）"
    echo "    bash $(basename "$0") report         # 生成全部格式报告 (txt+md+docx)"
    echo "    bash $(basename "$0") report md      # 仅生成 Markdown 报告"
    echo "    bash $(basename "$0") report docx    # 仅生成 Word 报告"
    echo "    bash $(basename "$0") password       # 仅执行密码策略加固"
    echo "    bash $(basename "$0") ssh            # 单独执行SSH加固"
    echo "    bash $(basename "$0") restore        # 交互式选择备份恢复"
    echo "    bash $(basename "$0") restore 20260416_155137  # 恢复指定备份"
    echo ""
    echo "报告与日志:"
    echo "    检查报告: /root/security_reports/security_check_<时间戳>.[txt|md|docx]"
    echo "    执行日志: $LOG_FILE"
    echo "    配置备份: /root/security_backup/<时间戳>/  (保留完整目录结构)"
    echo "    密码文件: /root/security_backup/<时间戳>/passwords.txt"
    echo ""
}

# ========================= 入口 =========================
main() {
    # --help / -h 不需要 root
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]; then
        show_help
        exit 0
    fi

    check_root
    check_os

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "========== $(date) ==========" >> "$LOG_FILE"

    if [[ $# -eq 0 ]]; then
        show_menu
        exit 0
    fi

    # 命令别名映射
    case "$1" in
        all)        run_all ;;
        password)   harden_password_policy ;;
        login)      harden_login_policy ;;
        ssh)        harden_ssh ;;
        hosts)      harden_hosts_access ;;
        users)      harden_separation_of_duties ;;
        umask)      harden_umask ;;
        audit)      harden_audit ;;
        history)    harden_histsize ;;
        fileperm)   harden_file_permissions ;;
        kernel)     harden_kernel_params ;;
        services)   harden_disable_services ;;
        aide)       harden_integrity_check ;;
        accounts)   harden_cleanup_accounts ;;
        backup)     harden_config_backup ;;
        report)     security_check_report "${2:-all}" ;;
        restore)    restore_config "${2:-}" ;;
        # 兼容：也支持直接传函数名
        harden_*|security_*|run_*|restore_*) "$@" ;;
        *)
            log_error "未知命令: $1"
            echo "运行 'bash $(basename "$0") --help' 查看所有可用命令"
            exit 1
            ;;
    esac
}

main "$@"
