# locals.tf
locals {
  # #####################
  # Project Metadata
  # #####################
  project_name = "gitops-vm"
  github_owner = "simonangel-fong"
  github_repo  = "runbook-ansible-gitops-vm"

  # #####################
  # AWS
  # #####################
  aws_region = "ca-central-1"

  # #####################
  # Network
  # #####################
  subnet_vpc_cidr = "10.0.0.0/16"

  # DMZ subnet
  subnet_dmz_cidr = "10.0.10.0/24"
  ec2_lb_cidr     = "10.0.10.20"

  # App subnet
  subnet_app_cidr  = "10.0.20.0/24"
  ec2_app_vm1_cidr = "10.0.20.11"
  ec2_app_vm2_cidr = "10.0.20.12"

  # mgmt subnet
  subnet_mgmt_cidr = "10.0.90.0/24"
  ec2_jump_cidr    = "10.0.90.10"
  ec2_mon_cidr     = "10.0.90.20"
}
