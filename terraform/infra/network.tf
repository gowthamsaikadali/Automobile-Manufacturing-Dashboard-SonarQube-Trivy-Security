# Builds the VPC from scratch - you have none of this yet.
#
# Cost-conscious design: EKS worker nodes go in PUBLIC subnets with public
# IPs (so they can reach the internet/ECR/Secrets Manager without paying
# for a NAT Gateway, ~$32/mo saved). Worker nodes are still protected by
# the EKS cluster's shared security group (see eks.tf's eks_cluster_sg -
# only outbound is open by default, nothing unsolicited gets in). RDS
# sits in PRIVATE subnets with NO internet route at all - it never needs one.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name                                = "${var.project}-vpc"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# ---- Public subnets (EKS nodes + ALB) ----
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                             = "${var.project}-public-${count.index}"
    "kubernetes.io/cluster/${var.eks_cluster_name}"  = "shared"
    "kubernetes.io/role/elb"                         = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---- Private subnets (RDS only - no internet route, no NAT needed) ----
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.${10 + count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project}-private-${count.index}"
  }
}

# Local-only route table (no 0.0.0.0/0 route = no internet, which is fine,
# RDS never needs outbound internet access).
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
