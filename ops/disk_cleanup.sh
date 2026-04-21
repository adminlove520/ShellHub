#!/usr/bin/env bash
# =============================================================================
#  disk_cleanup.sh — 通用 Linux 磁盘清理工具
# -----------------------------------------------------------------------------
#  适配系统:
#    - CentOS 7 / 8 / 9 (Stream)
#    - RHEL / Rocky / AlmaLinux 7-9
#    - Ubuntu 18.04 / 20.04 / 22.04 / 24.04
#    - Debian 10 / 11 / 12
#    - 麒麟 Kylin V10 (Halberd / SP1 / SP2 / SP3)
#    - 华为 EulerOS / openEuler 20.03+ / 22.03+
#    - 龙蜥 Anolis OS 7 / 8 / 23
#    - 统信 UOS Server / Desktop 20+
#
#  设计原则:
#    1. 先识别系统 → 选择对应包管理器与清理策略
#    2. 区分安全/中危/高危操作; --all 默认仅执行安全+中危
#    3. 高危操作 (Docker全镜像清理/旧内核删除/用户大文件) 需显式开关
#    4. 全程支持 --dry-run; 危险操作二次确认
#    5. 记录详细日志到 /var/log/disk_cleanup.log
#    6. 清理前后磁盘容量对比
#
#  Author : ShellHub - ops/
#  License: 内部使用
# =============================================================================

set -o pipefail
# 注意: 故意不使用 set -e
#   清理任务的设计目标是"尽力而为", 单个子命令失败 (例如某个文件不存在/被锁)
#   不应中断后续模块. 我们用 _log/run 显式追踪每一步的结果.
# 允许未匹配的 glob 返回空, 防止 'for f in /path/*' 把通配符当字面量处理
shopt -s nullglob 2>/dev/null || true
# 创建文件默认权限: 仅 root 可读写
umask 077

# -----------------------------------------------------------------------------
# 0. 全局变量与默认参数
# -----------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/disk_cleanup.log"
readonly TARGET_DISK="${TARGET_DISK:-/}"   # 用于容量对比的挂载点

# 命令行开关 (默认值)
DRY_RUN=0
ASSUME_YES=0
INCLUDE_DOCKER_IMAGES=0      # --include-docker-images : 删除全部未使用镜像
INCLUDE_OLD_KERNELS=0        # --include-old-kernels   : 删除旧内核
INCLUDE_HOME_LARGE=0         # --include-home-large    : 扫描并提示用户大文件
JOURNAL_KEEP="200M"          # journal 保留量
LOG_KEEP_DAYS=30             # /var/log 下普通日志的保留天数
TMP_KEEP_DAYS=7              # /tmp 文件保留天数
VARTMP_KEEP_DAYS=30          # /var/tmp 文件保留天数

# 颜色
if [[ -t 1 ]]; then
    readonly C_RED=$'\033[1;31m'
    readonly C_GRN=$'\033[1;32m'
    readonly C_YLW=$'\033[1;33m'
    readonly C_BLU=$'\033[1;34m'
    readonly C_CYA=$'\033[1;36m'
    readonly C_DIM=$'\033[2m'
    readonly C_RST=$'\033[0m'
else
    readonly C_RED="" C_GRN="" C_YLW="" C_BLU="" C_CYA="" C_DIM="" C_RST=""
fi

# 系统识别结果
OS_ID=""          # centos / ubuntu / debian / kylin / euleros / openeuler / anolis / uos / rhel / rocky / almalinux
OS_VERSION=""     # 7 / 8 / 9 / 22.04 / V10 ...
OS_FAMILY=""      # rhel / debian
PKG_MGR=""        # yum / dnf / apt
SVC_MGR=""        # systemd / sysv

# -----------------------------------------------------------------------------
# 1. 日志与输出
# -----------------------------------------------------------------------------
_log() {
    local lvl="$1"; shift
    local ts msg color
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="[$ts] [$lvl] $*"
    case "$lvl" in
        INFO)  color="$C_BLU" ;;
        OK)    color="$C_GRN" ;;
        WARN)  color="$C_YLW" ;;
        ERR)   color="$C_RED" ;;
        DRY)   color="$C_CYA" ;;
        *)     color="" ;;
    esac
    printf '%b%s%b\n' "$color" "$msg" "$C_RST"
    # 写入日志文件 (失败时静默, 例如非 root 运行 dry-run/无 /var/log 写权限)
    # 重定向自身的失败 ("Permission denied") 来自 shell, 不能被 2>/dev/null 拦截;
    # 故先做一次可写性预检, 仅在文件可写时才追加.
    [[ -n "$LOG_FILE_WRITABLE" ]] && printf '%s\n' "$msg" >>"$LOG_FILE" 2>/dev/null
    return 0
}

info()  { _log INFO "$@"; }
ok()    { _log OK   "$@"; }
warn()  { _log WARN "$@"; }
err()   { _log ERR  "$@"; }
dry()   { _log DRY  "$@"; }

print_banner() {
    cat <<EOF
${C_CYA}===============================================================${C_RST}
${C_CYA}        通用 Linux 磁盘清理工具  v${SCRIPT_VERSION}${C_RST}
${C_CYA}        适配 CentOS/Ubuntu/Debian/Kylin/Euler/Anolis/UOS${C_RST}
${C_CYA}===============================================================${C_RST}
EOF
}

# 二次确认 (--yes 跳过)
confirm() {
    local prompt="$1"
    [[ $ASSUME_YES -eq 1 ]] && return 0
    [[ $DRY_RUN  -eq 1 ]] && return 0
    local ans
    read -r -p "${C_YLW}${prompt} [y/N]: ${C_RST}" ans </dev/tty || return 1
    [[ "$ans" =~ ^[Yy]$ ]]
}

# 安全执行 (字符串模式): dry-run 时只打印, 否则通过 bash -c 执行
# 用法: run "command with args > /dev/null"
# 说明: 我们的清理命令多含管道/重定向/通配符, 因此使用 shell 解析模式;
#       所有用户输入均不进入 run 字符串, 由我们自己控制.
run() {
    local cmd="$*"
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "DRY-RUN: $cmd"
        return 0
    fi
    bash -c "$cmd"
}

# 安全执行 (数组模式): 直接执行命令, 不经 shell 解析, 适合参数含空格的场景
# 用法: run_argv truncate -s 0 "$file"
run_argv() {
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "DRY-RUN: $*"
        return 0
    fi
    "$@"
}

# -----------------------------------------------------------------------------
# 2. 工具函数
# -----------------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "本脚本需要 root 权限运行 (当前用户: $(id -un))"
        exit 1
    fi
}

# 转换字节为可读单位
human_size() {
    local bytes="$1"
    if [[ -z "$bytes" || ! "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0B"; return
    fi
    awk -v b="$bytes" 'BEGIN{
        u[0]="B"; u[1]="K"; u[2]="M"; u[3]="G"; u[4]="T";
        s=0; while(b>=1024 && s<4){b/=1024; s++}
        printf("%.1f%s", b, u[s])
    }'
}

# 获取目录占用 (字节)
# 优先 du -sb (GNU), 退化到 du -sk (POSIX, 单位 KB) — BusyBox/精简系统兼容
dir_size_bytes() {
    local d="$1"
    [[ -d "$d" ]] || { echo 0; return; }
    if du -sb /dev/null >/dev/null 2>&1; then
        du -sb "$d" 2>/dev/null | awk '{print $1+0}'
    else
        # POSIX: -sk 输出 KB, 转换为字节
        du -sk "$d" 2>/dev/null | awk '{print ($1+0)*1024}'
    fi
}

# 获取磁盘剩余空间 (KB)
disk_avail_kb() {
    df -P "$TARGET_DISK" 2>/dev/null | awk 'NR==2{print $4+0}'
}

disk_used_pct() {
    df -P "$TARGET_DISK" 2>/dev/null | awk 'NR==2{print $5}'
}

# 判断命令是否存在
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 判断服务是否存在 (systemd)
has_service() {
    [[ "$SVC_MGR" == "systemd" ]] || return 1
    systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$1.service"
}

is_service_active() {
    [[ "$SVC_MGR" == "systemd" ]] || return 1
    systemctl is-active --quiet "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# 3. 操作系统识别
# -----------------------------------------------------------------------------
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "未找到 /etc/os-release, 无法识别系统"
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"

    # 处理 ID_LIKE / 特殊发行版
    case "$OS_ID" in
        centos|rhel|rocky|almalinux|ol)
            OS_FAMILY="rhel"
            ;;
        kylin|Kylin)
            OS_FAMILY="rhel"
            OS_ID="kylin"
            ;;
        euleros|EulerOS)
            OS_FAMILY="rhel"
            OS_ID="euleros"
            ;;
        openEuler|openeuler)
            OS_FAMILY="rhel"
            OS_ID="openeuler"
            ;;
        anolis)
            OS_FAMILY="rhel"
            ;;
        uos|UnionTech)
            # UOS 基于 Debian/Deepin
            OS_FAMILY="debian"
            OS_ID="uos"
            ;;
        ubuntu)
            OS_FAMILY="debian"
            ;;
        debian|deepin)
            OS_FAMILY="debian"
            ;;
        *)
            # 退化判断: ID_LIKE
            case "${ID_LIKE:-}" in
                *rhel*|*centos*|*fedora*) OS_FAMILY="rhel" ;;
                *debian*|*ubuntu*)        OS_FAMILY="debian" ;;
                *)
                    warn "未知系统 ID=$OS_ID, 尝试通过命令探测包管理器"
                    if   has_cmd dnf;     then OS_FAMILY="rhel"
                    elif has_cmd yum;     then OS_FAMILY="rhel"
                    elif has_cmd apt-get; then OS_FAMILY="debian"
                    else
                        err "无法确定系统家族, 退出"
                        return 1
                    fi
                    ;;
            esac
            ;;
    esac

    # 选择包管理器 (优先 dnf > yum)
    if   has_cmd dnf;     then PKG_MGR="dnf"
    elif has_cmd yum;     then PKG_MGR="yum"
    elif has_cmd apt-get; then PKG_MGR="apt"
    else
        warn "未检测到 yum/dnf/apt, 包管理相关清理将被跳过"
        PKG_MGR="none"
    fi

    # 服务管理器
    if has_cmd systemctl && [[ -d /run/systemd/system ]]; then
        SVC_MGR="systemd"
    else
        SVC_MGR="sysv"
    fi

    info "系统识别: ID=${OS_ID}  版本=${OS_VERSION}  家族=${OS_FAMILY}  包管理=${PKG_MGR}  服务=${SVC_MGR}"
    return 0
}

# -----------------------------------------------------------------------------
# 4. 清理模块
# -----------------------------------------------------------------------------

# 4.1 包管理器缓存
clean_pkg_cache() {
    info "[模块] 清理包管理器缓存"
    local before after freed
    case "$PKG_MGR" in
        dnf)
            before=$(dir_size_bytes /var/cache/dnf)
            run_argv dnf clean all >/dev/null 2>&1 || true
            # 物理删除残留 (clean all 偶尔不彻底)
            if [[ -d /var/cache/dnf ]]; then
                run_argv find /var/cache/dnf -mindepth 1 -delete 2>/dev/null || true
            fi
            after=$(dir_size_bytes /var/cache/dnf)
            ;;
        yum)
            before=$(dir_size_bytes /var/cache/yum)
            run_argv yum clean all >/dev/null 2>&1 || true
            if [[ -d /var/cache/yum ]]; then
                run_argv find /var/cache/yum -mindepth 1 -delete 2>/dev/null || true
            fi
            after=$(dir_size_bytes /var/cache/yum)
            ;;
        apt)
            before=$(( $(dir_size_bytes /var/cache/apt) + $(dir_size_bytes /var/lib/apt/lists) ))
            # 注意: apt-get clean / autoclean 不接受 -y 参数
            run_argv apt-get clean >/dev/null 2>&1 || true
            run_argv apt-get autoclean >/dev/null 2>&1 || true
            # 仅删 partial (未完整下载的包), 保留 lists 索引
            run_argv find /var/lib/apt/lists/partial -type f -delete 2>/dev/null || true
            after=$(( $(dir_size_bytes /var/cache/apt) + $(dir_size_bytes /var/lib/apt/lists) ))
            ;;
        none)
            warn "无包管理器, 跳过"
            return 0
            ;;
    esac
    freed=$(( before - after ))
    [[ $freed -lt 0 ]] && freed=0
    ok "包缓存清理完成, 释放 $(human_size "$freed")"
}

# 4.2 孤立包 / 未使用依赖
clean_orphan_packages() {
    info "[模块] 清理孤立/未使用依赖包"
    case "$PKG_MGR" in
        dnf)
            run_argv dnf autoremove -y >/dev/null 2>&1 || true
            ;;
        yum)
            if has_cmd package-cleanup; then
                # 此处必须用 shell 解析模式 (含管道)
                run "package-cleanup --leaves --quiet 2>/dev/null | xargs -r yum -y remove >/dev/null 2>&1 || true"
            else
                warn "未安装 yum-utils, 跳过孤立包清理 (可执行: yum install yum-utils)"
            fi
            ;;
        apt)
            run_argv apt-get autoremove -y --purge >/dev/null 2>&1 || true
            ;;
        *) warn "未知包管理器, 跳过" ;;
    esac
    ok "孤立包清理完成"
}

# 4.3 systemd journal 日志
clean_journal() {
    info "[模块] 清理 systemd journal (保留 ${JOURNAL_KEEP}, 时间 30 天内)"
    if ! has_cmd journalctl; then
        warn "journalctl 不存在, 跳过"
        return 0
    fi
    local before after freed
    before=$(dir_size_bytes /var/log/journal)
    run_argv journalctl --vacuum-size="${JOURNAL_KEEP}" >/dev/null 2>&1 || true
    run_argv journalctl --vacuum-time=30d >/dev/null 2>&1 || true
    after=$(dir_size_bytes /var/log/journal)
    freed=$(( before - after ))
    [[ $freed -lt 0 ]] && freed=0
    ok "journal 清理完成, 释放 $(human_size "$freed")"
}

# 4.4 普通日志 (/var/log/*.log /var/log/*-YYYYMMDD)
clean_var_log() {
    info "[模块] 清理 /var/log 旧日志 (>${LOG_KEEP_DAYS}天 或 .gz/.[0-9]) "
    local before after freed
    before=$(dir_size_bytes /var/log)

    # 删除被压缩/轮转的旧日志:  *.gz *.xz *.bz2 *.old *.1 *.2 ...
    # 用 run_argv 避免 bash -c 中反斜杠转义层级问题
    run_argv find /var/log -type f \
        \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.old' \
           -o -name '*.[0-9]' -o -name '*.[0-9][0-9]' \
           -o -name '*.[0-9].gz' -o -name '*.[0-9].xz' \) \
        -mtime +"${LOG_KEEP_DAYS}" -delete 2>/dev/null || true

    # 截断当前活动日志 > 100M (仅常见服务)
    # 用 -print0/while-read 处理含空格路径
    local big_log_list
    big_log_list="$(mktemp)"
    find /var/log -maxdepth 3 -type f \
        \( -name '*.log' -o -name 'messages' -o -name 'secure' \
           -o -name 'maillog' -o -name 'cron' -o -name 'dmesg' \) \
        -size +100M -print0 2>/dev/null >"$big_log_list" || true

    if [[ -s "$big_log_list" ]]; then
        warn "以下日志 >100M, 将被截断 (truncate, 保留文件):"
        # 安全打印 (NUL 分隔 → 换行展示)
        tr '\0' '\n' <"$big_log_list" | while IFS= read -r f; do
            [[ -n "$f" ]] && printf '  - %s (%s)\n' "$f" "$(du -h "$f" 2>/dev/null | awk '{print $1}')"
        done
        if confirm "确认截断这些大日志?"; then
            while IFS= read -r -d '' f; do
                [[ -n "$f" && -f "$f" ]] && run_argv truncate -s 0 "$f"
            done <"$big_log_list"
        fi
    fi
    rm -f "$big_log_list"

    after=$(dir_size_bytes /var/log)
    freed=$(( before - after ))
    [[ $freed -lt 0 ]] && freed=0
    ok "/var/log 清理完成, 释放 $(human_size "$freed")"
}

# 4.5 /tmp 与 /var/tmp
clean_tmp() {
    info "[模块] 清理 /tmp (>${TMP_KEEP_DAYS}天) 与 /var/tmp (>${VARTMP_KEEP_DAYS}天)"
    local before after freed
    before=$(( $(dir_size_bytes /tmp) + $(dir_size_bytes /var/tmp) ))

    # 不删除根目录本身, 不删除 .X11-unix / systemd-private-* 等系统目录
    if [[ -d /tmp ]]; then
        run_argv find /tmp -mindepth 1 -maxdepth 1 \
            ! -name '.X*-lock' ! -name '.X11-unix' ! -name '.ICE-unix' \
            ! -name '.font-unix' ! -name '.Test-unix' \
            ! -name 'systemd-private-*' ! -name 'snap-private-tmp' \
            ! -name 'tmp-mount.*' ! -name '.dc_*' \
            -mtime +"${TMP_KEEP_DAYS}" -exec rm -rf {} + 2>/dev/null || true
    fi
    if [[ -d /var/tmp ]]; then
        run_argv find /var/tmp -mindepth 1 -maxdepth 1 \
            ! -name 'systemd-private-*' \
            -mtime +"${VARTMP_KEEP_DAYS}" -exec rm -rf {} + 2>/dev/null || true
    fi

    after=$(( $(dir_size_bytes /tmp) + $(dir_size_bytes /var/tmp) ))
    freed=$(( before - after ))
    [[ $freed -lt 0 ]] && freed=0
    ok "tmp 清理完成, 释放 $(human_size "$freed")"
}

# 4.6 core dump 文件
clean_coredump() {
    info "[模块] 清理 coredump 文件 (>7天)"
    local before=0 after=0 before2=0 after2=0 freed
    # systemd-coredump
    if [[ -d /var/lib/systemd/coredump ]]; then
        before=$(dir_size_bytes /var/lib/systemd/coredump)
        run_argv find /var/lib/systemd/coredump -type f -mtime +7 -delete 2>/dev/null || true
        after=$(dir_size_bytes /var/lib/systemd/coredump)
    fi
    # /var/crash (Ubuntu/Debian apport)
    if [[ -d /var/crash ]]; then
        before2=$(dir_size_bytes /var/crash)
        run_argv find /var/crash -type f -mtime +7 -delete 2>/dev/null || true
        after2=$(dir_size_bytes /var/crash)
    fi
    # 散落在根目录/家目录的 core.* (-xdev 仅本文件系统, 限制深度4防误删)
    run_argv find / -maxdepth 4 -xdev -type f -name 'core.[0-9]*' \
        -mtime +7 -size +1M -delete 2>/dev/null || true

    freed=$(( (before - after) + (before2 - after2) ))
    [[ $freed -lt 0 ]] && freed=0
    ok "coredump 清理完成, 释放 $(human_size "$freed")"
}

# 4.7 用户级缓存 (~/.cache, thumbnails, pip, npm, composer, maven 等)
clean_user_cache() {
    info "[模块] 清理用户级缓存 (~/.cache 等, >30天未访问)"
    local uname_ uid_ home_ before=0 after=0 freed=0
    # 收集所有交互用户家目录 (含 root)
    while IFS=: read -r uname_ _ uid_ _ _ home_ _; do
        # 跳过系统用户 (uid<1000) 但保留 root (uid=0); nobody 通常 65534
        if [[ "$uid_" -eq 0 ]] || { [[ "$uid_" -ge 1000 ]] && [[ "$uid_" -lt 65534 ]]; }; then
            [[ -d "$home_" ]] || continue
            # ~/.cache
            if [[ -d "$home_/.cache" ]]; then
                before=$(( before + $(dir_size_bytes "$home_/.cache") ))
                # 用 run_argv 避免路径含空格/特殊字符
                run_argv find "$home_/.cache" -mindepth 1 -atime +30 -delete 2>/dev/null || true
                after=$(( after + $(dir_size_bytes "$home_/.cache") ))
            fi
            # 缩略图
            if [[ -d "$home_/.thumbnails" ]]; then
                run_argv find "$home_/.thumbnails" -mindepth 1 -delete 2>/dev/null || true
            fi
            # npm 缓存 (>30天未访问)
            if [[ -d "$home_/.npm/_cacache" ]]; then
                run_argv find "$home_/.npm/_cacache" -type f -atime +30 -delete 2>/dev/null || true
            fi
            # composer/maven/gradle 缓存 (仅清旧)
            for c in "$home_/.composer/cache" "$home_/.m2/repository/.cache" "$home_/.gradle/caches"; do
                [[ -d "$c" ]] && run_argv find "$c" -type f -atime +60 -delete 2>/dev/null || true
            done
            info "  - ${uname_} (${home_}) 处理完成"
        fi
    done < <(getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null)

    freed=$(( before - after ))
    [[ $freed -lt 0 ]] && freed=0
    ok "用户缓存清理完成, 释放 $(human_size "$freed")"
}

# 4.8 snap 旧版本 (Ubuntu/UOS)
clean_snap() {
    if ! has_cmd snap; then
        return 0
    fi
    info "[模块] 清理 snap 旧版本 (保留每个 snap 最新2个修订)"
    # 设置保留数 (失败不阻塞)
    run_argv snap set system refresh.retain=2 >/dev/null 2>&1 || true
    # 列出 disabled (已被新版替换的) 旧版本并删除
    if [[ $DRY_RUN -eq 1 ]]; then
        snap list --all 2>/dev/null | awk '/disabled/{print "DRY-RUN: snap remove "$1" --revision="$3}'
    else
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | \
            while read -r snapname rev; do
                [[ -n "$snapname" && -n "$rev" ]] || continue
                if snap remove "$snapname" --revision="$rev" >/dev/null 2>&1; then
                    info "已删除 snap ${snapname} (rev ${rev})"
                fi
            done
    fi
    ok "snap 清理完成"
}

# 4.9 Docker —— 中危: 容器/网络/构建缓存/dangling镜像
clean_docker_safe() {
    if ! has_cmd docker; then
        return 0
    fi
    if ! is_service_active docker 2>/dev/null && ! docker info >/dev/null 2>&1; then
        warn "Docker 未运行, 跳过"
        return 0
    fi
    info "[模块] Docker 安全清理 (停止容器/未使用网络/构建缓存/dangling镜像)"
    # 1. 已停止容器
    run_argv docker container prune -f >/dev/null 2>&1 || true
    # 2. 未使用网络
    run_argv docker network prune -f >/dev/null 2>&1 || true
    # 3. 未使用 volume (谨慎! volume 含数据, 需确认)
    if confirm "是否清理未挂载的 Docker volume? (含数据, 不可恢复)"; then
        run_argv docker volume prune -f >/dev/null 2>&1 || true
    fi
    # 4. 构建缓存 (BuildKit)
    run_argv docker builder prune -f >/dev/null 2>&1 || true
    # 5. dangling 镜像 (无 tag 的悬空镜像, 通常安全)
    run_argv docker image prune -f >/dev/null 2>&1 || true
    # 6. 容器日志截断 (json-file)
    if confirm "是否截断所有容器日志 (json-file driver)?"; then
        local container_ids cid logpath
        container_ids="$(docker ps -aq 2>/dev/null || true)"
        if [[ -n "$container_ids" ]]; then
            while IFS= read -r cid; do
                [[ -z "$cid" ]] && continue
                logpath="$(docker inspect --format='{{.LogPath}}' "$cid" 2>/dev/null || true)"
                if [[ -n "$logpath" && -f "$logpath" ]]; then
                    run_argv truncate -s 0 "$logpath"
                fi
            done <<<"$container_ids"
        fi
    fi
    ok "Docker 安全清理完成"
}

# 4.10 Docker —— 高危: 删除全部未使用镜像 (需 --include-docker-images)
clean_docker_images_all() {
    if [[ $INCLUDE_DOCKER_IMAGES -ne 1 ]]; then
        return 0
    fi
    if ! has_cmd docker; then
        return 0
    fi
    warn "[高危模块] 删除所有未被容器引用的 Docker 镜像"
    if ! confirm "确认删除全部未使用镜像? 重新拉取需要时间和网络!"; then
        info "用户取消"
        return 0
    fi
    run_argv docker image prune -a -f >/dev/null 2>&1 || true
    # docker system prune -a 一并清理 (不含 volume — volume 由上面交互式处理)
    run_argv docker system prune -a -f >/dev/null 2>&1 || true
    ok "Docker 全镜像清理完成"
}

# 4.11 podman (RHEL 系替代)
clean_podman() {
    if ! has_cmd podman; then
        return 0
    fi
    info "[模块] Podman 清理 (容器/构建缓存/dangling)"
    run_argv podman container prune -f >/dev/null 2>&1 || true
    run_argv podman network prune -f >/dev/null 2>&1 || true
    run_argv podman image prune -f >/dev/null 2>&1 || true
    if [[ $INCLUDE_DOCKER_IMAGES -eq 1 ]]; then
        if confirm "确认删除所有未使用的 Podman 镜像?"; then
            run_argv podman image prune -a -f >/dev/null 2>&1 || true
        fi
    fi
    ok "Podman 清理完成"
}

# 4.12 containerd (k8s/CRI)
clean_containerd() {
    if ! has_cmd crictl; then
        return 0
    fi
    info "[模块] containerd/crictl 清理"
    run_argv crictl rmi --prune >/dev/null 2>&1 || true
    ok "containerd 清理完成"
}

# 4.13 高危: 旧内核 (--include-old-kernels)
clean_old_kernels() {
    if [[ $INCLUDE_OLD_KERNELS -ne 1 ]]; then
        return 0
    fi
    warn "[高危模块] 删除旧内核 (保留当前运行内核 + 1 个备用)"
    local current
    current="$(uname -r)"
    info "当前运行内核: $current"

    case "$OS_FAMILY" in
        rhel)
            if has_cmd package-cleanup; then
                if confirm "确认删除多余内核 (保留最新 2 个)?"; then
                    run_argv package-cleanup --oldkernels --count=2 -y >/dev/null 2>&1 || true
                fi
            elif [[ "$PKG_MGR" == "dnf" ]]; then
                if confirm "确认 dnf remove 旧内核 (保留 2 个)?"; then
                    run_argv dnf remove --oldinstallonly --setopt installonly_limit=2 kernel -y >/dev/null 2>&1 || true
                fi
            else
                warn "未安装 yum-utils/package-cleanup, 跳过"
            fi
            ;;
        debian)
            # 提取当前内核的版本主串 (如 5.15.0-91-generic → 5.15.0-91)
            local cur_ver
            cur_ver="$(echo "$current" | sed -E 's/-(generic|server|aws|azure|gcp|kvm|lowlatency|cloud)$//')"
            # 列出所有 linux-image/headers/modules 包, 排除当前版本
            local -a old_pkgs=()
            while IFS= read -r pkg; do
                [[ -z "$pkg" ]] && continue
                old_pkgs+=("$pkg")
            done < <(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-(image|headers|modules)-[0-9]/{print $2}' | grep -F -v "$cur_ver" || true)

            if [[ ${#old_pkgs[@]} -eq 0 ]]; then
                info "无旧内核可清理 (当前: $current)"
            else
                warn "将删除以下旧内核包:"
                printf '  - %s\n' "${old_pkgs[@]}"
                if confirm "确认删除?"; then
                    # 用 run_argv 数组方式安全传参
                    run_argv apt-get -y purge "${old_pkgs[@]}" >/dev/null 2>&1 || warn "apt purge 部分失败"
                    run_argv apt-get -y autoremove --purge >/dev/null 2>&1 || true
                fi
            fi
            ;;
    esac
    ok "旧内核清理完成"
}

# 4.14 用户家目录大文件扫描 (--include-home-large)
scan_home_large_files() {
    if [[ $INCLUDE_HOME_LARGE -ne 1 ]]; then
        return 0
    fi
    info "[扫描] 家目录中 >100M 的大文件 (仅列出, 不删除)"
    find /home /root -xdev -type f -size +100M 2>/dev/null | \
        xargs -r du -h 2>/dev/null | sort -rh | head -n 30 | \
        awk '{printf "  %-10s %s\n", $1, $2}'
    ok "扫描完成 (请人工评估是否删除)"
}

# 4.15 应用日志: nginx/apache/mysql 等慢日志
clean_app_logs() {
    info "[模块] 清理常见应用旧日志 (nginx/httpd/mysql 等, >${LOG_KEEP_DAYS}天)"
    # 第二项含 * 的路径靠 nullglob 在 for 中安全展开
    local patterns=(
        /var/log/nginx
        /var/log/httpd
        /var/log/apache2
        /var/log/mysql
        /var/log/mariadb
        /var/log/redis
        /var/log/php-fpm
        /var/log/php*-fpm
        /var/log/tomcat*
        /var/log/zabbix
        /var/log/supervisor
    )
    local before=0 after=0 freed d
    for d in "${patterns[@]}"; do
        # 通配展开: 若不存在 (nullglob), $d 仍是字面字符串, 用 -d 测试过滤
        for actual in $d; do
            [[ -d "$actual" ]] || continue
            before=$(( before + $(dir_size_bytes "$actual") ))
            run_argv find "$actual" -type f \
                \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' \
                   -o -name '*.[0-9]' -o -name '*.[0-9][0-9]' \
                   -o -name '*.[0-9].gz' -o -name '*.old' \) \
                -mtime +"${LOG_KEEP_DAYS}" -delete 2>/dev/null || true
            after=$(( after + $(dir_size_bytes "$actual") ))
        done
    done
    freed=$(( before - after ))
    [[ $freed -lt 0 ]] && freed=0
    ok "应用日志清理完成, 释放 $(human_size "$freed")"
}

# -----------------------------------------------------------------------------
# 5. 顶层任务编排
# -----------------------------------------------------------------------------
do_all() {
    info "===== 执行 --all (默认跳过高危: Docker全镜像/旧内核/家目录扫描) ====="
    clean_pkg_cache
    clean_orphan_packages
    clean_journal
    clean_var_log
    clean_app_logs
    clean_tmp
    clean_coredump
    clean_user_cache
    clean_snap
    clean_docker_safe
    clean_podman
    clean_containerd
    # 高危项: 仅在显式开启时执行
    clean_docker_images_all
    clean_old_kernels
    scan_home_large_files
    info "===== --all 执行完毕 ====="
}

# -----------------------------------------------------------------------------
# 6. 容量对比
# -----------------------------------------------------------------------------
show_disk_usage() {
    local label="$1"
    local pct avail
    pct="$(disk_used_pct)"
    avail="$(disk_avail_kb)"
    info "${label} 磁盘 [$TARGET_DISK] 使用率: ${pct:-?}  剩余: $(human_size $((${avail:-0} * 1024)))"
}

# -----------------------------------------------------------------------------
# 7. 交互菜单
# -----------------------------------------------------------------------------
show_menu() {
    cat <<EOF

${C_CYA}====================== 磁盘清理菜单 ======================${C_RST}
  ${C_GRN}-- 安全清理 --${C_RST}
   1) 包管理器缓存 (yum/dnf/apt cache)
   2) 孤立包/未使用依赖
   3) systemd journal 日志
   4) /var/log 旧日志 (轮转/压缩)
   5) 应用日志 (nginx/httpd/mysql 等)
   6) /tmp 与 /var/tmp
   7) coredump (/var/lib/systemd/coredump, /var/crash)
   8) 用户缓存 (~/.cache, npm, pip 等)
   9) snap 旧版本 (若已安装)

  ${C_YLW}-- 容器中危清理 --${C_RST}
  10) Docker 安全清理 (容器/网络/dangling/构建缓存)
  11) Podman 清理
  12) containerd/crictl 清理

  ${C_RED}-- 高危清理 (需明确意图) --${C_RST}
  13) Docker 全部未使用镜像 (含已tag但未运行)
  14) 旧内核 (保留当前+1)
  15) 扫描家目录 >100M 大文件 (仅列出)

  ${C_BLU}-- 一键 --${C_RST}
  99) 一键清理 (执行 1-12, 跳过 13-15)
   0) 退出
${C_CYA}=========================================================${C_RST}
EOF
    local choice
    read -r -p "请选择 [0-15/99]: " choice </dev/tty || return 1
    show_disk_usage "[执行前]"
    case "$choice" in
        1)  clean_pkg_cache ;;
        2)  clean_orphan_packages ;;
        3)  clean_journal ;;
        4)  clean_var_log ;;
        5)  clean_app_logs ;;
        6)  clean_tmp ;;
        7)  clean_coredump ;;
        8)  clean_user_cache ;;
        9)  clean_snap ;;
        10) clean_docker_safe ;;
        11) clean_podman ;;
        12) clean_containerd ;;
        13) INCLUDE_DOCKER_IMAGES=1; clean_docker_images_all ;;
        14) INCLUDE_OLD_KERNELS=1;   clean_old_kernels ;;
        15) INCLUDE_HOME_LARGE=1;    scan_home_large_files ;;
        99) do_all ;;
        0)  info "退出"; return 99 ;;     # 99 用于通知调用者跳出循环
        *)  warn "无效选择: $choice" ;;
    esac
    show_disk_usage "[执行后]"
}

# -----------------------------------------------------------------------------
# 8. 帮助信息
# -----------------------------------------------------------------------------
show_help() {
    cat <<EOF
${C_CYA}通用 Linux 磁盘清理工具 v${SCRIPT_VERSION}${C_RST}

${C_GRN}用法:${C_RST}
  $SCRIPT_NAME [选项] [命令]

${C_GRN}命令 (单项执行):${C_RST}
  pkg          清理包管理器缓存 (yum/dnf/apt)
  orphan       清理孤立包/未使用依赖
  journal      清理 systemd journal
  varlog       清理 /var/log 旧日志
  applog       清理 nginx/httpd/mysql 等应用日志
  tmp          清理 /tmp 与 /var/tmp
  coredump     清理 coredump 文件
  usercache    清理用户缓存 (~/.cache 等)
  snap         清理 snap 旧版本
  docker       Docker 安全清理 (容器/网络/dangling)
  podman       Podman 清理
  containerd   containerd/crictl 清理
  kernel       清理旧内核 (高危, 需 --include-old-kernels)
  dockerimg    清理全部未使用 Docker 镜像 (高危, 需 --include-docker-images)
  scanhome     扫描家目录大文件 (需 --include-home-large)
  all          一键清理 (默认跳过高危项)
  menu         显示交互菜单 (默认行为)

${C_GRN}选项:${C_RST}
  --all                       同 'all' 命令
  --dry-run                   试运行, 仅显示将要执行的命令, 不实际删除
  --yes, -y                   跳过所有确认提示
  --include-docker-images     ${C_YLW}允许${C_RST}清理全部未使用的 Docker 镜像 (高危)
  --include-old-kernels       ${C_YLW}允许${C_RST}清理旧内核 (高危)
  --include-home-large        允许扫描 /home /root 大文件
  --journal-keep <SIZE>       journal 保留量, 默认 200M (如 500M / 1G)
  --log-days <N>              /var/log 旧日志保留天数, 默认 30
  --tmp-days <N>              /tmp 文件保留天数, 默认 7
  --vartmp-days <N>           /var/tmp 文件保留天数, 默认 30
  --target-disk <PATH>        容量对比的挂载点, 默认 /
  -h, --help                  显示本帮助
  -v, --version               显示版本

${C_GRN}示例:${C_RST}
  # 试运行查看将清理什么 (强烈推荐首次使用)
  sudo bash $SCRIPT_NAME --all --dry-run

  # 安全一键清理 (跳过 Docker 镜像/旧内核)
  sudo bash $SCRIPT_NAME --all --yes

  # 一键清理 + Docker 全镜像清理
  sudo bash $SCRIPT_NAME --all --include-docker-images --yes

  # 一键清理 + 旧内核 + Docker 镜像
  sudo bash $SCRIPT_NAME --all --include-docker-images --include-old-kernels

  # 仅清理 journal, 保留 500M
  sudo bash $SCRIPT_NAME --journal-keep 500M journal

  # 交互菜单
  sudo bash $SCRIPT_NAME

${C_YLW}日志文件:${C_RST} $LOG_FILE
${C_YLW}支持系统:${C_RST} CentOS 7/8/9, Ubuntu 18-24, Debian, Kylin, EulerOS, Anolis, UOS

${C_RED}安全提示:${C_RST}
  * --all 默认 ${C_GRN}不会${C_RST}删除可用 Docker 镜像、不会删除任何内核
  * 高危操作必须显式通过 --include-* 开关启用, 且仍会二次确认 (除非 -y)
  * 首次使用建议先 --dry-run 查看效果
EOF
}

# -----------------------------------------------------------------------------
# 9. 参数解析
# -----------------------------------------------------------------------------
COMMAND=""
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)                       COMMAND="all" ;;
            --dry-run)                   DRY_RUN=1 ;;
            --yes|-y)                    ASSUME_YES=1 ;;
            --include-docker-images)     INCLUDE_DOCKER_IMAGES=1 ;;
            --include-old-kernels)       INCLUDE_OLD_KERNELS=1 ;;
            --include-home-large)        INCLUDE_HOME_LARGE=1 ;;
            --journal-keep)              JOURNAL_KEEP="$2"; shift ;;
            --log-days)                  LOG_KEEP_DAYS="$2"; shift ;;
            --tmp-days)                  TMP_KEEP_DAYS="$2"; shift ;;
            --vartmp-days)               VARTMP_KEEP_DAYS="$2"; shift ;;
            --target-disk)               TARGET_DISK="$2"; shift ;;
            -h|--help)                   show_help; exit 0 ;;
            -v|--version)                echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
            pkg|orphan|journal|varlog|applog|tmp|coredump|usercache|snap|\
            docker|podman|containerd|kernel|dockerimg|scanhome|all|menu)
                COMMAND="$1"
                ;;
            *)
                err "未知参数: $1 (使用 --help 查看帮助)"
                exit 2
                ;;
        esac
        shift
    done
}

dispatch() {
    case "${COMMAND:-menu}" in
        pkg)        clean_pkg_cache ;;
        orphan)     clean_orphan_packages ;;
        journal)    clean_journal ;;
        varlog)     clean_var_log ;;
        applog)     clean_app_logs ;;
        tmp)        clean_tmp ;;
        coredump)   clean_coredump ;;
        usercache)  clean_user_cache ;;
        snap)       clean_snap ;;
        docker)     clean_docker_safe ;;
        podman)     clean_podman ;;
        containerd) clean_containerd ;;
        kernel)     INCLUDE_OLD_KERNELS=1;   clean_old_kernels ;;
        dockerimg)  INCLUDE_DOCKER_IMAGES=1; clean_docker_images_all ;;
        scanhome)   INCLUDE_HOME_LARGE=1;    scan_home_large_files ;;
        all)        do_all ;;
        menu)
            # 菜单模式: show_menu 返回 99 时退出循环
            while true; do
                show_menu
                local rc=$?
                [[ $rc -eq 99 ]] && break
            done
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 10. 主流程
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    print_banner

    # dry-run 不强制 root, 其他模式必须 root
    if [[ $DRY_RUN -ne 1 ]]; then
        require_root
    fi

    # 初始化日志文件 (仅 root 可读写)
    LOG_FILE_WRITABLE=""
    if [[ ! -f "$LOG_FILE" ]]; then
        # 尝试创建; 失败 (非 root) 时安静放弃, 仅打印到屏幕
        if touch "$LOG_FILE" 2>/dev/null; then
            chmod 600 "$LOG_FILE" 2>/dev/null || true
            LOG_FILE_WRITABLE=1
        fi
    elif [[ -w "$LOG_FILE" ]]; then
        LOG_FILE_WRITABLE=1
    fi

    info "==== 启动 $SCRIPT_NAME v$SCRIPT_VERSION ===="
    [[ $DRY_RUN -eq 1 ]] && warn "*** DRY-RUN 模式: 不会实际删除任何文件 ***"

    detect_os || exit 1

    # 菜单模式内部已自带 before/after 对比, 无需在外层重复
    if [[ "${COMMAND:-menu}" != "menu" ]]; then
        show_disk_usage "[执行前]"
        dispatch
        show_disk_usage "[执行后]"
    else
        dispatch
    fi

    info "==== 完成. 详细日志: $LOG_FILE ===="
}

main "$@"
