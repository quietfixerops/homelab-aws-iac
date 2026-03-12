# Homelab AWS IaC — Tailscale Subnet Router + ActualBudget

This Terraform repo deploys a **minimal, ultra-low-cost** Tailscale subnet router on AWS that runs a self-hosted **[Actual Budget](https://actualbudget.org/)** personal finance app.

Everything runs on a single `t4g.nano` ARM instance (~$3–5/month total).

## Features
- Always-on Tailscale subnet router (advertises your VPC CIDR)
- ActualBudget in Docker with persistent encrypted EBS volume
- Watchtower auto-updates + Telegram notifications
- Daily automated backups to S3 (STANDARD_IA) + Telegram alert
- Least-privilege IAM + SSM Parameter Store for secrets (no secrets in Terraform state or EC2 logs)
- Remote S3 backend with state locking
- GitHub Actions OIDC CI/CD

## Architecture
```mermaid
graph TD
    A[Internet] --> B(Tailscale)
    B --> C[t4g.nano EC2<br/>Ubuntu 24.04 ARM]
    C --> D[ActualBudget Docker<br/>port 5006]
    C --> E[10GB EBS Volume]
    E --> F[Daily S3 Backup + Telegram]