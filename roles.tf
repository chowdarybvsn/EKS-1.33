
# ========== IAM Policy for Cluster Autoscaler ==========
resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "AmazonEKSClusterAutoscalerPolicy"
  description = "Permissions for Kubernetes Cluster Autoscaler to manage ASGs / NodeGroups"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeLaunchTemplateVersions"
        ],
        Resource = "*"
      }
    ]
  })
}

# ========== IAM Role for Cluster Autoscaler (IRSA) ==========
resource "aws_iam_role" "cluster_autoscaler" {
  name = "AmazonEKSClusterAutoscalerRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = {
          Federated = module.eks.oidc_provider_arn
        },
        Action    = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            # audience must be sts.amazonaws.com
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com",
            # bind specifically to kube-system/cluster-autoscaler SA
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          }
        }
      }
    ]
  })
}

# Attach the autoscaler policy to the role
resource "aws_iam_role_policy_attachment" "cluster_autoscaler_attach" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}


# Ensure your kubernetes provider is configured to point to the EKS cluster

resource "kubernetes_service_account" "cluster_autoscaler" {
  metadata {
    name      = "cluster-autoscaler"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
    }
  }
}
