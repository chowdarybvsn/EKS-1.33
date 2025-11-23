variable "region" {
  default = "us-east-1"
}

variable "cluster_name" {
  default = "eks-133"
}

variable "desired_size" {
  default = 5
}

variable "instance_type" {
  default = "t3.micro"
}

variable "tfstate_bucket" {
    default = ""
}

variable "worker_instance_profile_name" {
  type        = string
  description = "IAM instance profile name for worker nodes"
  default     = null
}
