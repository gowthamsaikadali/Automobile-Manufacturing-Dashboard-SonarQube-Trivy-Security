# =============================================================================
# SECRETS MANAGER
# Every credential the app needs lives here, encrypted with a dedicated KMS
# key. Terraform generates the DB password itself so it never passes through
# your shell history or a .tfvars file.
# =============================================================================

resource "aws_kms_key" "secrets_key" {
  description             = "${var.project_name} secrets encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "secrets_key_alias" {
  name          = "alias/${var.project_name}-secrets"
  target_key_id = aws_kms_key.secrets_key.key_id
}

resource "random_password" "db_password" {
  length            = 24
  special           = true
  override_special  = "!#$%^&*()-_=+[]{}<>:?" # RDS-safe special chars
}

resource "random_password" "flask_secret_key" {
  length  = 48
  special = false
}

resource "random_password" "admin_password" {
  length           = 16
  special          = true
  override_special = "!#$%^&*"
}

resource "aws_secretsmanager_secret" "app_secrets" {
  name                    = "${var.project_name}/app-credentials"
  kms_key_id              = aws_kms_key.secrets_key.arn
  recovery_window_in_days = 0 # purge immediately on destroy -- avoids the "already scheduled for deletion" conflict on rebuild cycles

  tags = { Project = var.project_name }
}

resource "aws_secretsmanager_secret_version" "app_secrets_version" {
  secret_id = aws_secretsmanager_secret.app_secrets.id
  secret_string = jsonencode({
    DB_HOST          = aws_db_instance.app_db.address
    DB_PORT          = "3306"
    DB_USER          = var.db_username
    DB_PASSWORD      = random_password.db_password.result
    DB_NAME          = var.db_name
    FLASK_SECRET_KEY = random_password.flask_secret_key.result
    ADMIN_USERNAME   = var.admin_username
    ADMIN_PASSWORD   = random_password.admin_password.result
  })
}

# IRSA role that the External Secrets Operator's ServiceAccount assumes so
# it -- and only it -- can read this one secret.
resource "aws_iam_role" "external_secrets_irsa" {
  name = "${var.project_name}-external-secrets-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:external-secrets:external-secrets-sa"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "external_secrets_read_only" {
  name = "${var.project_name}-external-secrets-read"
  role = aws_iam_role.external_secrets_irsa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_secretsmanager_secret.app_secrets.arn
      },
      {
        # Required in addition to the above -- the secret is encrypted with
        # a customer-managed KMS key (not the AWS-managed default), so
        # reading its VALUE (not just metadata) needs an explicit Decrypt
        # grant on that key too.
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.secrets_key.arn
      }
    ]
  })
}

output "app_secrets_arn" {
  value = aws_secretsmanager_secret.app_secrets.arn
}

output "external_secrets_irsa_role_arn" {
  value = aws_iam_role.external_secrets_irsa.arn
}
