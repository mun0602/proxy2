#!/bin/bash

# Script cài đặt GOST với HTTP, SOCKS5 và HTTP-SOCKS Bridge
# Cho phép thiết bị chỉ hỗ trợ HTTP proxy (như iPhone) sử dụng SOCKS5

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

# Hàm lấy địa chỉ IP công cộng
get_public_ip() {
  PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || 
              curl -s https://api.ipify.org || 
              curl -s https://ifconfig.me)

  if [ -z "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi
}

# Chọn cổng 
HTTP_PROXY_PORT=8080
SOCKS5_PROXY_PORT=1080
BRIDGE_PORT=8118
HTTP_PORT=80
echo -e "${GREEN}Sử dụng cổng HTTP proxy: $HTTP_PROXY_PORT${NC}"
echo -e "${GREEN}Sử dụng cổng SOCKS5 proxy: $SOCKS5_PROXY_PORT${NC}"
echo -e "${GREEN}Sử dụng cổng HTTP-SOCKS Bridge: $BRIDGE_PORT${NC}"
echo -e "${GREEN}Sử dụng cổng web server: $HTTP_PORT${NC}"

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y nginx curl ufw wget privoxy

# Dừng các dịch vụ hiện có
systemctl stop nginx 2>/dev/null
systemctl stop privoxy 2>/dev/null
pkill gost 2>/dev/null

# Tải về và cài đặt GOST
echo -e "${GREEN}Đang tải và cài đặt GOST...${NC}"
mkdir -p /tmp/gost
cd /tmp/gost
wget https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
gunzip gost-linux-amd64-2.11.5.gz
mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
chmod +x /usr/local/bin/gost

# Tạo thư mục cấu hình GOST
mkdir -p /etc/gost

# Tạo service file cho GOST - cấu hình cả HTTP và SOCKS5
cat > /etc/systemd/system/gost.service << EOF
[Unit]
Description=GO Simple Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L http://:$HTTP_PROXY_PORT -L socks5://:$SOCKS5_PROXY_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Cấu hình Privoxy làm cầu nối HTTP-SOCKS5
echo -e "${GREEN}Đang cấu hình Privoxy làm HTTP-SOCKS5 Bridge...${NC}"
cat > /etc/privoxy/config << EOF
listen-address  0.0.0.0:$BRIDGE_PORT
toggle  1
enable-remote-toggle  0
enable-remote-http-toggle  0
enable-edit-actions 0
enforce-blocks 0
buffer-limit 4096
forward-socks5 / 127.0.0.1:$SOCKS5_PROXY_PORT .
debug 0
EOF

# Tạo thư mục cho PAC file
mkdir -p /var/www/html

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo PAC file với cả ba tùy chọn
cat > /var/www/html/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Chọn HTTP proxy làm mặc định, SOCKS5 làm backup
    return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT; SOCKS5 $PUBLIC_IP:$SOCKS5_PROXY_PORT; DIRECT";
}
EOF

# Tạo PAC file chỉ dùng SOCKS5
cat > /var/www/html/socks5.pac << EOF
function FindProxyForURL(url, host) {
    // Chỉ sử dụng SOCKS5 proxy
    return "SOCKS5 $PUBLIC_IP:$SOCKS5_PROXY_PORT; DIRECT";
}
EOF

# Tạo PAC file chỉ dùng HTTP
cat > /var/www/html/http.pac << EOF
function FindProxyForURL(url, host) {
    // Chỉ sử dụng HTTP proxy
    return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT; DIRECT";
}
EOF

# Tạo PAC file dùng HTTP-SOCKS Bridge (dành cho thiết bị chỉ hỗ trợ HTTP)
cat > /var/www/html/bridge.pac << EOF
function FindProxyForURL(url, host) {
    // Sử dụng HTTP-SOCKS Bridge
    return "PROXY $PUBLIC_IP:$BRIDGE_PORT; DIRECT";
}
EOF

# Tạo trang index với thông tin và lựa chọn
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Proxy Options</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .proxy-info { background: #f5f5f5; padding: 15px; margin-bottom: 20px; border-radius: 5px; }
        .proxy-option { margin-bottom: 10px; }
        .proxy-option a { text-decoration: none; color: #0066cc; }
        .iphone-note { background: #fffbea; padding: 10px; border-left: 4px solid #ffcc00; margin: 15px 0; }
    </style>
</head>
<body>
    <h2>Proxy Settings</h2>
    
    <div class="proxy-info">
        <h3>Available Proxies:</h3>
        <p><strong>HTTP Proxy:</strong> $PUBLIC_IP:$HTTP_PROXY_PORT</p>
        <p><strong>SOCKS5 Proxy:</strong> $PUBLIC_IP:$SOCKS5_PROXY_PORT</p>
        <p><strong>HTTP-SOCKS Bridge:</strong> $PUBLIC_IP:$BRIDGE_PORT</p>
    </div>
    
    <div class="iphone-note">
        <strong>iPhone & iPad Users:</strong> Use either the regular HTTP proxy or the HTTP-SOCKS Bridge. 
        The Bridge allows iPhone to use SOCKS5 protocol through HTTP proxy.
    </div>
    
    <h3>PAC Files:</h3>
    <div class="proxy-option">
        <p><a href="/proxy.pac">Combined PAC</a> - Uses HTTP with SOCKS5 fallback</p>
    </div>
    <div class="proxy-option">
        <p><a href="/http.pac">HTTP PAC</a> - HTTP proxy only</p>
    </div>
    <div class="proxy-option">
        <p><a href="/socks5.pac">SOCKS5 PAC</a> - SOCKS5 proxy only (not for iPhone/iPad)</p>
    </div>
    <div class="proxy-option">
        <p><a href="/bridge.pac">Bridge PAC</a> - Uses HTTP-SOCKS Bridge (best for iPhone/iPad)</p>
    </div>
    
    <h3>Manual Configuration:</h3>
    <p>If you prefer manual setup, use the proxy information above.</p>
    <p>No username or password required.</p>
</body>
</html>
EOF

# Cấu hình Nginx để phục vụ PAC file
cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root /var/www/html;
    index index.html;
    
    server_name _;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location ~ \.pac$ {
        types { }
        default_type application/x-ns-proxy-autoconfig;
    }
}
EOF

# Cấu hình tường lửa
echo -e "${GREEN}Đang cấu hình tường lửa...${NC}"
# Sao lưu các quy tắc tường lửa hiện tại
iptables-save > /tmp/iptables-rules.bak

# Mở các cổng trên ufw
ufw allow ssh
ufw allow $HTTP_PORT/tcp
ufw allow $HTTP_PROXY_PORT/tcp
ufw allow $SOCKS5_PROXY_PORT/tcp
ufw allow $BRIDGE_PORT/tcp

# Nếu ufw bị tắt, mở các cổng bằng iptables trực tiếp
iptables -I INPUT -p tcp --dport 22 -j ACCEPT
iptables -I INPUT -p tcp --dport $HTTP_PORT -j ACCEPT
iptables -I INPUT -p tcp --dport $HTTP_PROXY_PORT -j ACCEPT
iptables -I INPUT -p tcp --dport $SOCKS5_PROXY_PORT -j ACCEPT
iptables -I INPUT -p tcp --dport $BRIDGE_PORT -j ACCEPT

# Kích hoạt và khởi động các dịch vụ
systemctl daemon-reload
systemctl enable gost
systemctl enable nginx
systemctl enable privoxy
systemctl start gost
systemctl start nginx
systemctl start privoxy

# Tạo script kiểm tra
cat > /usr/local/bin/check-proxy.sh << EOF
#!/bin/bash
# Script kiểm tra proxy

# Kiểm tra GOST
if pgrep gost > /dev/null; then
  echo "GOST đang chạy"
else
  echo "GOST không chạy - khởi động lại"
  systemctl restart gost
fi

# Kiểm tra Nginx
if systemctl is-active --quiet nginx; then
  echo "Nginx đang chạy"
else
  echo "Nginx không chạy - khởi động lại"
  systemctl restart nginx
fi

# Kiểm tra Privoxy
if systemctl is-active --quiet privoxy; then
  echo "Privoxy (HTTP-SOCKS Bridge) đang chạy"
else
  echo "Privoxy không chạy - khởi động lại"
  systemctl restart privoxy
fi

# Kiểm tra kết nối HTTP proxy
echo "Kiểm tra kết nối HTTP proxy..."
curl -x http://localhost:$HTTP_PROXY_PORT -s https://httpbin.org/ip

# Kiểm tra kết nối SOCKS5 proxy
echo "Kiểm tra kết nối SOCKS5 proxy..."
curl --socks5 localhost:$SOCKS5_PROXY_PORT -s https://httpbin.org/ip

# Kiểm tra kết nối HTTP-SOCKS Bridge
echo "Kiểm tra kết nối HTTP-SOCKS Bridge..."
curl -x http://localhost:$BRIDGE_PORT -s https://httpbin.org/ip
EOF
chmod +x /usr/local/bin/check-proxy.sh

# Kiểm tra GOST
echo -e "${YELLOW}Đang kiểm tra GOST...${NC}"
sleep 2
if pgrep gost > /dev/null; then
  echo -e "${GREEN}GOST đang chạy!${NC}"
else
  echo -e "${RED}GOST không chạy. Khởi động thủ công...${NC}"
  /usr/local/bin/gost -L http://:$HTTP_PROXY_PORT -L socks5://:$SOCKS5_PROXY_PORT &
fi

# Kiểm tra Nginx
echo -e "${YELLOW}Đang kiểm tra Nginx...${NC}"
if systemctl is-active --quiet nginx; then
  echo -e "${GREEN}Nginx đang chạy!${NC}"
else
  echo -e "${RED}Nginx không khởi động được. Kiểm tra log: journalctl -u nginx${NC}"
  nginx
fi

# Kiểm tra Privoxy
echo -e "${YELLOW}Đang kiểm tra Privoxy...${NC}"
if systemctl is-active --quiet privoxy; then
  echo -e "${GREEN}Privoxy đang chạy!${NC}"
else
  echo -e "${RED}Privoxy không khởi động được. Kiểm tra log: journalctl -u privoxy${NC}"
fi

# Hiển thị thông tin cấu hình
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}PROXY HOÀN CHỈNH ĐÃ CÀI ĐẶT XONG!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "HTTP Proxy: ${GREEN}$PUBLIC_IP:$HTTP_PROXY_PORT${NC}"
echo -e "SOCKS5 Proxy: ${GREEN}$PUBLIC_IP:$SOCKS5_PROXY_PORT${NC}"
echo -e "HTTP-SOCKS Bridge: ${GREEN}$PUBLIC_IP:$BRIDGE_PORT${NC}"
echo -e "PAC Files:"
echo -e "  Kết hợp: ${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
echo -e "  HTTP: ${GREEN}http://$PUBLIC_IP/http.pac${NC}"
echo -e "  SOCKS5: ${GREEN}http://$PUBLIC_IP/socks5.pac${NC}"
echo -e "  Bridge: ${GREEN}http://$PUBLIC_IP/bridge.pac${NC}"
echo -e "${GREEN}============================================${NC}"

# Hướng dẫn cho iPhone/iPad
echo -e "\n${YELLOW}HƯỚNG DẪN CHO iPHONE/iPAD:${NC}"
echo -e "1. ${GREEN}Sử dụng PAC tự động:${NC}"
echo -e "   - Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Auto"
echo -e "   - URL: ${GREEN}http://$PUBLIC_IP/bridge.pac${NC}"
echo -e "2. ${GREEN}Cấu hình thủ công:${NC}"
echo -e "   - Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Manual"
echo -e "   - Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "   - Port: ${GREEN}$BRIDGE_PORT${NC} (sử dụng Bridge để có hiệu suất tốt nhất)"
echo -e "   - Không cần Authentication"

# Hướng dẫn khắc phục sự cố
echo -e "\n${YELLOW}KHẮC PHỤC SỰ CỐ:${NC}"
echo -e "- Chạy script kiểm tra: ${GREEN}sudo /usr/local/bin/check-proxy.sh${NC}"
echo -e "- Kiểm tra log GOST: ${GREEN}journalctl -u gost${NC}"
echo -e "- Kiểm tra log Privoxy: ${GREEN}journalctl -u privoxy${NC}"
echo -e "- Khởi động lại tất cả: ${GREEN}systemctl restart gost privoxy nginx${NC}"
echo -e "- Kiểm tra cổng đang mở: ${GREEN}netstat -tulpn | grep -E '$HTTP_PROXY_PORT|$SOCKS5_PROXY_PORT|$BRIDGE_PORT'${NC}"
