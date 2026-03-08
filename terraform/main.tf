# Latest Ubuntu 24.04 LTS ARM64 AMI
data "aws_ssm_parameter" "ubuntu_2404_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# ============== VPC (public-only — cheapest possible) ==============
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.house_name}-vpc"
  cidr = var.vpc_cidr

  azs            = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 3)]

  enable_nat_gateway = false
  create_igw         = true

  tags = {
    House = var.house_name
    IaC   = "Terraform"
  }
}

# ============== Security Group (Tailscale only) ==============
resource "aws_security_group" "subnet_router" {
  name        = "${var.house_name}-subnet-router-sg"
  description = "Tailscale only (zero public ports except required UDP)"
  vpc_id      = module.vpc.vpc_id

  # Tailscale (required for direct connections)
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

# ============== Single EC2: Tailscale Subnet Router + Actual Budget ==============
resource "aws_instance" "subnet_router" {
  ami           = data.aws_ssm_parameter.ubuntu_2404_arm64.value
  instance_type = "t4g.nano"
  subnet_id     = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.subnet_router.id]
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  user_data = <<-EOF
    #!/bin/bash -ex

    # === System update ===
    apt-get update -y
    apt-get upgrade -y

    # === Tailscale (installed first) ===
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

    # === Docker (official method for Ubuntu 24.04 ARM64) ===
    apt-get install -y ca-certificates curl gnupg lsb-release
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker

    # === Actual Budget ===
    mkdir -p /opt/actualbudget/data
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

# ============== IAM for SSM ==============
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

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
