#!/bin/bash

# Script tự động cài đặt Shadowsocks với tên tùy chọn và DNS Cloudflare
# Tạo QR code với tên do người dùng nhập

# Màu sắc cho output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
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

# Cấu hình DNS Cloudflare cho hệ thống
configure_cloudflare_dns() {
  echo -e "${BLUE}Cấu hình DNS Cloudflare cho hệ thống...${NC}"
  
  # Xác định loại hệ thống
  if [ -f /etc/systemd/resolved.conf ]; then
    # SystemD Resolved
    echo -e "${BLUE}Cấu hình DNS qua systemd-resolved...${NC}"
    cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak
    cat > /etc/systemd/resolved.conf << EOF
[Resolve]
DNS=1.1.1.1 1.0.0.1
DNSStubListener=yes
EOF
    systemctl restart systemd-resolved
  fi
  
  # Cập nhật /etc/resolv.conf
  if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak
    cat > /etc/resolv.conf << EOF
# Cloudflare DNS
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
  fi
  
  # Cấu hình resolvconf nếu được cài đặt
  if command -v resolvconf >/dev/null 2>&1; then
    echo -e "${BLUE}Cấu hình Cloudflare DNS qua resolvconf...${NC}"
    echo "nameserver 1.1.1.1" > /etc/resolvconf/resolv.conf.d/head
    echo "nameserver 1.0.0.1" >> /etc/resolvconf/resolv.conf.d/head
    resolvconf -u
  fi
  
  echo -e "${GREEN}Đã cấu hình DNS Cloudflare thành công!${NC}"
}

# Phân tích tham số dòng lệnh
while getopts "p:m:n:" opt; do
  case $opt in
    p) SS_PASS="$OPTARG" ;;
    m) SS_METHOD="$OPTARG" ;;
    n) SS_NAME="$OPTARG" ;;
    \?) echo "Tùy chọn không hợp lệ: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Nhập tên cho Shadowsocks server nếu chưa cung cấp
if [ -z "$SS_NAME" ]; then
  read -p "Nhập tên cho Shadowsocks server: " SS_NAME
  if [ -z "$SS_NAME" ]; then
    SS_NAME="MySSServer"
    echo -e "${YELLOW}Không có tên được nhập. Sử dụng tên mặc định: $SS_NAME${NC}"
  fi
fi

# Lấy cổng ngẫu nhiên cho Shadowsocks
SS_PORT=$(get_random_port)
echo -e "${GREEN}Đã chọn cổng ngẫu nhiên cho Shadowsocks: $SS_PORT${NC}"

# Phương thức mã hóa mặc định
if [ -z "$SS_METHOD" ]; then
  SS_METHOD="aes-256-gcm"
fi

# Tạo mật khẩu
generate_password

# Cài đặt các gói cần thiết
echo -e "${BLUE}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y python3-pip curl ufw qrencode libsodium-dev netcat

# Cài đặt Shadowsocks
echo -e "${BLUE}Đang cài đặt Shadowsocks...${NC}"
pip3 install https://github.com/shadowsocks/shadowsocks/archive/master.zip

# Cấu hình DNS Cloudflare cho hệ thống
configure_cloudflare_dns

# Tạo thư mục cấu hình Shadowsocks
mkdir -p /etc/shadowsocks

# Tạo cấu hình Shadowsocks với DNS Cloudflare
cat > /etc/shadowsocks/config.json << EOF
{
    "server": "0.0.0.0",
    "server_port": $SS_PORT,
    "password": "$SS_PASS",
    "timeout": 300,
    "method": "$SS_METHOD",
    "fast_open": true,
    "nameserver": "1.1.1.1,1.0.0.1",
    "dns_ipv6": false,
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

# Tối ưu hóa sysctl cho hiệu suất proxy
cat > /etc/sysctl.d/local.conf << EOF
# Tối ưu hóa cho Shadowsocks
net.core.somaxconn = 32768
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_max_tw_buckets = 6000000
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
EOF

# Áp dụng tối ưu hóa
sysctl --system

# Cấu hình tường lửa
echo -e "${BLUE}Đang cấu hình tường lửa...${NC}"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow $SS_PORT/tcp
ufw allow $SS_PORT/udp
ufw --force enable

# Khởi động dịch vụ Shadowsocks
echo -e "${BLUE}Đang khởi động Shadowsocks...${NC}"
systemctl daemon-reload
systemctl enable shadowsocks
systemctl restart shadowsocks
sleep 2

# Kiểm tra trạng thái Shadowsocks
if ! systemctl is-active --quiet shadowsocks; then
  echo -e "${YELLOW}Dịch vụ Shadowsocks không khởi động được. Đang thử phương pháp khác...${NC}"
  # Thử phương pháp chạy trực tiếp
  ssserver -c /etc/shadowsocks/config.json -d start
  sleep 2
fi

# Kiểm tra xem cổng có mở không
if ! netstat -tuln | grep -q ":$SS_PORT "; then
  echo -e "${RED}Không thể mở cổng $SS_PORT. Kiểm tra lại cấu hình.${NC}"
  systemctl status shadowsocks
  exit 1
fi

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo file QR code cho cấu hình SS (cho client di động) với tên tùy chỉnh
SS_URI="ss://$(echo -n "$SS_METHOD:$SS_PASS@$PUBLIC_IP:$SS_PORT" | base64 | tr -d '\n')#$SS_NAME"

# Tạo QR code trong thư mục hiện tại
echo -e "${GREEN}Đang tạo QR code...${NC}"
qrencode -o "$SS_NAME.png" "$SS_URI"

# Hiển thị QR code trong terminal
echo -e "\n${GREEN}=== QR CODE CHO $SS_NAME ===${NC}"
qrencode -t ANSIUTF8 -o - "$SS_URI"
echo -e "${GREEN}$SS_NAME${NC}"

# In ra thông tin kết nối
echo -e "\n${GREEN}=== THÔNG TIN SHADOWSOCKS ===${NC}"
echo -e "Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "Cổng: ${GREEN}$SS_PORT${NC}"
echo -e "Mật khẩu: ${GREEN}$SS_PASS${NC}"
echo -e "Phương thức: ${GREEN}$SS_METHOD${NC}"
echo -e "Tên: ${GREEN}$SS_NAME${NC}"
echo -e "DNS: ${GREEN}Cloudflare (1.1.1.1, 1.0.0.1)${NC}"
echo -e "\nURI cấu hình: ${GREEN}$SS_URI${NC}"
echo -e "\nQR code đã được lưu thành file: ${GREEN}$SS_NAME.png${NC}"
echo -e "\n${YELLOW}Để sử dụng trên iOS/Android, hãy quét mã QR ở trên với app Shadowsocks${NC}"
echo -e "${YELLOW}Để sử dụng trên Windows/Mac, hãy cấu hình với thông tin bên trên${NC}"
