# Latest Ubuntu 24.04 LTS ARM64 AMI
data "aws_ssm_parameter" "ubuntu_2404_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# ============== VPC ==============
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.house_name}-vpc"
  cidr = var.vpc_cidr

  azs            = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 3)]

  enable_nat_gateway = false
  create_igw         = true

  tags = { House = var.house_name, IaC = "Terraform" }
}

# ============== Security Group ==============
resource "aws_security_group" "subnet_router" {
  name        = "${var.house_name}-subnet-router-sg"
  description = "Tailscale only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { House = var.house_name }
}

# ============== Persistent EBS Volume ==============
resource "aws_ebs_volume" "actual_data" {
  availability_zone = "${var.aws_region}a"
  size              = 10
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.house_name}-actualbudget-data", House = var.house_name }

  lifecycle { prevent_destroy = true }
}

resource "aws_volume_attachment" "actual_data_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.actual_data.id
  instance_id = aws_instance.subnet_router.id
}

# ============== Single EC2 ==============
resource "aws_instance" "subnet_router" {
  ami           = data.aws_ssm_parameter.ubuntu_2404_arm64.value
  instance_type = "t4g.nano"
  subnet_id     = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.subnet_router.id]
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  lifecycle { create_before_destroy = true }

  user_data = <<-EOF
    #!/bin/bash -ex
    exec > >(tee -a /var/log/user-data.log) 2>&1

    apt-get update -y && apt-get upgrade -y

    # Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh
    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
    sysctl -p

    tailscale up --authkey="${var.tailscale_auth_key}" --hostname=${var.house_name}-subnet-router --advertise-routes=${var.vpc_cidr} --advertise-tags=tag:infra-router --accept-routes --accept-dns=false
    tailscale set --advertise-exit-node=false

    # Docker
    apt-get install -y ca-certificates curl gnupg lsb-release awscli
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker

    # Smart EBS Mount
    mkdir -p /opt/actualbudget/data
    EBS_DEVICE=$(lsblk -o NAME,SIZE -d -n | awk '$2 ~ /^[0-9]/ && $1 ~ /^nvme/ && $1 !~ /n1p/ {print "/dev/" $1}' | head -n1)
    if [ -n "$EBS_DEVICE" ]; then
      if ! blkid $EBS_DEVICE > /dev/null 2>&1; then mkfs -t ext4 $EBS_DEVICE; fi
      mount $EBS_DEVICE /opt/actualbudget/data || true
      echo "$EBS_DEVICE /opt/actualbudget/data ext4 defaults,nofail 0 2" | tee -a /etc/fstab
    fi

    # Actual Budget + Watchtower
    cat > /opt/actualbudget/docker-compose.yml <<'EOL'
    services:
      actual:
        image: actualbudget/actual-server:latest
        ports:
          - "5006:5006"
        volumes:
          - ./data:/data
        restart: unless-stopped

      watchtower:
        image: containrrr/watchtower:latest
        volumes:
          - /var/run/docker.sock:/var/run/docker.sock
        environment:
          - WATCHTOWER_POLL_INTERVAL=3600
          - WATCHTOWER_CLEANUP=true
          - WATCHTOWER_NOTIFICATION_TYPE=shoutrrr
          - WATCHTOWER_NOTIFICATION_TITLE=Homelab Update
          - WATCHTOWER_NOTIFICATION_URL=telegram://${var.telegram_bot_token}@telegram?channels=8634860634
        restart: unless-stopped
    EOL

    cd /opt/actualbudget
    docker compose down || true
    docker compose up -d

    # Daily backup to your existing bucket (organized folder)
    cat > /usr/local/bin/backup-actualbudget.sh <<'BACKUP'
    #!/bin/bash
    DATE=$(date +%Y-%m-%d)
    BACKUP_FILE="/tmp/actualbudget-$DATE.tar.gz"
    cd /opt/actualbudget
    docker compose down
    tar -czf $BACKUP_FILE data/
    docker compose up -d
    aws s3 cp $BACKUP_FILE s3://backups-083636778104/actual-budget/actualbudget-$DATE.tar.gz --storage-class STANDARD_IA
    rm $BACKUP_FILE
    curl -s -X POST "https://api.telegram.org/bot${var.telegram_bot_token}/sendMessage" -d "chat_id=8634860634" -d "text=✅ Actual Budget backup completed: actual-budget/actualbudget-$DATE.tar.gz"
    BACKUP

    chmod +x /usr/local/bin/backup-actualbudget.sh
    echo "0 3 * * * /usr/local/bin/backup-actualbudget.sh" | crontab -
  EOF

  tags = { Name = "${var.house_name}-subnet-router", House = var.house_name }
}

# ============== IAM ==============
resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.house_name}-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

resource "aws_iam_role" "ssm_role" {
  name = "${var.house_name}-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "s3_backup" {
  name = "${var.house_name}-s3-backup"
  role = aws_iam_role.ssm_role.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "arn:aws:s3:::backups-083636778104/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
