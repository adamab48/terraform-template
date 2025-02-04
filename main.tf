provider "aws" {
  region = local.region
}

locals {
  region = "eu-west-1"
  name   = "my-infrastructure"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }


}

data "aws_availability_zones" "available" {}

resource "aws_key_pair" "deployer" {
  key_name   = "deployer-key"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIfcwWWSNU5pQH3SSgsm6vpJccQlWKqWC5W3dL03prQW dell xps@DESKTOP-1U3A5PU"
}

# VPC Module
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

# Security Groups
module "app_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-app"
  description = "Security group for App and DB instances"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "SSH from VPC"
      cidr_blocks = local.vpc_cidr
    }
  ]

  egress_rules = ["all-all"]

  tags = local.tags
}

module "frontend_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-frontend"
  description = "Security group for frontend instance"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP from internet"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "SSH from internet"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "HTTPS from internet"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  egress_rules = ["all-all"]

  tags = local.tags
}

# EC2 Instances
locals {
  instances = {
    db = {
      instance_type     = "t3.small"
      subnet_id         = element(module.vpc.private_subnets, 0)
      security_group_id = module.app_sg.security_group_id
      user_data         = <<-EOT
        #!/bin/bash
        sudo apt update -y &&
        sudo apt install -y mysql-server
        EOT
    },
    app = {
      instance_type     = "t3.small"
      subnet_id         = element(module.vpc.private_subnets, 1)
      security_group_id = module.app_sg.security_group_id
      user_data         = <<-EOT
        #!/bin/bash
        echo "HERE IS THE APP DEPS INSTALLATION (backend ?? node ??)"
        EOT
    },
    frontend = {
      instance_type     = "t3.small"
      subnet_id         = element(module.vpc.public_subnets, 0)
      security_group_id = module.frontend_sg.security_group_id
      user_data         = <<-EOT
    #!/bin/bash
    sudo apt update -y &&
    sudo apt install -y nginx
    # Here you would put the "dist" folder of your frontend app (after building it)
    echo "Hello World" > /var/www/html/index.html
  EOT

    }
  }
}

module "ec2_instances" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "5.7.1"

  for_each = local.instances

  name                        = "${local.name}-${each.key}"
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = each.value.instance_type
  subnet_id                   = each.value.subnet_id
  vpc_security_group_ids      = [each.value.security_group_id]
  key_name                    = aws_key_pair.deployer.key_name
  associate_public_ip_address = each.key == "frontend"
  user_data_base64            = base64encode(each.value.user_data)
  user_data_replace_on_change = true
  enable_volume_tags          = false
  root_block_device = [
    {
      encrypted   = true
      volume_type = "gp3"
      volume_size = 20
    }
  ]

  tags = merge(local.tags, {
    Name = "${local.name}-${each.key}"
  })
}

# Data source for AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# Outputs
output "frontend_public_ip" {
  description = "Public IP address of the frontend instance"
  value       = module.ec2_instances["frontend"].public_ip
}

output "private_instance_ips" {
  description = "Private IP addresses of the App and DB instances"
  value = {
    for k, v in module.ec2_instances : k => v.private_ip if k != "frontend"
  }
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "subnets" {
  description = "List of subnet IDs"
  value       = module.vpc.private_subnets
}
