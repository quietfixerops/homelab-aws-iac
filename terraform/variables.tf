variable "aws_region" {
  default = "us-east-1"
}

variable "house_name" {
  description = "Name of this house (e.g. 5marionct, house2, etc.)"
  type        = string
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

variable "telegram_chat_id" {
  description = "Your Telegram chat ID for notifications"
  type        = string
  sensitive   = true
}
