resource "aws_db_subnet_group" "app_db_subnets" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds_sg" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow MySQL only from EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from EKS nodes"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "app_db" {
  identifier     = "${var.project_name}-db"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type       = "gp2" # gp3 is NOT Free Tier eligible on a new account -- gp2 is; see project history

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result # generated in secrets-manager.tf, never typed by hand

  db_subnet_group_name   = aws_db_subnet_group.app_db_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = false # deliberate -- only reachable from inside the cluster, see README Part 6 for how schema init runs

  multi_az                = false # single-AZ keeps cost down for a portfolio project; flip to true for real HA
  backup_retention_period = 0
  skip_final_snapshot     = true # avoids a stuck snapshot blocking teardown during iteration cycles
  deletion_protection     = false
}

output "db_instance_address" {
  value = aws_db_instance.app_db.address
}
