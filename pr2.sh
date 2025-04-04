#!/bin/bash

# Script tự động cài đặt Shadowsocks đã tối ưu
# Phiên bản tối giản - không sử dụng PAC file, sử dụng DNS Cloudflare

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

# Lưu thông tin kết nối vào file để người dùng có thể xem lại sau này
CONFIG_FILE="/root/shadowsocks_info.txt"
cat > "$CONFIG_FILE" << EOF
Server: $PUBLIC_IP
Cổng: $SS_PORT
Mật khẩu: $SS_PASS
Phương thức: $SS_METHOD
Tên: $SS_NAME
URI: ss://$(echo -n "$SS_METHOD:$SS_PASS@$PUBLIC_IP:$SS_PORT" | base64 | tr -d '\n')#$SS_NAME
EOF

# Kiểm tra phương thức mã hóa đúng định dạng
if [[ ! "$SS_METHOD" =~ ^(aes-256-gcm|aes-128-gcm|chacha20-ietf-poly1305|aes-256-cfb|aes-128-cfb)$ ]]; then
  echo -e "${YELLOW}Cảnh báo: Phương thức mã hóa '$SS_METHOD' có thể không được hỗ trợ. Đang sử dụng mặc định aes-256-gcm${NC}"
  SS_METHOD="aes-256-gcm"
fi

# Tạo URI Shadowsocks đảm bảo đúng định dạng
# Format: ss://BASE64(method:password@server:port)#tag
BASE64_STR=$(echo -n "$SS_METHOD:$SS_PASS@$PUBLIC_IP:$SS_PORT" | base64 -w 0)
SS_URI="ss://${BASE64_STR}#${SS_NAME}"

# Kiểm tra và hiển thị mẫu URI để xác nhận
echo -e "${YELLOW}URI Shadowsocks: ${NC}$SS_URI" >> "$CONFIG_FILE"

# Lưu URI vào file riêng để dễ truy cập
echo "$SS_URI" > "/root/shadowsocks_uri.txt"

# Hiển thị QR code trước, sau đó hiển thị tên ở dưới giữa với định dạng --------TÊN-------- màu xanh dương
echo
qrencode -t ANSIUTF8 -o - "$SS_URI"
# Tạo dòng trống để cách khoảng
echo
# Lấy độ dài của terminal để căn giữa
TERM_WIDTH=$(tput cols)
FORMATTED_NAME="--------${SS_NAME}--------"
NAME_LENGTH=${#FORMATTED_NAME}
# Tính số khoảng trắng cần thêm vào trước tên để căn giữa
PADDING=$(( (TERM_WIDTH - NAME_LENGTH) / 2 ))
# In tên với định dạng in đậm, màu xanh dương và căn giữa
printf "%${PADDING}s" ""
echo -e "${BLUE}\033[1m${FORMATTED_NAME}\033[0m"
echo
echo -e "\n${YELLOW}Quét mã QR trên với app Shadowsocks để kết nối${NC}"
echo -e "${YELLOW}Thông tin kết nối đã được lưu vào: $CONFIG_FILE${NC}"
