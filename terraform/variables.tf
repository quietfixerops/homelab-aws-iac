variable "aws_region" {
  default = "us-east-1"
}

variable "house_name" {
  default = "5marionct"
}

variable "vpc_cidr" {
  default = "10.10.0.0/16"
}

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}

variable "telegram_bot_token" {
  type      = string
  sensitive = true
}