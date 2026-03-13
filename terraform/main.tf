# ============== Latest Ubuntu 24.04 ARM64 AMI ==============
data "aws_ssm_parameter" "ubuntu_2404_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

data "aws_caller_identity" "current" {}

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

  tags = {
    Name  = "${var.house_name}-actualbudget-data"
    House = var.house_name
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "actual_data_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.actual_data.id
  instance_id = aws_instance.subnet_router.id

  stop_instance_before_detaching = true
}

# ============== IAM Role for SSM + S3 Backups ==============
resource "aws_iam_role" "ssm_role" {
  name = "${var.house_name}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "s3_backup" {
  name = "${var.house_name}-s3-backup"
  role = aws_iam_role.ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "arn:aws:s3:::${var.backup_bucket_name}/*"
    }]
  })
}

resource "aws_iam_role_policy" "ssm_parameters" {
  name = "${var.house_name}-ssm-parameters"
  role = aws_iam_role.ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/homelab/${var.house_name}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.house_name}-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# ============== EC2 Instance ==============
resource "aws_instance" "subnet_router" {
  ami                         = data.aws_ssm_parameter.ubuntu_2404_arm64.value
  instance_type               = "t4g.nano"
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.subnet_router.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted             = true
    delete_on_termination = true
    volume_type           = "gp3"
    volume_size           = 8
  }

  user_data = templatefile("${path.module}/scripts/user-data.sh.tpl", {
    house_name         = var.house_name
    vpc_cidr           = var.vpc_cidr
    backup_bucket_name = var.backup_bucket_name
  })

  user_data_replace_on_change = true

  tags = {
    Name  = "${var.house_name}-subnet-router"
    House = var.house_name
  }
}
