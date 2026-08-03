module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.project_name
  cluster_version = var.eks_cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true # keep true for kubectl-from-laptop access during a portfolio project

  # Grants YOUR terraform-apply identity admin automatically, plus anyone
  # listed in additional_admin_arns -- this is what avoids the "console
  # login can't see the cluster" issue from earlier iterations.
  authentication_mode = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  access_entries = merge(
    {
      for idx, arn in var.additional_admin_arns : "admin-${idx}" => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      # Lets the CI/CD role deploy (kubectl set image / apply) inside the
      # app namespace only -- IAM alone only grants DescribeCluster; this is
      # what actually authorizes it inside the Kubernetes API.
      cicd = {
        principal_arn = aws_iam_role.cicd_role.arn
        policy_associations = {
          edit = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = {
              type       = "namespace"
              namespaces = ["automobile-app"]
            }
          }
        }
      }
    }
  )

  cluster_addons = {
    coredns                = {}
    kube-proxy              = {}
    vpc-cni = {
      configuration_values = jsonencode({
        env = { ENABLE_NETWORK_POLICY = "true" } # required for k8s/networkpolicy.yaml to actually be enforced
      })
    }
    aws-ebs-csi-driver = {
      service_account_role_arn = aws_iam_role.ebs_csi_irsa.arn
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.eks_node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Use the least-privilege role from iam-least-privilege.tf instead of
      # letting the module create its own broad default role.
      create_iam_role = false
      iam_role_arn    = aws_iam_role.eks_node_role.arn
    }
  }
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}
