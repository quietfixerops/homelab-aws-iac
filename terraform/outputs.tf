# ============== Outputs ==============
output "subnet_router_public_ip" {
  value       = aws_instance.subnet_router.public_ip
  description = "Public IP of the Tailscale subnet router"
}

output "subnet_router_private_ip" {
  value       = aws_instance.subnet_router.private_ip
  description = "Private IP (use this in Tailscale to reach ActualBudget)"
}

output "backup_bucket" {
  value       = var.backup_bucket_name
  description = "S3 bucket used for daily backups"
}
