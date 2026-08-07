# =============================================================================
# SonarQube on EC2 -- self-hosted static analysis server for the CI pipeline.
#
# WHY THE PREVIOUS EC2 ATTEMPT FAILED (root causes, all fixed below):
#  1. "SonarQube not listening on 9000" -- SonarQube bundles Elasticsearch,
#     which refuses to start unless vm.max_map_count >= 262144 and the file
#     descriptor/process ulimits are raised FIRST. Without that, the
#     container exits seconds after starting and nothing ever binds to 9000.
#     Fixed by: sysctl + limits.d set at boot, PLUS
#     SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true as a safety net.
#  2. "Test-NetConnection to 9000 fails / browser can't connect" -- the
#     instance either had no public IP, sat in a subnet with no route to an
#     Internet Gateway, or the security group never actually opened 9000.
#     Fixed by: launching in the VPC module's PUBLIC subnet with
#     associate_public_ip_address = true, and a dedicated SG with an
#     explicit 9000 ingress rule.
#  3. "SSM cannot connect to the instance" -- the instance had no IAM
#     instance profile (or one without AmazonSSMManagedInstanceCore), so the
#     SSM agent had no permissions to register with Systems Manager, even
#     though it ships pre-installed on Amazon Linux 2023.
#     Fixed by: dedicated IAM role + instance profile below.
#
# You reach SonarQube's UI over the internet on port 9000, and you reach the
# instance itself (for troubleshooting) via SSM Session Manager -- no SSH
# key pair and no port 22 needed anywhere.
# =============================================================================

# Latest Amazon Linux 2023 AMI, resolved automatically -- no hardcoded/stale AMI IDs.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "sonarqube" {
  name_prefix = "${var.project_name}-sonarqube-"
  description = "SonarQube EC2 -- inbound 9000 for the web UI/API, all outbound for Docker Hub pulls"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SonarQube web UI/API"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = var.sonarqube_allowed_cidrs
  }

  egress {
    description = "All outbound (docker pull, SSM, package updates)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sonarqube-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "sonarqube_ssm" {
  name = "${var.project_name}-sonarqube-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# This single managed policy is what makes SSM Session Manager (and
# `aws ssm start-session`) work at all -- this is the piece that was
# missing before, which is why SSM couldn't connect.
resource "aws_iam_role_policy_attachment" "sonarqube_ssm_core" {
  role       = aws_iam_role.sonarqube_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "sonarqube" {
  name = "${var.project_name}-sonarqube-profile"
  role = aws_iam_role.sonarqube_ssm.name
}

resource "aws_instance" "sonarqube" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.sonarqube_instance_type
  subnet_id                   = module.vpc.public_subnets[0] # PUBLIC subnet -- required for a routable public IP
  vpc_security_group_ids      = [aws_security_group.sonarqube.id]
  iam_instance_profile        = aws_iam_instance_profile.sonarqube.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20 # SonarQube + its Elasticsearch index need more than the 8GB default
    volume_type = "gp3"
  }

  # Every command here logs to /var/log/user-data.log on the instance --
  # if something ever goes wrong again, that log is the first place to look
  # (see README troubleshooting section for the SSM command to read it).
  user_data = <<-EOF
    #!/bin/bash
    set -x
    exec > /var/log/user-data.log 2>&1

    # --- 1. Kernel/ulimit prerequisites Elasticsearch (bundled in SonarQube) requires ---
    cat <<'SYSCTL' > /etc/sysctl.d/99-sonarqube.conf
    vm.max_map_count=262144
    fs.file-max=65536
    SYSCTL
    sysctl --system

    cat <<'LIMITS' > /etc/security/limits.d/99-sonarqube.conf
    * soft nofile 65536
    * hard nofile 65536
    * soft nproc 4096
    * hard nproc 4096
    LIMITS

    # --- 2. Docker ---
    dnf update -y
    dnf install -y docker
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ec2-user

    # --- 3. SonarQube (Community Edition) ---
    # SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true is a safety net in case the
    # sysctl settings above haven't fully propagated to the container's
    # namespace by the time it starts -- without it, a slow boot can still
    # crash-loop Elasticsearch even with the correct host settings.
    docker run -d \
      --name sonarqube \
      --restart unless-stopped \
      -p 9000:9000 \
      -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
      --ulimit nofile=65536:65536 \
      --ulimit nproc=4096:4096 \
      sonarqube:community

    # --- 4. Wait and confirm (visible in /var/log/user-data.log) ---
    for i in $(seq 1 30); do
      if curl -sf http://localhost:9000/api/system/status | grep -q '"status":"UP"'; then
        echo "SonarQube is UP after $((i * 10))s"
        break
      fi
      echo "Waiting for SonarQube... attempt $i"
      sleep 10
    done
    docker ps
  EOF

  tags = { Name = "${var.project_name}-sonarqube" }
}

output "sonarqube_public_ip" {
  description = "Public IP of the SonarQube EC2 instance"
  value       = aws_instance.sonarqube.public_ip
}

output "sonarqube_url" {
  description = "SonarQube URL -- set this as the SONAR_HOST_URL GitHub secret"
  value       = "http://${aws_instance.sonarqube.public_ip}:9000"
}

output "sonarqube_instance_id" {
  description = "Instance ID -- use with `aws ssm start-session --target <id>` for troubleshooting"
  value       = aws_instance.sonarqube.id
}
