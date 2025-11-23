terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0.0"
    }
  }

    backend "s3" {
        bucket = "bucket-eks133"
        key    = "eks"
        region = "us-east-1"
        encrypt = true
    }
}    
provider "aws" {
  region = "us-east-1"
}
