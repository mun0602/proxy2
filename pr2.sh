#!/bin/bash

# Script tự động cài đặt Shadowsocks với PAC file
# Phiên bản tối giản - cài đặt Shadowsocks và PAC file

# Màu sắc cho output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Vui lòng chạy script với quyền root (sudo)${NC}"
  exit 1
fi

# Hàm để tạo cổng ngẫu nhiên
get_random_port() {
  while true; do
    RANDOM_PORT=$(shuf -i 10000-65000 -n 1)
    if ! netstat -tuln | grep -q ":$RANDOM_PORT "; then
      echo $RANDOM_PORT
      return 0
    fi
  done
}

# Hàm lấy địa chỉ IP công cộng
get_public_ip() {
  PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com || curl -s https://ipinfo.io/ip)

  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi
}

# Tạo password nếu không được cung cấp
generate_password() {
  if [ -z "$SS_PASS" ]; then
    SS_PASS="pass$(openssl rand -hex 6)"
  fi
}

# Phân tích tham số dòng lệnh
while getopts "p:m:" opt; do
  case $opt in
    p) SS_PASS="$OPTARG" ;;
    m) SS_METHOD="$OPTARG" ;;
    \?) echo "Tùy chọn không hợp lệ: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Lấy cổng ngẫu nhiên cho Shadowsocks
SS_PORT=$(get_random_port)

# Sử dụng cổng 80 cho web server PAC
HTTP_PORT=80

# Phương thức mã hóa mặc định
if [ -z "$SS_METHOD" ]; then
  SS_METHOD="aes-256-gcm"
fi

# Tạo mật khẩu
generate_password

# Cài đặt các gói cần thiết
apt update -y
apt install -y python3-pip nginx curl ufw

# Cài đặt Shadowsocks
pip3 install https://github.com/shadowsocks/shadowsocks/archive/master.zip

# Dừng dịch vụ Nginx để cấu hình
systemctl stop nginx 2>/dev/null

# Tạo thư mục cấu hình Shadowsocks
mkdir -p /etc/shadowsocks

# Tạo cấu hình Shadowsocks
cat > /etc/shadowsocks/config.json << EOF
{
    "server": "0.0.0.0",
    "server_port": $SS_PORT,
    "password": "$SS_PASS",
    "timeout": 300,
    "method": "$SS_METHOD",
    "fast_open": true,
    "nameserver": "1.1.1.1",
    "mode": "tcp_and_udp"
}
EOF

# Tạo service Systemd cho Shadowsocks
cat > /etc/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Server
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Khắc phục lỗi crypto libsodium cho một số hệ thống
apt install -y libsodium-dev

# Tạo thư mục cho PAC file
mkdir -p /var/www/html

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo PAC file với cú pháp cho Shadowsocks
cat > /var/www/html/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Các tên miền truy cập trực tiếp, không qua proxy
    var directDomains = [
        "localhost",
        "127.0.0.1",
        "$PUBLIC_IP"
    ];
    
    // Kiểm tra xem tên miền có nằm trong danh sách truy cập trực tiếp không
    for (var i = 0; i < directDomains.length; i++) {
        if (dnsDomainIs(host, directDomains[i]) || 
            shExpMatch(host, directDomains[i])) {
            return "DIRECT";
        }
    }
    
    // Sử dụng Shadowsocks SOCKS5 proxy
    // Lưu ý: Password được mã hóa trong URL Shadowsocks
    return "SOCKS5 $PUBLIC_IP:$SS_PORT; SOCKS $PUBLIC_IP:$SS_PORT";
}
EOF

# Cấu hình Nginx để chỉ phục vụ PAC file
cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root /var/www/html;
    
    location / {
        return 404;
    }
    
    location = /proxy.pac {
        types { }
        default_type application/x-ns-proxy-autoconfig;
        add_header Content-Disposition 'inline; filename="proxy.pac"';
    }
}
EOF

# Cấu hình tường lửa
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow $HTTP_PORT/tcp
ufw allow $SS_PORT/tcp
ufw allow $SS_PORT/udp
ufw --force enable

# Khởi động lại các dịch vụ
systemctl daemon-reload
systemctl enable nginx
systemctl enable shadowsocks
systemctl restart shadowsocks
sleep 2
systemctl restart nginx
sleep 2

# Đảm bảo quyền truy cập cho PAC file
chmod 644 /var/www/html/proxy.pac
chown www-data:www-data /var/www/html/proxy.pac

# Tạo file QR code cho cấu hình SS (cho client di động)
apt install -y qrencode
SS_URI="ss://$(echo -n "$SS_METHOD:$SS_PASS@$PUBLIC_IP:$SS_PORT" | base64 | tr -d '\n')#SS-PAC"
qrencode -t ANSIUTF8 -o - "$SS_URI"

# In ra thông tin kết nối
echo -e "\n${GREEN}=== THÔNG TIN SHADOWSOCKS ===${NC}"
echo -e "Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "Cổng: ${GREEN}$SS_PORT${NC}"
echo -e "Mật khẩu: ${GREEN}$SS_PASS${NC}"
echo -e "Phương thức: ${GREEN}$SS_METHOD${NC}"
echo -e "\nURL PAC: ${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
echo -e "\nURI cấu hình (dùng cho Shadowsocks clients): ${GREEN}$SS_URI${NC}"
echo -e "\n${YELLOW}Lưu ý: PAC file chỉ hoạt động với client hỗ trợ SOCKS5 proxy${NC}"
echo -e "${YELLOW}Để sử dụng trên iOS/Android, hãy quét mã QR ở trên với app Shadowsocks${NC}"
