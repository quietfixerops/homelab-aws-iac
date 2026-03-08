# Latest Ubuntu 24.04 LTS ARM64 AMI
data "aws_ssm_parameter" "ubuntu_2404_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# ============== VPC (public-only) ==============
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

# ============== Security Group (Tailscale only) ==============
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

# ============== Persistent EBS Volume for Actual Budget data ==============
resource "aws_ebs_volume" "actual_data" {
  availability_zone = "${var.aws_region}a"
  size              = 10                    # 10 GB — plenty for years of budgets
  type              = "gp3"
  encrypted         = true

  tags = {
    Name  = "${var.house_name}-actualbudget-data"
    House = var.house_name
  }

  lifecycle {
    prevent_destroy = true   # ← IMPORTANT: Terraform will NEVER delete your data
  }
}

# ============== Attach EBS to the EC2 ==============
resource "aws_volume_attachment" "actual_data_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.actual_data.id
  instance_id = aws_instance.subnet_router.id
}

# ============== Single EC2: Tailscale + Actual Budget (with persistent data) ==============
resource "aws_instance" "subnet_router" {
  ami           = data.aws_ssm_parameter.ubuntu_2404_arm64.value
  instance_type = "t4g.nano"
  subnet_id     = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.subnet_router.id]
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  user_data = <<-EOF
    #!/bin/bash -ex
    apt-get update -y
    apt-get upgrade -y

    # Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh
    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
    sysctl -p

    tailscale up \
      --authkey="${var.tailscale_auth_key}" \
      --hostname=${var.house_name}-subnet-router \
      --advertise-routes=${var.vpc_cidr} \
      --advertise-tags=tag:infra-router \
      --accept-routes \
      --accept-dns=false

    tailscale set --advertise-exit-node=false

    # Docker
    apt-get install -y ca-certificates curl gnupg lsb-release
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker

    # Mount persistent EBS volume
    mkdir -p /opt/actualbudget/data
    mkfs -t ext4 /dev/sdf || true   # only formats on first attach
    mount /dev/sdf /opt/actualbudget/data || true
    echo '/dev/sdf /opt/actualbudget/data ext4 defaults,nofail 0 2' | tee -a /etc/fstab

    # Actual Budget
    cat > /opt/actualbudget/docker-compose.yml <<'EOL'
    services:
      actual:
        image: actualbudget/actual-server:latest
        ports:
          - "5006:5006"
        volumes:
          - ./data:/data
        restart: unless-stopped
    EOL

    cd /opt/actualbudget
    docker compose up -d
  EOF

  tags = {
    Name  = "${var.house_name}-subnet-router"
    House = var.house_name
  }
}

# IAM (unchanged)
resource "aws_iam_instance_profile" "ssm_profile" { ... }   # keep your existing IAM block
resource "aws_iam_role" "ssm_role" { ... }
resource "aws_iam_role_policy_attachment" "ssm_core" { ... }
