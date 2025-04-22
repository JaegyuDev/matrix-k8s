# AWS EKS Terraform Configuration for Matrix Synapse
# For a small user base (<10 users)

provider "aws" {
  region = "us-west-2"  # Change to your preferred region
}

# Use this to store Terraform state remotely (recommended)
terraform {
  backend "s3" {
    bucket = "jaegyu-terraform-state"
    key    = "matrix-synapse/terraform.tfstate"
    region = "us-west-2"
  }
}

# VPC Configuration
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "matrix-synapse-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-west-2a", "us-west-2b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true  # Cost-saving for small deployments
  enable_dns_hostnames = true

  tags = {
    Environment = "production"
    Project     = "matrix-synapse"
  }
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "matrix-synapse"
  cluster_version = "1.29"  # Update to latest stable version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # For a small setup, one managed node group is sufficient
  eks_managed_node_groups = {
    general = {
      desired_size = 2
      min_size     = 1
      max_size     = 3

      instance_types = ["t3.medium"]  # Good balance for small workloads
      capacity_type  = "ON_DEMAND"

      disk_size = 20

      labels = {
        role = "general"
      }

      tags = {
        ExtraTag = "matrix-synapse"
      }
    }
  }

  tags = {
    Environment = "production"
    Project     = "matrix-synapse"
  }
}

# Create an IAM policy for EKS cluster autoscaler
resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "eks-cluster-autoscaler"
  description = "EKS cluster autoscaler policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeLaunchTemplateVersions"
        ]
        Resource = "*"
        Effect   = "Allow"
      }
    ]
  })
}

# Create an IAM role for EBS CSI driver
module "ebs_csi_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name             = "ebs-csi-controller"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# Route53 record for Matrix server
resource "aws_route53_zone" "primary" {
  name = "jaegyu.dev"
}

resource "aws_route53_record" "matrix" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "jaegyu.dev"
  type    = "A"

  alias {
    name                   = module.eks_ingress_nginx.load_balancer_hostname
    zone_id                = module.eks_ingress_nginx.load_balancer_zone_id
    evaluate_target_health = true
  }
}

# NGINX Ingress Controller
module "eks_ingress_nginx" {
  source  = "terraform-iaac/nginx-ingress-controller/kubernetes"
  version = "~> 1.0"

  # Use the EKS cluster's authentication to deploy resources
  depends_on = [module.eks]
}

# Outputs
output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "load_balancer_hostname" {
  description = "Hostname of the load balancer for the ingress controller"
  value       = module.eks_ingress_nginx.load_balancer_hostname
}