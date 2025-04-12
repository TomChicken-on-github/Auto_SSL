#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 检查依赖
check_dependencies() {
    echo -e "${BLUE}正在检查依赖项...${NC}"
    
    # 检查 curl
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}未找到 curl，正在安装...${NC}"
        apt-get update && apt-get install -y curl || yum install -y curl
    fi
    
    # 检查 whiptail
    if ! command -v whiptail &> /dev/null; then
        echo -e "${RED}未找到 whiptail，正在安装...${NC}"
        apt-get update && apt-get install -y whiptail || yum install -y newt
    fi
    
    # 检查 socat (acme.sh 可能需要)
    if ! command -v socat &> /dev/null; then
        echo -e "${RED}未找到 socat，正在安装...${NC}"
        apt-get update && apt-get install -y socat || yum install -y socat
    fi
    
    # 检查 acme.sh
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        echo -e "${YELLOW}未找到 acme.sh，正在安装...${NC}"
        curl https://get.acme.sh | sh -s email=admin@example.com
        
        # 重新加载 shell 以便找到 acme.sh
        source "$HOME/.bashrc"
        source "$HOME/.acme.sh/acme.sh.env"
    fi
    
    echo -e "${GREEN}所有依赖已满足${NC}"
}

# 绘制标题
draw_title() {
    whiptail --title "公开可信 SSL 证书自动申请工具" --msgbox "\
欢迎使用AUTO_SSL

此工具将帮助您：
1. 通过 Let's Encrypt 申请免费的 SSL 证书
2. 支持多种验证方式（DNS、HTTP）
3. 将证书和私钥保存到指定位置
4. 提供自动续期配置

作者：Tom_Chicken
版本：2.0
" 15 60
}

# 获取用户输入
get_user_input() {
    # 获取证书保存路径
    CERT_PATH=$(whiptail --inputbox "请输入证书保存路径 (默认为 /key/)" 10 60 "/key/" 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [ $exitstatus != 0 ]; then
        echo -e "${RED}用户取消了操作${NC}"
        exit 1
    fi
    
    # 如果用户未输入，使用默认值
    CERT_PATH=${CERT_PATH:-/key/}
    
    # 确保路径以 / 结尾
    [[ "${CERT_PATH}" != */ ]] && CERT_PATH="${CERT_PATH}/"
    
    # 获取域名
    DOMAIN=$(whiptail --inputbox "请输入您要申请证书的域名 (例如: example.com)" 10 60 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [ $exitstatus != 0 ]; then
        echo -e "${RED}用户取消了操作${NC}"
        exit 1
    fi
    
    # 询问是否包含 www 子域名
    INCLUDE_WWW=$(whiptail --yesno "是否同时为 www.${DOMAIN} 申请证书？" 10 60 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [ $exitstatus = 0 ]; then
        DOMAIN_PARAM="${DOMAIN} www.${DOMAIN}"
        DOMAIN_MAIN="${DOMAIN}"
    else
        DOMAIN_PARAM="${DOMAIN}"
        DOMAIN_MAIN="${DOMAIN}"
    fi
    
    # 选择验证方式
    VALIDATION_METHOD=$(whiptail --menu "请选择域名验证方式" 15 60 3 \
    "1" "Cloudflare DNS API (推荐)" \
    "2" "HTTP 文件验证" \
    "3" "手动 DNS 验证" 3>&1 1>&2 2>&3)
    
    case $VALIDATION_METHOD in
        1) 
            # 获取 Cloudflare 信息
            CF_EMAIL=$(whiptail --inputbox "请输入您的 Cloudflare 邮箱地址" 10 60 3>&1 1>&2 2>&3)
            CF_API_KEY=$(whiptail --passwordbox "请输入您的 Cloudflare 全局 API 密钥" 10 60 3>&1 1>&2 2>&3)
            
            # 确认 DNS 已经指向 Cloudflare
            whiptail --title "确认" --yesno "请确认您的域名 ${DOMAIN} 的 DNS 已经指向 Cloudflare，否则验证将失败！" 10 60
            exitstatus=$?
            if [ $exitstatus != 0 ]; then
                echo -e "${RED}用户取消了操作${NC}"
                exit 1
            fi
            ;;
        2)
            # 获取 Web 根目录
            WEB_ROOT=$(whiptail --inputbox "请输入网站根目录路径（用于验证）" 10 60 "/var/www/html" 3>&1 1>&2 2>&3)
            
            # 确认 Web 服务器已经配置正确
            whiptail --title "确认" --yesno "请确认您的 Web 服务器已正确配置，且域名 ${DOMAIN} 可以通过 HTTP 访问！" 10 60
            exitstatus=$?
            if [ $exitstatus != 0 ]; then
                echo -e "${RED}用户取消了操作${NC}"
                exit 1
            fi
            ;;
        3)
            # 通知用户将使用手动 DNS 验证
            whiptail --title "手动 DNS 验证" --msgbox "您选择了手动 DNS 验证方式。\n\n在接下来的步骤中，系统将提示您添加一条 TXT 记录到您的 DNS 配置中。\n\n请确保您有权限修改域名的 DNS 记录。" 12 60
            ;;
        *)
            echo -e "${RED}未选择验证方式，退出${NC}"
            exit 1
            ;;
    esac
    
    # 选择证书类型
    KEY_TYPE=$(whiptail --menu "请选择证书密钥类型" 12 60 2 \
    "1" "RSA (广泛兼容)" \
    "2" "ECC (更安全，体积更小)" 3>&1 1>&2 2>&3)
    
    case $KEY_TYPE in
        1) KEY_TYPE="rsa" ;;
        2) KEY_TYPE="ec-256" ;;  # 使用 P-256 曲线
        *) KEY_TYPE="rsa" ;;
    esac
    
    # 询问是否设置自动续期
    AUTO_RENEW=$(whiptail --yesno "是否设置证书自动续期？(推荐)" 10 60 3>&1 1>&2 2>&3)
    AUTO_RENEW=$?  # 0表示是，1表示否
}

# 申请证书
issue_certificate() {
    {
        echo "10" ; sleep 0.5
        echo "# 准备申请证书..." ; sleep 1
        
        # 确保目录存在
        mkdir -p "${CERT_PATH}"
        
        # 根据验证方式执行不同的命令
        case $VALIDATION_METHOD in
            1)  # Cloudflare DNS API
                echo "30" ; sleep 0.5
                echo "# 配置 Cloudflare API..." ; sleep 1
                
                # 设置 Cloudflare API 环境变量
                export CF_Email="${CF_EMAIL}"
                export CF_Key="${CF_API_KEY}"
                
                echo "50" ; sleep 0.5
                echo "# 通过 Cloudflare DNS 申请证书..." ; sleep 1
                
                if [ "$KEY_TYPE" == "rsa" ]; then
                    ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${DOMAIN_PARAM} --keylength 2048 --force
                else
                    ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${DOMAIN_PARAM} --keylength ec-256 --force
                fi
                ;;
                
            2)  # HTTP 验证
                echo "30" ; sleep 0.5
                echo "# 配置 HTTP 验证..." ; sleep 1
                
                echo "50" ; sleep 0.5
                echo "# 通过 HTTP 验证申请证书..." ; sleep 1
                
                if [ "$KEY_TYPE" == "rsa" ]; then
                    ~/.acme.sh/acme.sh --issue --webroot "${WEB_ROOT}" -d ${DOMAIN_PARAM} --keylength 2048 --force
                else
                    ~/.acme.sh/acme.sh --issue --webroot "${WEB_ROOT}" -d ${DOMAIN_PARAM} --keylength ec-256 --force
                fi
                ;;
                
            3)  # 手动 DNS 验证
                echo "30" ; sleep 0.5
                echo "# 开始手动 DNS 验证流程..." ; sleep 1
                
                # 使用 --dns 选项进行手动验证
                if [ "$KEY_TYPE" == "rsa" ]; then
                    ~/.acme.sh/acme.sh --issue --dns -d ${DOMAIN_PARAM} --keylength 2048 --yes-I-know-dns-manual-mode-enough-go-ahead-please
                else
                    ~/.acme.sh/acme.sh --issue --dns -d ${DOMAIN_PARAM} --keylength ec-256 --yes-I-know-dns-manual-mode-enough-go-ahead-please
                fi
                
                # 获取验证信息
                TXT_RECORDS=$(grep "txt value" ~/.acme.sh/${DOMAIN_MAIN}/${DOMAIN_MAIN}.txt_validation.txt 2>/dev/null || echo "无法获取 TXT 记录")
                
                # 显示 TXT 记录信息
                whiptail --title "DNS 验证" --msgbox "请在您的 DNS 控制面板中添加以下 TXT 记录：\n\n${TXT_RECORDS}\n\n添加完成后，请按确定继续。" 15 70
                
                echo "70" ; sleep 0.5
                echo "# 正在验证 DNS 记录..." ; sleep 1
                
                # 重新运行以验证
                if [ "$KEY_TYPE" == "rsa" ]; then
                    ~/.acme.sh/acme.sh --renew -d ${DOMAIN_MAIN} --keylength 2048 --yes-I-know-dns-manual-mode-enough-go-ahead-please
                else
                    ~/.acme.sh/acme.sh --renew -d ${DOMAIN_MAIN} --keylength ec-256 --yes-I-know-dns-manual-mode-enough-go-ahead-please
                fi
                ;;
        esac
        
        echo "80" ; sleep 0.5
        echo "# 安装证书到指定目录..." ; sleep 1
        
        # 安装证书到指定目录
        ~/.acme.sh/acme.sh --install-cert -d ${DOMAIN_MAIN} \
            --cert-file ${CERT_PATH}${DOMAIN_MAIN}.crt \
            --key-file ${CERT_PATH}${DOMAIN_MAIN}.key \
            --fullchain-file ${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt
        
        # 设置权限
        chmod 644 ${CERT_PATH}${DOMAIN_MAIN}.crt ${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt
        chmod 600 ${CERT_PATH}${DOMAIN_MAIN}.key
        
        # 设置自动续期
        if [ $AUTO_RENEW -eq 0 ]; then
            echo "90" ; sleep 0.5
            echo "# 配置自动续期..." ; sleep 1
            
            # 添加自动续期任务
            ~/.acme.sh/acme.sh --cron --home ~/.acme.sh/
            
            # 设置自动安装证书到指定目录的钩子
            ~/.acme.sh/acme.sh --reloadcmd "cp ~/.acme.sh/${DOMAIN_MAIN}/${DOMAIN_MAIN}.key ${CERT_PATH}${DOMAIN_MAIN}.key && cp ~/.acme.sh/${DOMAIN_MAIN}/fullchain.cer ${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt && cp ~/.acme.sh/${DOMAIN_MAIN}/${DOMAIN_MAIN}.cer ${CERT_PATH}${DOMAIN_MAIN}.crt && chmod 644 ${CERT_PATH}${DOMAIN_MAIN}.crt ${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt && chmod 600 ${CERT_PATH}${DOMAIN_MAIN}.key" -d ${DOMAIN_MAIN}
        fi
        
        echo "100" ; sleep 0.5
        echo "# 完成！" ; sleep 1
        
    } | whiptail --gauge "申请 SSL 证书中..." 10 60 0
}

# 显示结果
show_results() {
    # 检查证书是否存在
    if [ ! -f "${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt" ]; then
        whiptail --title "错误" --msgbox "证书申请失败，请检查日志。" 10 60
        exit 1
    fi
    
    # 提取证书信息
    CERT_INFO=$(openssl x509 -in "${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt" -noout -text)
    ISSUER=$(openssl x509 -in "${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt" -noout -issuer | sed 's/issuer=//g')
    VALID_FROM=$(openssl x509 -in "${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt" -noout -startdate | sed 's/notBefore=//g')
    VALID_TO=$(openssl x509 -in "${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt" -noout -enddate | sed 's/notAfter=//g')
    SUBJECT_ALT_NAMES=$(openssl x509 -in "${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt" -noout -text | grep -A1 "Subject Alternative Name" | tail -n1 | sed 's/DNS://g; s/, DNS:/,/g')
    
    # 准备 Nginx 配置示例
    NGINX_CONFIG="server {
    listen 443 ssl;
    server_name ${DOMAIN_PARAM};
    
    ssl_certificate ${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt;
    ssl_certificate_key ${CERT_PATH}${DOMAIN_MAIN}.key;
    
    # 推荐的 SSL 参数
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
    ssl_session_timeout 10m;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    
    # 开启 OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # HSTS (请谨慎启用)
    # add_header Strict-Transport-Security \"max-age=63072000; includeSubDomains; preload\";
    
    # 其他服务器配置
    # ...
}"
    
    # 准备 Apache 配置示例
    APACHE_CONFIG="<VirtualHost *:443>
    ServerName ${DOMAIN_MAIN}
    ServerAlias www.${DOMAIN_MAIN}
    
    SSLEngine on
    SSLCertificateFile ${CERT_PATH}${DOMAIN_MAIN}.crt
    SSLCertificateKeyFile ${CERT_PATH}${DOMAIN_MAIN}.key
    SSLCertificateChainFile ${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt
    
    # 其他服务器配置
    # ...
</VirtualHost>"
    
    # 显示成功信息
    whiptail --title "证书申请成功" --msgbox "\
恭喜！您的 SSL 证书已成功创建。

证书详情:
- 域名: ${SUBJECT_ALT_NAMES}
- 签发方: ${ISSUER}
- 有效期: ${VALID_FROM} 至 ${VALID_TO}
- 密钥类型: ${KEY_TYPE^^}

文件位置:
- 证书: ${CERT_PATH}${DOMAIN_MAIN}.crt
- 完整链: ${CERT_PATH}${DOMAIN_MAIN}.fullchain.crt
- 私钥: ${CERT_PATH}${DOMAIN_MAIN}.key

自动续期: $([ $AUTO_RENEW -eq 0 ] && echo "已启用" || echo "未启用")
" 20 76
    
    # 显示 Web 服务器配置示例
    if (whiptail --title "Web 服务器配置" --yesno "是否查看 Web 服务器配置示例？" 10 60); then
        # 显示配置选择菜单
        CONFIG_TYPE=$(whiptail --menu "请选择 Web 服务器类型" 12 60 2 \
        "1" "Nginx" \
        "2" "Apache" 3>&1 1>&2 2>&3)
        
        case $CONFIG_TYPE in
            1)
                whiptail --title "Nginx 配置示例" --scrolltext --msgbox "${NGINX_CONFIG}" 20 76
                ;;
            2)
                whiptail --title "Apache 配置示例" --scrolltext --msgbox "${APACHE_CONFIG}" 20 76
                ;;
        esac
    fi
}

# 主函数
main() {
    check_dependencies
    draw_title
    get_user_input
    issue_certificate
    show_results
}

# 运行主函数
main