#!/bin/bash

# Script tự động cài đặt Shadowsocks đã tối ưu
# Phiên bản tối giản - không sử dụng PAC file, sử dụng DNS Cloudflare

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
while getopts "p:m:n:" opt; do
  case $opt in
    p) SS_PASS="$OPTARG" ;;
    m) SS_METHOD="$OPTARG" ;;
    n) SS_NAME="$OPTARG" ;;
    \?) echo "Tùy chọn không hợp lệ: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Nếu không có tên được cung cấp, hỏi người dùng
if [ -z "$SS_NAME" ]; then
  echo -e "${YELLOW}Nhập tên cho QR code Shadowsocks [mặc định: SS-Server]:${NC} "
  read -r user_name
  if [ -z "$user_name" ]; then
    SS_NAME="SS-Server"
  else
    SS_NAME="$user_name"
  fi
fi

# Lấy cổng ngẫu nhiên cho Shadowsocks
SS_PORT=$(get_random_port)

# Phương thức mã hóa mặc định
if [ -z "$SS_METHOD" ]; then
  SS_METHOD="aes-256-gcm"
fi

# Tạo mật khẩu
generate_password

# Cài đặt các gói cần thiết
apt update -y
apt install -y python3-pip curl ufw qrencode

# Cài đặt Shadowsocks
pip3 install https://github.com/shadowsocks/shadowsocks/archive/master.zip

# Tạo thư mục cấu hình Shadowsocks
mkdir -p /etc/shadowsocks

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo cấu hình Shadowsocks với DNS Cloudflare
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

# Cấu hình tường lửa
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow $SS_PORT/tcp
ufw allow $SS_PORT/udp
ufw --force enable

# Khởi động lại dịch vụ
systemctl daemon-reload
systemctl enable shadowsocks
systemctl restart shadowsocks
sleep 2

# Tạo file QR code cho cấu hình SS (cho client di động)
SS_URI="ss://$(echo -n "$SS_METHOD:$SS_PASS@$PUBLIC_IP:$SS_PORT" | base64 | tr -d '\n')#$SS_NAME"
qrencode -t ANSIUTF8 -o - "$SS_URI"

# In ra thông tin kết nối
echo -e "\n${GREEN}=== THÔNG TIN SHADOWSOCKS ===${NC}"
echo -e "Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "Cổng: ${GREEN}$SS_PORT${NC}"
echo -e "Mật khẩu: ${GREEN}$SS_PASS${NC}"
echo -e "Phương thức: ${GREEN}$SS_METHOD${NC}"
echo -e "Tên: ${GREEN}$SS_NAME${NC}"
echo -e "\nURI cấu hình (dùng cho Shadowsocks clients): ${GREEN}$SS_URI${NC}"
echo -e "\n${YELLOW}Để sử dụng trên iOS/Android, hãy quét mã QR ở trên với app Shadowsocks${NC}"
