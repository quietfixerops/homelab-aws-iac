#!/bin/bash -ex
exec > >(tee -a /var/log/user-data.log) 2>&1

echo "=== Starting bootstrap script at $(date) ==="

# === 1. AWS CLI v2 FIRST (critical) ===
apt-get update -y
apt-get install -y ca-certificates curl gnupg unzip

curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

echo "AWS CLI installed successfully: $(aws --version)"

# === 2. Fetch secrets from SSM ===
HOUSE_NAME="${house_name}"
TAILSCALE_KEY=$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/tailscale-auth-key" --with-decryption --query Parameter.Value --output text)
TELEGRAM_TOKEN=$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/telegram-bot-token" --with-decryption --query Parameter.Value --output text)
TELEGRAM_CHAT_ID=$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/telegram-chat-id" --with-decryption --query Parameter.Value --output text)

echo "All secrets fetched from SSM successfully"

# === 3. Tailscale ===
curl -fsSL https://tailscale.com/install.sh | sh
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
sysctl -p

tailscale up --authkey="$TAILSCALE_KEY" \
  --hostname=${house_name}-subnet-router \
  --advertise-routes=${vpc_cidr} \
  --advertise-tags=tag:infra-router \
  --accept-routes --accept-dns=false || echo "Tailscale up completed (warnings are normal)"

echo "Tailscale started"

# === 4. Docker + add ubuntu user to docker group ===
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

usermod -aG docker ubuntu
echo "Docker installed: $(docker --version)"

# === 5. EBS volume + ActualBudget data dir ===
mkdir -p /opt/actualbudget/data

EBS_DEVICE=$(lsblk -o NAME,SERIAL -n | grep -E 'nvme1n1|vol' | awk '{print "/dev/"$1}' | head -n1)
if [ -n "$EBS_DEVICE" ] && ! mountpoint -q /opt/actualbudget/data; then
  mkfs.ext4 -F $EBS_DEVICE || true
  mount $EBS_DEVICE /opt/actualbudget/data
  echo "$EBS_DEVICE /opt/actualbudget/data ext4 defaults,nofail 0 2" >> /etc/fstab
  echo "EBS volume mounted successfully"
fi

# === 6. Docker Compose + Watchtower ===
cat > /opt/actualbudget/docker-compose.yml <<EOL
services:
  actual:
    image: actualbudget/actual-server:latest
    ports: ["5006:5006"]
    volumes: ["./data:/data"]
    restart: unless-stopped
  watchtower:
    image: containrrr/watchtower:latest
    volumes: ["/var/run/docker.sock:/var/run/docker.sock"]
    environment:
      - WATCHTOWER_POLL_INTERVAL=3600
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_NOTIFICATION_TYPE=shoutrrr
      - WATCHTOWER_NOTIFICATION_URL=telegram://$TELEGRAM_TOKEN@telegram?channels=$TELEGRAM_CHAT_ID
    restart: unless-stopped
EOL

cd /opt/actualbudget && docker compose up -d
echo "ActualBudget + Watchtower started successfully"

# === 7. Daily backup cron (re-fetches secrets) ===
cat > /usr/local/bin/backup-actualbudget.sh <<'BACKUP'
#!/bin/bash
HOUSE_NAME="5marionct"
TELEGRAM_TOKEN=$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/telegram-bot-token" --with-decryption --query Parameter.Value --output text)
TELEGRAM_CHAT_ID=$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/telegram-chat-id" --with-decryption --query Parameter.Value --output text)

DATE=$(date +%Y-%m-%d)
BACKUP_FILE="/tmp/actualbudget-$DATE.tar.gz"
cd /opt/actualbudget
docker compose down
tar -czf $BACKUP_FILE data/
docker compose up -d
aws s3 cp $BACKUP_FILE s3://${backup_bucket_name}/actual-budget/actualbudget-$DATE.tar.gz --storage-class STANDARD_IA
rm -f $BACKUP_FILE
curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=✅ Actual Budget backup completed: actual-budget/actualbudget-$DATE.tar.gz"
BACKUP

chmod +x /usr/local/bin/backup-actualbudget.sh
echo "0 3 * * * /usr/local/bin/backup-actualbudget.sh" | crontab -

echo "=== FULL BOOTSTRAP COMPLETED SUCCESSFULLY at $(date) ==="
