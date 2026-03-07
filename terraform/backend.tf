terraform {
  backend "s3" {
    bucket         = "tfstate-083636778104"
    key            = "5marionct/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tfstate-lock"
    encrypt        = true
  }
}
