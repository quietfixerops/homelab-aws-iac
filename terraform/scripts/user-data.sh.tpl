#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
exec > >(tee -a /var/log/user-data.log) 2>&1

echo "=== Starting bootstrap script at $(date -Is) ==="

HOUSE_NAME="${house_name}"
VPC_CIDR="${vpc_cidr}"
BACKUP_BUCKET_NAME="${backup_bucket_name}"
ACTUAL_DIR="/opt/actualbudget"
DATA_DIR="$${ACTUAL_DIR}/data"

log() {
  echo "[$(date -Is)] $*"
}

wait_for_apt() {
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
     || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    log "Waiting for apt/dpkg lock..."
    sleep 3
  done
}

apt_install() {
  wait_for_apt
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

ensure_swap() {
  if swapon --show | grep -q .; then
    log "Swap already enabled"
    return
  fi

  log "Enabling 1G swap for tiny instance stability"
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
  else
    dd if=/dev/zero of=/swapfile bs=1M count=1024
  fi

  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  free -h
}

retry() {
  local attempts="$1"
  shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      log "Command failed after $attempts attempts: $*"
      return 1
    fi
    log "Command failed, retrying ($n/$attempts): $*"
    n=$((n + 1))
    sleep 5
  done
}

detect_ebs_device() {
  local dev=""
  for _ in $(seq 1 60); do
    for candidate in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
      if [ -b "$candidate" ]; then
        dev="$candidate"
        break
      fi
    done
    [ -n "$dev" ] && break
    sleep 2
  done

  if [ -z "$dev" ]; then
    log "ERROR: expected EBS device not found"
    return 1
  fi

  printf '%s\n' "$dev"
}

mount_data_volume() {
  mkdir -p "$DATA_DIR"

  local ebs_device
  ebs_device="$(detect_ebs_device)"
  log "Detected EBS device: $ebs_device"

  if ! blkid "$ebs_device" >/dev/null 2>&1; then
    log "No filesystem found on $ebs_device, creating ext4"
    mkfs.ext4 -L actualbudget-data "$ebs_device"
  else
    log "Existing filesystem detected on $ebs_device"
  fi

  local uuid
  uuid="$(blkid -s UUID -o value "$ebs_device")"
  if [ -z "$uuid" ]; then
    log "ERROR: could not determine UUID for $ebs_device"
    return 1
  fi

  grep -q " $${DATA_DIR} " /etc/fstab || \
    echo "UUID=$uuid $DATA_DIR ext4 defaults,nofail 0 2" >> /etc/fstab

  mountpoint -q "$DATA_DIR" || mount "$DATA_DIR"
  chown -R ubuntu:ubuntu "$ACTUAL_DIR"
  log "EBS volume mounted successfully at $DATA_DIR"
}

install_awscli() {
  if command -v aws >/dev/null 2>&1; then
    log "AWS CLI already installed: $(aws --version)"
    return
  fi

  apt_install ca-certificates curl gnupg unzip cron jq
  retry 3 curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
  rm -rf /tmp/aws
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip

  log "AWS CLI installed successfully: $(aws --version)"
}

fetch_secrets() {
  log "Fetching secrets from SSM"
  TAILSCALE_KEY="$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/tailscale-auth-key" --with-decryption --query 'Parameter.Value' --output text)"
  TELEGRAM_TOKEN="$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/telegram-bot-token" --with-decryption --query 'Parameter.Value' --output text)"
  TELEGRAM_CHAT_ID="$(aws ssm get-parameter --name "/homelab/$HOUSE_NAME/telegram-chat-id" --with-decryption --query 'Parameter.Value' --output text)"
  log "All secrets fetched from SSM successfully"
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale already installed"
  else
    retry 3 bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
  fi

  grep -qxF 'net.ipv4.ip_forward = 1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
  grep -qxF 'net.ipv6.conf.all.forwarding = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
  sysctl -p

  systemctl enable --now tailscaled

  install -d -m 0700 /root/.config/tailscale
  local authkey_file=/root/.config/tailscale/authkey
  printf '%s' "$TAILSCALE_KEY" > "$authkey_file"
  chmod 0600 "$authkey_file"

  tailscale up \
    --auth-key "file:$authkey_file" \
    --hostname "$${HOUSE_NAME}-subnet-router" \
    --advertise-routes "$VPC_CIDR" \
    --advertise-tags=tag:infra-router \
    --accept-routes \
    --accept-dns=false \
    --ssh || log "tailscale up returned non-zero; check admin approval state if needed"

  shred -u "$authkey_file" 2>/dev/null || rm -f "$authkey_file"
  unset TAILSCALE_KEY

  log "Tailscale started with Tailscale SSH enabled"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    return
  fi

  ensure_swap
  apt_install ca-certificates curl gnupg cron

  install -m 0755 -d /etc/apt/keyrings
  retry 3 bash -c 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg'
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

  wait_for_apt
  apt-get update -y
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable --now docker
  usermod -aG docker ubuntu || true

  docker --version
  docker compose version
  log "Docker installed successfully"
}

write_compose_file() {
  mkdir -p "$ACTUAL_DIR" "$DATA_DIR" "$ACTUAL_DIR/diun"

  cat > "$ACTUAL_DIR/docker-compose.yml" <<'COMPOSE_FILE'
services:
  actual:
    image: actualbudget/actual-server:latest
    container_name: actualbudget
    ports:
      - "5006:5006"
    volumes:
      - "./data:/data"
    restart: unless-stopped
    labels:
      - "diun.enable=true"

  diun:
    image: crazymax/diun:v4.31.0
    container_name: diun
    command: serve
    hostname: "__HOUSE_NAME__-diun"
    volumes:
      - "./diun:/data"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
    environment:
      TZ: "America/Chicago"
      LOG_LEVEL: "info"
      LOG_JSON: "false"
      DIUN_WATCH_WORKERS: "10"
      DIUN_WATCH_SCHEDULE: "0 9 * * *"
      DIUN_WATCH_JITTER: "30s"
      DIUN_WATCH_RUNONSTARTUP: "true"
      DIUN_PROVIDERS_DOCKER: "true"
      DIUN_PROVIDERS_DOCKER_WATCHBYDEFAULT: "false"
      DIUN_NOTIF_TELEGRAM_TOKEN: "__TELEGRAM_TOKEN__"
      DIUN_NOTIF_TELEGRAM_CHATIDS: "__TELEGRAM_CHAT_ID__"
    restart: unless-stopped
COMPOSE_FILE

  sed -i \
    -e "s|__HOUSE_NAME__|$HOUSE_NAME|g" \
    -e "s|__TELEGRAM_TOKEN__|$TELEGRAM_TOKEN|g" \
    -e "s|__TELEGRAM_CHAT_ID__|$TELEGRAM_CHAT_ID|g" \
    "$ACTUAL_DIR/docker-compose.yml"

  chown -R ubuntu:ubuntu "$ACTUAL_DIR"

  if [ ! -f "$ACTUAL_DIR/docker-compose.yml" ]; then
    log "ERROR: failed to create $ACTUAL_DIR/docker-compose.yml"
    return 1
  fi

  log "Created $ACTUAL_DIR/docker-compose.yml"
  ls -l "$ACTUAL_DIR/docker-compose.yml"
}

start_containers() {
  if [ ! -f "$ACTUAL_DIR/docker-compose.yml" ]; then
    log "ERROR: $ACTUAL_DIR/docker-compose.yml not found"
    ls -la "$ACTUAL_DIR" || true
    return 1
  fi

  cd "$ACTUAL_DIR"
  docker compose -f "$ACTUAL_DIR/docker-compose.yml" up -d
  docker ps
  log "ActualBudget + DIUN started successfully"
}

install_backup_script() {
  cat > /usr/local/bin/backup-actualbudget.sh <<EOF
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

HOUSE_NAME="$${HOUSE_NAME}"
BACKUP_BUCKET_NAME="$${BACKUP_BUCKET_NAME}"
ACTUAL_DIR="$${ACTUAL_DIR}"

TELEGRAM_TOKEN=\$(aws ssm get-parameter --name "/homelab/\$HOUSE_NAME/telegram-bot-token" --with-decryption --query 'Parameter.Value' --output text)
TELEGRAM_CHAT_ID=\$(aws ssm get-parameter --name "/homelab/\$HOUSE_NAME/telegram-chat-id" --with-decryption --query 'Parameter.Value' --output text)

DATE=\$(date +%Y-%m-%d)
BACKUP_FILE="/tmp/actualbudget-\$DATE.tar.gz"

cd "\$ACTUAL_DIR"
tar -czf "\$BACKUP_FILE" data/

aws s3 cp "\$BACKUP_FILE" "s3://\$BACKUP_BUCKET_NAME/actual-budget/actualbudget-\$DATE.tar.gz" --storage-class STANDARD_IA
rm -f "\$BACKUP_FILE"

curl -fsS -X POST "https://api.telegram.org/bot\$TELEGRAM_TOKEN/sendMessage" \
  -d "chat_id=\$TELEGRAM_CHAT_ID" \
  -d "text=✅ Actual Budget backup completed: actual-budget/actualbudget-\$DATE.tar.gz"
EOF

  chmod +x /usr/local/bin/backup-actualbudget.sh
}

install_cron() {
  systemctl enable --now cron
  cat > /etc/cron.d/actualbudget-backup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root /usr/local/bin/backup-actualbudget.sh >> /var/log/actualbudget-backup.log 2>&1
EOF
  chmod 0644 /etc/cron.d/actualbudget-backup
  systemctl restart cron
  log "Backup cron installed"
}

main() {
  install_awscli
  fetch_secrets
  install_tailscale
  install_docker
  mount_data_volume
  write_compose_file
  start_containers
  install_backup_script
  install_cron

  log "=== FULL BOOTSTRAP COMPLETED SUCCESSFULLY ==="
}

main