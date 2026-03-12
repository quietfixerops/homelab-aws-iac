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

variable "backup_bucket_name" {
  description = "Name of the S3 backup bucket"
  type        = string
  default     = "backups-083636778104"
}
