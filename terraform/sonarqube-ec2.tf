# =============================================================================
# SELF-HOSTED SONARQUBE (EC2)
#
# Alternative to SonarCloud -- a small EC2 instance running SonarQube in
# Docker, with an Elastic IP so the address never changes across reboots.
# GitHub Actions (a public cloud runner) can reach this over the internet,
# same as it would reach SonarCloud -- no tunnel (ngrok) needed, and no
# SonarCloud account/project-creation quirks to fight with.
#
# COST NOTE: this runs 24/7 unless you stop it. SonarQube needs at least
# 2GB RAM to run reliably -- t3.medium (4GB) below is NOT Free Tier
# eligible. Stop the instance when you're not actively using CI
# (`aws ec2 stop-instances`) to avoid paying for idle time.
#
# SECURITY NOTE: port 9000 is opened to 0.0.0.0/0 below so GitHub's cloud
# runners (whose IP ranges change constantly and aren't practical to
# allowlist) can reach it. This means anyone on the internet can also reach
# your SonarQube login page -- mitigated by: (1) you change the default
# admin password immediately on first login, (2) SonarQube itself requires
# auth for everything except the login page, (3) this is a portfolio/dev
# setup, not handling real proprietary code. Don't reuse this pattern for
# anything with actual sensitive source code without tightening it further.
# =============================================================================

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "sonarqube_sg" {
  name        = "${var.project_name}-sonarqube-sg"
  description = "Allow SonarQube UI/API on 9000, SSH for troubleshooting"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SonarQube web UI/API -- needs to be reachable from GitHub Actions runners"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH for troubleshooting -- narrow this to your own IP if you can"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "sonarqube" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.medium" # SonarQube needs >=2GB RAM; t3.medium (4GB) is a safe minimum
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.sonarqube_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.sonarqube_ssm_profile.name

  # SonarQube's embedded Elasticsearch needs this bumped from the Linux
  # default, or the container crash-loops on boot.
  user_data = <<-EOF
    #!/bin/bash
    sysctl -w vm.max_map_count=262144
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    dnf install -y docker
    systemctl enable --now docker
    docker run -d --name sonarqube --restart unless-stopped \
      -p 9000:9000 sonarqube:community
  EOF

  tags = { Name = "${var.project_name}-sonarqube" }
}

resource "aws_eip" "sonarqube_eip" {
  instance = aws_instance.sonarqube.id
  domain   = "vpc"
}

# SSM access instead of relying purely on the SSH key -- lets you get a
# shell even if you lose the key pair.
resource "aws_iam_role" "sonarqube_ssm_role" {
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

resource "aws_iam_role_policy_attachment" "sonarqube_ssm_attach" {
  role       = aws_iam_role.sonarqube_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "sonarqube_ssm_profile" {
  name = "${var.project_name}-sonarqube-ssm-profile"
  role = aws_iam_role.sonarqube_ssm_role.name
}

output "sonarqube_url" {
  value = "http://${aws_eip.sonarqube_eip.public_ip}:9000"
}
