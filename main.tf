# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

provider "aws" {
  region = var.region
}

# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = "viet-vpc"

  cidr = "10.49.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 1)

  private_subnets = ["10.49.53.0/24"]
  public_subnets  = ["10.49.54.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.19.0"

  name = var.cluster_name
  kubernetes_version = "1.35"

  endpoint_public_access = true
  endpoint_public_access_cidrs = ["171.224.177.142/32"]
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t4g.nano"]
      ami_type = "AL2_ARM_64"
      capacity_type = "SPOT"

      min_size     = 1
      max_size     = 1
      desired_size = 1
    }
  }
  
  service_ipv4_cidr = "10.53.49.0/24"

}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
  depends_on               = [module.eks]
}


# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/ 
data "aws_iam_policy" "ebs_csi_policy" {
  # arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  arn = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCRole-${var.cluster_name}"
  provider_url                  = module.eks.oidc_provider_url
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}
