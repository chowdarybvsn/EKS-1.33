data "aws_ami" "eks_worker" {
  most_recent = true
  owners      = ["602401143452"] # Amazon EKS AMI owner

  filter {
    name   = "name"
    values = ["amazon-eks-node-1.32-v*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_launch_template" "self_managed_lt" {
  name_prefix   = "eks-self-managed-133-"
  image_id      = data.aws_ami.eks_worker.id
  instance_type = "t3.large"

  user_data = base64encode(<<EOF
  Content-Type: multipart/mixed; boundary="==MYBOUNDARY=="
  MIME-Version: 1.0

  --==MYBOUNDARY==
  Content-Type: text/x-shellscript; charset="us-ascii"

  #!/bin/bash
  /opt/nodeadm bootstrap \
    --container-runtime containerd \
    --kubelet-extra-args "--node-labels=eks.amazonaws.com/nodegroup=self-managed" \
    --kubelet-extra-args "--max-pods=110"

  --==MYBOUNDARY==--
  EOF
  )

  vpc_security_group_ids = [aws_security_group.eks_worker_sg.id]
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-worker"
    }
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
}

resource "aws_security_group" "eks_worker_sg" {
  name        = "${var.cluster_name}-worker-sg"
  description = "Security group for EKS self-managed worker nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow nodes to communicate with each other"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow worker to EKS control plane"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Or restrict to EKS API CIDRs
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-worker-sg"
    Environment = "dev"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0.0"

  name    = var.cluster_name
  kubernetes_version = "1.33"
  subnet_ids      = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

  enable_irsa = true
  authentication_mode = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true
  endpoint_public_access  = true
  endpoint_private_access = false
  
  access_entries = {
    my_new_role = {
      principal_arn = "arn:aws:iam::384570460850:role/RIDY_EKS"
      type         = "STANDARD"
      username     = "my-new-role-user"
      groups       = ["system:masters"]  # gives cluster-admin access
      policy_associations  = {}
    }
  }

  self_managed_node_groups = {
    default = {
      name_prefix   = "self-mng"
      desired_size  = var.desired_size
      min_size      = 1
      max_size      = 5
      subnet_ids    = module.vpc.private_subnets
      instance_type = var.instance_type

      launch_template = {
        id      = aws_launch_template.self_managed_lt.id
        version = "$Latest"
      }

      tags = {
        Name = "self-managed-eks-node"
      }
    }
  }
}

resource "null_resource" "wait_for_eks" {
  depends_on = [module.eks]

  provisioner "local-exec" {
    command = <<EOT
      echo "Waiting for EKS cluster to become ACTIVE..."
      for i in {1..30}; do
        STATUS=$(aws eks describe-cluster --name ${var.cluster_name} --region us-east-1 --query "cluster.status" --output text)
        if [ "$STATUS" == "ACTIVE" ]; then
          echo "Cluster is ACTIVE."
          exit 0
        fi
        echo "Cluster status: $STATUS. Retrying in 20s..."
        sleep 20
      done
      echo "Cluster did not become ACTIVE in time."
      exit 1
    EOT
  }
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name      = module.eks.cluster_name
  addon_name        = "vpc-cni"
  depends_on        = [null_resource.wait_for_eks]
}

resource "aws_eks_addon" "coredns" {
  cluster_name      = module.eks.cluster_name
  addon_name        = "coredns"
  depends_on        = [null_resource.wait_for_eks]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name            = module.eks.cluster_name
  addon_name              = "aws-ebs-csi-driver"
  addon_version           = "v1.53.0-eksbuild.1"    # or omit to use the latest compatible
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
  depends_on = [
        aws_iam_role.ebs_csi_driver       # ensure policy attached
    ]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name      = module.eks.cluster_name
  addon_name        = "kube-proxy"
  depends_on        = [null_resource.wait_for_eks]
}

resource "aws_iam_role" "ebs_csi_driver" {
  name = "AmazonEBSCSIDriverRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com",
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver_attach" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
