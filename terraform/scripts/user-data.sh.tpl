#!/bin/bash -euo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

echo "=== Starting bootstrap script at $(date) ==="

# === 1. AWS CLI v2 FIRST ===
apt-get update -y
apt-get install -y ca-certificates curl gnupg unzip

curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

echo "AWS CLI installed successfully: $(aws --version)"

# === 2. Fetch secrets ===
HOUSE_NAME="${house_name}"
TAILSCALE_KEY=$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/tailscale-auth-key" --with-decryption --query Parameter.Value --output text)
TELEGRAM_TOKEN=$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/telegram-bot-token" --with-decryption --query Parameter.Value --output text)
TELEGRAM_CHAT_ID=$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/telegram-chat-id" --with-decryption --query Parameter.Value --output text)

echo "All secrets fetched from SSM successfully"

# === 3. Tailscale ===
# === 3. Tailscale ===
curl -fsSL https://tailscale.com/install.sh | sh

grep -qxF 'net.ipv4.ip_forward = 1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
grep -qxF 'net.ipv6.conf.all.forwarding = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
sysctl -p

install -d -m 0700 /root/.config/tailscale
AUTHKEY_FILE=/root/.config/tailscale/authkey
printf '%s' "$TAILSCALE_KEY" > "$AUTHKEY_FILE"
chmod 0600 "$AUTHKEY_FILE"

tailscale up \
  --auth-key "file:$${AUTHKEY_FILE}" \
  --hostname="${house_name}-subnet-router" \
  --advertise-routes="${vpc_cidr}" \
  --advertise-tags=tag:infra-router \
  --accept-routes \
  --accept-dns=false || echo "Tailscale up completed (warnings are normal)"

shred -u "$AUTHKEY_FILE" || rm -f "$AUTHKEY_FILE"
unset TAILSCALE_KEY

echo "Tailscale started"

# === 4. Docker + ubuntu user to docker group ===
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

usermod -aG docker ubuntu
echo "Docker installed: $(docker --version)"

# === 5. EBS volume + ActualBudget data dir ===
mkdir -p /opt/actualbudget/data

# Wait for the attached volume to appear. For Nitro instances, /dev/sdf usually shows up as /dev/nvme1n1.
for _ in $(seq 1 30); do
  if [ -b /dev/nvme1n1 ]; then
    EBS_DEVICE=/dev/nvme1n1
    break
  elif [ -b /dev/xvdf ]; then
    EBS_DEVICE=/dev/xvdf
    break
  fi
  sleep 2
done

if [ -z "$${EBS_DEVICE:-}" ]; then
  echo "ERROR: expected EBS device not found" >&2
  exit 1
fi

if ! blkid "$EBS_DEVICE" >/dev/null 2>&1; then
  mkfs.ext4 -L actualbudget-data "$EBS_DEVICE"
fi

UUID="$(blkid -s UUID -o value "$EBS_DEVICE")"
if [ -z "$UUID" ]; then
  echo "ERROR: could not determine filesystem UUID for $EBS_DEVICE" >&2
  exit 1
fi

grep -q "/opt/actualbudget/data " /etc/fstab || \
  echo "UUID=$UUID /opt/actualbudget/data ext4 defaults,nofail 0 2" >> /etc/fstab

mountpoint -q /opt/actualbudget/data || mount /opt/actualbudget/data
echo "EBS volume mounted successfully"

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

# === 7. Daily backup cron ===
cat > /usr/local/bin/backup-actualbudget.sh <<BACKUP
#!/bin/bash
set -euo pipefail

HOUSE_NAME="${house_name}"

TELEGRAM_TOKEN=\$(aws ssm get-parameter --name "/homelab/\$HOUSE_NAME/telegram-bot-token" --with-decryption --query Parameter.Value --output text)
TELEGRAM_CHAT_ID=\$(aws ssm get-parameter --name "/homelab/\$HOUSE_NAME/telegram-chat-id" --with-decryption --query Parameter.Value --output text)

DATE=\$(date +%Y-%m-%d)
BACKUP_FILE="/tmp/actualbudget-\$DATE.tar.gz"

cd /opt/actualbudget
tar -czf "\$BACKUP_FILE" data/

aws s3 cp "\$BACKUP_FILE" "s3://${backup_bucket_name}/actual-budget/actualbudget-\$DATE.tar.gz" --storage-class STANDARD_IA
rm -f "\$BACKUP_FILE"

curl -fsS -X POST "https://api.telegram.org/bot\$TELEGRAM_TOKEN/sendMessage" \
  -d "chat_id=\$TELEGRAM_CHAT_ID" \
  -d "text=✅ Actual Budget backup completed: actual-budget/actualbudget-\$DATE.tar.gz"
BACKUP

chmod +x /usr/local/bin/backup-actualbudget.sh
echo "0 3 * * * /usr/local/bin/backup-actualbudget.sh" | crontab -

echo "=== FULL BOOTSTRAP COMPLETED SUCCESSFULLY at $(date) ==="
