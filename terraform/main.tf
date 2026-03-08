# Latest Ubuntu 24.04 LTS ARM64 AMI (official Canonical)
data "aws_ssm_parameter" "ubuntu_2404_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# ============== VPC ==============
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.house_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = [cidrsubnet(var.vpc_cidr, 4, 1), cidrsubnet(var.vpc_cidr, 4, 2)]
  public_subnets  = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 3)]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  tags = {
    House = var.house_name
    IaC   = "Terraform"
  }
}

# ============== Security Group ==============
resource "aws_security_group" "subnet_router" {
  name        = "${var.house_name}-subnet-router-sg"
  description = "Tailscale subnet router"
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

# ============== Tailscale Subnet Router EC2 (Ubuntu 24.04) ==============
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
    curl -fsSL https://tailscale.com/install.sh | sh

    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
    sysctl -p

    # Join Tailscale (robust key handling)
    tailscale up \
      --authkey="${var.tailscale_auth_key}" \
      --hostname=${var.house_name}-subnet-router \
      --advertise-routes=${var.vpc_cidr} \
      --advertise-tags=tag:infra-router \
      --accept-routes \
      --accept-dns=false

    tailscale set --advertise-exit-node=false
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
