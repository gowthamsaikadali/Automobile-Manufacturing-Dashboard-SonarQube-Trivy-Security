resource "random_password" "db_password" {
  length  = 24
  special = true
  # Exclude characters that break connection strings / shell quoting
  override_special = "!#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  name        = "${var.project}/rds/credentials"
  description = "AutoForge RDS MySQL master credentials - single source of truth for DB_HOST/DB_USER/DB_PASSWORD"
  kms_key_id  = aws_kms_key.secrets.arn
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.mysql.address
    port     = 3306
    dbname   = var.db_name
  })
}

resource "aws_secretsmanager_secret" "flask_secret_key" {
  name       = "${var.project}/app/flask-secret-key"
  kms_key_id = aws_kms_key.secrets.arn
}

resource "random_password" "flask_secret_key" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret_version" "flask_secret_key" {
  secret_id     = aws_secretsmanager_secret.flask_secret_key.id
  secret_string = random_password.flask_secret_key.result
}

resource "random_password" "admin_bootstrap" {
  length  = 20
  special = true
}

resource "aws_secretsmanager_secret" "admin_bootstrap" {
  name       = "${var.project}/app/admin-bootstrap"
  kms_key_id = aws_kms_key.secrets.arn
}

resource "aws_secretsmanager_secret_version" "admin_bootstrap" {
  secret_id     = aws_secretsmanager_secret.admin_bootstrap.id
  secret_string = jsonencode({ password = random_password.admin_bootstrap.result })
}

resource "aws_kms_key" "secrets" {
  description             = "CMK for AutoForge Secrets Manager secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}
