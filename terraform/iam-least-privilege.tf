# =============================================================================
# IAM LEAST-PRIVILEGE
# Three separate roles, each scoped to exactly what that identity needs.
# Never attach AdministratorAccess or PowerUserAccess anywhere in this file.
# =============================================================================

# ---------------------------------------------------------------- EKS nodes -
# Nodes only need: pull images from ECR, mount EBS volumes, write CloudWatch
# logs, and register with the cluster. NOT full ECR or EC2 access.
resource "aws_iam_role" "eks_node_role" {
  name = "${var.project_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Read-only ECR pull instead of the broader EC2ContainerRegistryFullAccess
resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "node_ebs_csi_minimal" {
  name = "${var.project_name}-node-ebs-minimal"
  role = aws_iam_role.eks_node_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:DescribeVolumes",
        "ec2:DescribeInstances",
        "ec2:DescribeAvailabilityZones"
      ]
      Resource = "*"
    }]
  })
}

# ----------------------------------------------------------------- EC2 role -
# Only used for any bastion/utility EC2 instance -- scoped to SSM session
# access only, no direct SSH keys, no broad S3/EC2 permissions.
resource "aws_iam_role" "ec2_bastion_role" {
  name = "${var.project_name}-ec2-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.ec2_bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_bastion_profile" {
  name = "${var.project_name}-ec2-bastion-profile"
  role = aws_iam_role.ec2_bastion_role.name
}

# ------------------------------------------------------------------ CI/CD ---
# GitHub Actions assumes this role via OIDC federation (no long-lived AWS
# keys stored in GitHub secrets). Scoped to exactly: push to this app's ECR
# repo, and deploy to this specific EKS cluster.
data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "cicd_role" {
  name = "${var.project_name}-cicd-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Restrict to your specific repo + branch -- replace with your own.
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cicd_ecr_push" {
  name = "${var.project_name}-cicd-ecr-push"
  role = aws_iam_role.cicd_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage"
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "cicd_eks_deploy" {
  name = "${var.project_name}-cicd-eks-deploy"
  role = aws_iam_role.cicd_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.project_name}*"
    }]
  })
}

variable "github_org" {
  description = "GitHub org/user that owns this repo (for OIDC trust condition)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repo name (for OIDC trust condition)"
  type        = string
}
