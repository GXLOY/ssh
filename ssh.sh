#!/bin/bash
# SSH安全加固脚本
# 功能：修改SSH端口 + 添加SSH公钥 + 防火墙配置 + 公网IP检测
# 支持：Ubuntu, Debian, CentOS, Rocky Linux, AlmaLinux, 阿里云, 腾讯云
# 特点：操作前备份配置、操作后连接测试、失败自动回滚、IPv4/IPv6双栈支持


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 重置颜色

# 配置文件备份路径
BACKUP_DIR="/etc/ssh_backup_$(date +%Y%m%d%H%M%S)"
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_KEY_FILE="/root/.ssh/authorized_keys"

# 状态标记
ADDED_SSH_KEY=0
DISABLE_PASSWORD=0
OS_TYPE="未知"
OS_DISTRO="未知"

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要root权限执行！${NC}" >&2
        exit 1
    fi
}

# 检测操作系统类型
detect_os() {
    echo -e "${GREEN}[信息] 正在检测操作系统...${NC}"
    
    # 检查阿里云
    if [ -f /etc/alinux-release ]; then
        OS_TYPE="阿里云"
        OS_DISTRO=$(source /etc/os-release && echo $PRETTY_NAME)
        return
    fi
    
    # 检查腾讯云
    if [ -f /etc/tencentos-release ]; then
        OS_TYPE="腾讯云"
        OS_DISTRO=$(source /etc/os-release && echo $PRETTY_NAME)
        return
    fi
    
    # 检查标准Linux发行版
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_TYPE=$ID
        OS_DISTRO=$PRETTY_NAME
        
        # 映射到通用名称
        case $ID in
            ubuntu|debian|centos|rocky|almalinux)
                # 保持标准名称
                ;;
            rhel)
                OS_TYPE="centos"
                ;;
            *)
                # 其他发行版直接使用ID
                ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        OS_DISTRO=$(cat /etc/redhat-release)
        if [[ $OS_DISTRO == *"CentOS"* ]]; then
            OS_TYPE="centos"
        elif [[ $OS_DISTRO == *"Rocky"* ]]; then
            OS_TYPE="rocky"
        elif [[ $OS_DISTRO == *"AlmaLinux"* ]]; then
            OS_TYPE="almalinux"
        fi
    fi
    
    echo -e "检测到操作系统: ${BLUE}$OS_DISTRO${NC}"
    echo -e "系统类型: ${BLUE}$OS_TYPE${NC}"
}

# 获取公网IPv4地址
get_public_ipv4() {
    echo -e "${GREEN}[信息] 正在获取公网IPv4地址...${NC}"
    
    # IPv4备用源列表（国内源优先）
    IPV4_SOURCES=(
        "https://4.ipw.cn"                 # 国内源
        "https://ip.3322.net"              # 国内源
        "https://myip.ipip.net"            # 国内源
        "https://ddns.oray.com/checkip"    # 国内源
        "https://ipinfo.io/ip"             # 国际源
        "https://ifconfig.me"              # 国际源
        "https://api.ipify.org"            # 国际源
        "https://ipv4.icanhazip.com"       # 国际源
    )
    
    # 获取IPv4地址
    IPV4_ADDR=""
    for source in "${IPV4_SOURCES[@]}"; do
        # 使用curl获取IP地址，设置超时为3秒
        response=$(curl -4 -s --connect-timeout 3 "$source" 2>/dev/null)
        
        # 尝试多种提取方式
        ip=$(echo "$response" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
        [ -z "$ip" ] && ip=$(echo "$response" | grep -Eo '当前 IP：([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
        [ -z "$ip" ] && ip=$(echo "$response" | grep -Eo '地址是：([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
        [ -z "$ip" ] && ip=$(echo "$response" | head -n1 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
        
        # 验证IP格式
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            IPV4_ADDR=$ip
            echo -e "成功获取IPv4: ${BLUE}$IPV4_ADDR${NC} (源: ${YELLOW}$source${NC})"
            return 0
        fi
    done
    
    echo -e "${YELLOW}警告：无法获取公网IPv4地址${NC}"
    return 1
}

# 获取公网IPv6地址
get_public_ipv6() {
    echo -e "${GREEN}[信息] 正在获取公网IPv6地址...${NC}"
    
    # IPv6备用源列表（国内源优先）
    IPV6_SOURCES=(
        "https://6.ipw.cn"                 # 国内源
        "https://v6.ident.me"              # 国际源
        "https://ipv6.icanhazip.com"       # 国际源
        "https://api6.ipify.org"           # 国际源
        "https://ipv6.seeip.org"           # 国际源
    )
    
    # 获取IPv6地址
    IPV6_ADDR=""
    for source in "${IPV6_SOURCES[@]}"; do
        # 使用curl获取IP地址，设置超时为3秒
        response=$(curl -6 -s --connect-timeout 3 "$source" 2>/dev/null)
        
        # 尝试多种提取方式
        ip=$(echo "$response" | grep -Eo '([a-f0-9]{1,4}:){7}[a-f0-9]{1,4}')
        [ -z "$ip" ] && ip=$(echo "$response" | head -n1 | grep -Eo '([a-f0-9]{1,4}:){7}[a-f0-9]{1,4}')
        
        # 验证IP格式
        if [[ $ip =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$ ]]; then
            IPV6_ADDR=$ip
            echo -e "成功获取IPv6: ${BLUE}$IPV6_ADDR${NC} (源: ${YELLOW}$source${NC})"
            return 0
        fi
    done
    
    echo -e "${YELLOW}警告：无法获取公网IPv6地址${NC}"
    return 1
}

# 获取公网IP地址（分离式获取）
get_public_ips() {
    get_public_ipv4
    get_public_ipv6
    
    # 显示最终结果
    if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
        echo -e "${YELLOW}警告：无法获取公网IP地址，将使用内网地址${NC}"
    fi
}

# 备份配置文件
backup_config() {
    echo -e "${GREEN}[步骤1] 正在备份SSH配置文件...${NC}"
    mkdir -p "$BACKUP_DIR"
    cp "$SSH_CONFIG" "$BACKUP_DIR/sshd_config.bak"
    echo -e "备份已保存至: ${BLUE}${BACKUP_DIR}${NC}"
}

# 获取新端口
get_new_port() {
    while true; do
        read -p "请输入新的SSH端口 (1024-65535): " NEW_PORT
        # 验证端口格式
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}错误：端口必须是数字！${NC}"
            continue
        fi
        # 验证端口范围
        if [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
            echo -e "${RED}错误：端口必须在1024-65535之间！${NC}"
            continue
        fi
        # 检查端口是否被占用
        if ss -tuln | grep -q ":${NEW_PORT} "; then
            echo -e "${RED}错误：端口 ${NEW_PORT} 已被占用！${NC}"
            continue
        fi
        # 检查是否与当前端口相同
        CURRENT_PORT=$(grep -E "^Port" "$SSH_CONFIG" | awk '{print $2}' | head -n 1)
        if [ "$CURRENT_PORT" = "$NEW_PORT" ]; then
            echo -e "${YELLOW}警告：新端口与当前端口相同，无需修改！${NC}"
        fi
        break
    done
}

# 添加SSH公钥（可选）
add_ssh_key() {
    echo -e "${GREEN}[步骤2] 添加SSH公钥（可选）...${NC}"
    echo -e "${YELLOW}提示：直接回车跳过此步骤将保留密码登录${NC}"
    read -p "是否添加SSH公钥？(y/n): " ADD_KEY
    
    if [[ "$ADD_KEY" =~ ^[Yy]$ ]]; then
        mkdir -p /root/.ssh
        touch "$SSH_KEY_FILE"
        chmod 600 "$SSH_KEY_FILE"
        ADDED_SSH_KEY=1
        DISABLE_PASSWORD=1
        
        while true; do
            read -p "请输入SSH公钥内容: " SSH_KEY
            if [ -z "$SSH_KEY" ]; then
                echo -e "${RED}错误：SSH公钥不能为空！${NC}"
                continue
            fi
            
            # 检查公钥格式
            if ! grep -q "ssh-" <<< "$SSH_KEY"; then
                echo -e "${YELLOW}警告：公钥格式可能不正确，是否继续？(y/n): ${NC}"
                read -p "" FORCE_ADD
                if [[ ! "$FORCE_ADD" =~ ^[Yy]$ ]]; then
                    continue
                fi
            fi
            
            # 检查是否已存在相同公钥
            if grep -Fxq "$SSH_KEY" "$SSH_KEY_FILE"; then
                echo -e "${YELLOW}该公钥已存在，无需重复添加。${NC}"
            else
                echo "$SSH_KEY" >> "$SSH_KEY_FILE"
                echo -e "${GREEN}SSH公钥已成功添加！${NC}"
            fi
            break
        done
    else
        echo -e "${YELLOW}跳过SSH公钥添加，将保留密码登录。${NC}"
        ADDED_SSH_KEY=0
    fi
}

# 配置防火墙
configure_firewall() {
    echo -e "${GREEN}[步骤3] 正在配置防火墙...${NC}"
    
    # UFW (Ubuntu/Debian)
    if command -v ufw &> /dev/null; then
        ufw allow "$NEW_PORT/tcp"
        if [ -n "$CURRENT_PORT" ] && [ "$CURRENT_PORT" != "$NEW_PORT" ]; then
            ufw delete allow "$CURRENT_PORT/tcp"
        fi
        echo -e "${GREEN}UFW配置完成：已允许端口 ${BLUE}${NEW_PORT}${NC}"
    
    # Firewalld (CentOS/RHEL)
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port="$NEW_PORT/tcp"
        if [ -n "$CURRENT_PORT" ] && [ "$CURRENT_PORT" != "$NEW_PORT" ]; then
            firewall-cmd --permanent --remove-port="$CURRENT_PORT/tcp"
        fi
        firewall-cmd --reload
        echo -e "${GREEN}Firewalld配置完成：已允许端口 ${BLUE}${NEW_PORT}${NC}"
    
    # 阿里云
    elif [ "$OS_TYPE" = "阿里云" ]; then
        echo -e "${YELLOW}阿里云：请在控制台添加安全组规则放行端口 ${NEW_PORT}${NC}"
    
    # 腾讯云
    elif [ "$OS_TYPE" = "腾讯云" ]; then
        echo -e "${YELLOW}腾讯云：请在控制台添加安全组规则放行端口 ${NEW_PORT}${NC}"
    
    # 未检测到防火墙
    else
        echo -e "${YELLOW}警告：未检测到UFW或Firewalld，请手动配置防火墙！${NC}"
    fi
    
    # 云服务安全组配置指南（英文）
    if [ "$OS_TYPE" = "阿里云" ]; then
        echo -e "${YELLOW}阿里云安全组配置指南：${NC}"
        echo "1. Log in to Alibaba Cloud Console"
        echo "2. Go to Elastic Compute Service (ECS)"
        echo "3. Find your instance and click 'More' > 'Security Group Configuration'"
        echo "4. Add rule:"
        echo "   - Direction: Inbound"
        echo "   - Protocol: TCP"
        echo "   - Port Range: $NEW_PORT"
        echo "   - Source: 0.0.0.0/0 (or your IP range)"
        [ -n "$IPV6_ADDR" ] && echo "   - Add similar rule for IPv6"
        echo "5. Click 'Save'"
    
    elif [ "$OS_TYPE" = "腾讯云" ]; then
        echo -e "${YELLOW}腾讯云安全组配置指南：${NC}"
        echo "1. Log in to Tencent Cloud Console"
        echo "2. Go to Cloud Virtual Machine (CVM)"
        echo "3. Find your instance and click 'Security Groups'"
        echo "4. Add rule:"
        echo "   - Type: Custom"
        echo "   - Source: 0.0.0.0/0 (or your IP range)"
        echo "   - Protocol: TCP"
        echo "   - Port: $NEW_PORT"
        echo "   - Policy: Allow"
        [ -n "$IPV6_ADDR" ] && echo "   - Add similar rule for IPv6"
        echo "5. Click 'Complete'"
    fi
}

# 修改SSH配置
modify_ssh_config() {
    echo -e "${GREEN}[步骤4] 正在修改SSH配置...${NC}"
    # 注释旧端口设置
    sed -i '/^Port /s/^/# /' "$SSH_CONFIG"
    # 添加新端口设置
    echo "Port $NEW_PORT" | tee -a "$SSH_CONFIG"
    
    # 如果添加了SSH密钥，则修改认证设置
    if [ "$ADDED_SSH_KEY" -eq 1 ]; then
        # 启用公钥认证
        sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
        # 禁用密码登录
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
        # 允许root使用SSH密钥登录
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSH_CONFIG"
        echo -e "已启用公钥认证并禁用密码登录"
    else
        # 确保密码登录可用
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG"
        echo -e "已保留密码登录"
    fi
    
    # 启用IPv6监听（如果检测到IPv6地址）
    if [ -n "$IPV6_ADDR" ]; then
        if grep -q "^#ListenAddress ::" "$SSH_CONFIG"; then
            sed -i 's/^#ListenAddress ::/ListenAddress ::/' "$SSH_CONFIG"
            echo -e "已启用IPv6监听"
        elif ! grep -q "^ListenAddress ::" "$SSH_CONFIG"; then
            echo "ListenAddress ::" >> "$SSH_CONFIG"
            echo -e "已添加IPv6监听配置"
        fi
    fi
    
    echo -e "已设置新端口: ${BLUE}${NEW_PORT}${NC}"
}

# 重启SSH服务
restart_ssh() {
    echo -e "${GREEN}[步骤5] 正在重启SSH服务...${NC}"
    if systemctl restart sshd; then
        echo -e "${GREEN}SSH服务重启成功！${NC}"
    else
        echo -e "${RED}错误：SSH服务重启失败！正在恢复备份...${NC}"
        restore_backup
        exit 1
    fi
}

# 恢复备份
restore_backup() {
    echo -e "${YELLOW}正在恢复备份配置...${NC}"
    cp -f "$BACKUP_DIR/sshd_config.bak" "$SSH_CONFIG"
    systemctl restart sshd
    echo -e "${GREEN}配置已恢复！${NC}"
}

# 测试新连接
test_connection() {
    echo -e "${GREEN}[步骤6] 正在测试新端口连接...${NC}"
    
    # 获取内网IP作为备选
    INTERNAL_IP=$(hostname -I | awk '{print $1}')
    
    # 显示可用的连接地址
    if [ -n "$IPV4_ADDR" ]; then
        echo -e "公网IPv4地址: ${BLUE}$IPV4_ADDR${NC}"
        echo -e "IPv4连接命令:"
        echo -e "${BLUE}ssh -p $NEW_PORT root@$IPV4_ADDR${NC}"
    fi
    
    if [ -n "$IPV6_ADDR" ]; then
        echo -e "公网IPv6地址: ${BLUE}$IPV6_ADDR${NC}"
        echo -e "IPv6连接命令:"
        echo -e "${BLUE}ssh -p $NEW_PORT root@[$IPV6_ADDR]${NC}"
    fi
    
    if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
        echo -e "${YELLOW}使用内网地址测试连接:${NC}"
        echo -e "内网IP地址: ${BLUE}$INTERNAL_IP${NC}"
        echo -e "连接命令: ${BLUE}ssh -p $NEW_PORT root@$INTERNAL_IP${NC}"
    fi
    
    echo
    echo -e "${YELLOW}测试提示:${NC}"
    if [ "$ADDED_SSH_KEY" -eq 1 ]; then
        echo "- 请使用SSH密钥连接服务器"
    else
        echo "- 请使用密码连接服务器"
    fi
    echo "- 保持当前会话，在新终端测试"
    
    echo
    read -p "测试成功了吗？(y/n): " TEST_RESULT
    if [[ "$TEST_RESULT" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}连接测试成功！${NC}"
    else
        echo -e "${RED}连接测试失败！正在恢复配置...${NC}"
        restore_backup
        exit 1
    fi
}

# 显示总结信息
show_summary() {
    clear
    echo -e "${GREEN}"
    echo "========================================"
    echo " SSH安全加固完成！"
    echo "========================================"
    echo -e "${NC}"
    
    # 显示操作系统信息
    echo -e "操作系统: ${BLUE}$OS_DISTRO${NC}"
    [ "$OS_TYPE" != "未知" ] && echo -e "环境类型: ${BLUE}$OS_TYPE${NC}"
    
    # 显示IP信息
    if [ -n "$IPV4_ADDR" ]; then
        echo -e "公网IPv4: ${BLUE}$IPV4_ADDR${NC}"
    fi
    if [ -n "$IPV6_ADDR" ]; then
        echo -e "公网IPv6: ${BLUE}$IPV6_ADDR${NC}"
    fi
    
    # 获取内网IP作为备选
    INTERNAL_IP=$(hostname -I | awk '{print $1}')
    if [ -n "$INTERNAL_IP" ] && { [ -z "$IPV4_ADDR" ] || [ "$INTERNAL_IP" != "$IPV4_ADDR" ]; }; then
        echo -e "内网IP: ${BLUE}$INTERNAL_IP${NC}"
    fi
    
    echo -e "SSH端口: ${BLUE}$NEW_PORT${NC}"
    
    if [ "$ADDED_SSH_KEY" -eq 1 ]; then
        echo -e "认证方式: ${BLUE}SSH公钥${NC}"
        echo -e "${YELLOW}注意：密码登录已被禁用${NC}"
    else
        echo -e "认证方式: ${BLUE}密码登录${NC}"
        echo -e "${YELLOW}注意：建议添加SSH公钥增强安全性${NC}"
    fi
    
    echo
    echo -e "${YELLOW}重要提示:${NC}"
    echo "1. 备份文件保存在: ${BACKUP_DIR}"
    
    # 云服务特定提示
    if [ "$OS_TYPE" = "阿里云" ]; then
        echo "2. 请在阿里云控制台配置安全组放行端口 ${NEW_PORT}"
    elif [ "$OS_TYPE" = "腾讯云" ]; then
        echo "2. 请在腾讯云控制台配置安全组放行端口 ${NEW_PORT}"
    else
        echo "2. 请配置防火墙放行端口 ${NEW_PORT}"
    fi
    
    # 显示连接命令
    echo
    echo -e "${YELLOW}连接命令:${NC}"
    if [ -n "$IPV4_ADDR" ]; then
        if [ "$ADDED_SSH_KEY" -eq 1 ]; then
            echo -e "IPv4: ${BLUE}ssh -p $NEW_PORT root@$IPV4_ADDR${NC}"
        else
            echo -e "IPv4: ${BLUE}ssh -p $NEW_PORT root@$IPV4_ADDR${NC} (使用密码)"
        fi
    fi
    if [ -n "$IPV6_ADDR" ]; then
        if [ "$ADDED_SSH_KEY" -eq 1 ]; then
            echo -e "IPv6: ${BLUE}ssh -p $NEW_PORT root@[$IPV6_ADDR]${NC}"
        else
            echo -e "IPv6: ${BLUE}ssh -p $NEW_PORT root@[$IPV6_ADDR]${NC} (使用密码)"
        fi
    fi
    if [ -n "$INTERNAL_IP" ]; then
        if [ "$ADDED_SSH_KEY" -eq 1 ]; then
            echo -e "内网: ${BLUE}ssh -p $NEW_PORT root@$INTERNAL_IP${NC}"
        else
            echo -e "内网: ${BLUE}ssh -p $NEW_PORT root@$INTERNAL_IP${NC} (使用密码)"
        fi
    fi
    
    echo
    echo -e "${YELLOW}安全建议:${NC}"
    echo "1. 建议禁用root登录并使用普通用户+sudo"
    if [ "$ADDED_SSH_KEY" -eq 0 ]; then
        echo "2. 强烈建议添加SSH公钥并禁用密码登录"
    else
        echo "2. 定期轮换SSH密钥"
    fi
    echo "3. 配置防火墙仅允许必要端口"
}

# 主函数
main() {
    check_root
    echo -e "${GREEN}"
    echo "========================================"
    echo " SSH安全配置脚本"
    echo "========================================"
    echo -e "${NC}"
    echo -e "${YELLOW}警告：修改SSH配置可能导致服务器无法访问！${NC}"
    echo -e "请保持当前SSH会话，在新终端测试成功后再关闭此窗口！"
    echo
    
    # 检测操作系统
    detect_os
    
    # 获取公网IP地址
    get_public_ips
    
    read -p "是否继续？(y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
    backup_config
    get_new_port
    add_ssh_key
    configure_firewall
    modify_ssh_config
    restart_ssh
    test_connection
    show_summary
}
main
