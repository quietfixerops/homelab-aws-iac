output "subnet_router_private_ip" {
  value = aws_instance.subnet_router.private_ip
}

output "subnet_router_public_ip" {
  value = aws_instance.subnet_router.public_ip
}