# ec2_jump.tf

# AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
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

# ##############################
# SG
# ##############################
resource "aws_security_group" "jump" {
  name        = "${local.project_name}-sg-jump"
  description = "Jump host: SSH from admin CIDR only, all egress."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.project_name}-sg-jump"
  }
}

resource "aws_vpc_security_group_ingress_rule" "jump_ssh_from_admin" {
  security_group_id = aws_security_group.jump.id
  description       = "SSH from workstation admin CIDR."
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "jump_egress_all" {
  security_group_id = aws_security_group.jump.id
  description       = "All egress."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}


# ##############################
# EC2: Jump
# ##############################
resource "aws_instance" "jump" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.mgmt.id
  private_ip             = local.ec2_jump_cidr
  vpc_security_group_ids = [aws_security_group.jump.id]
  key_name               = aws_key_pair.fleet.key_name

  user_data = templatefile("${path.module}/cloud-init/jump.yaml.tftpl", {
    project_name           = local.project_name
    github_owner           = local.github_owner
    github_repo            = local.github_repo
    fleet_private_key_b64  = base64encode(tls_private_key.fleet.private_key_pem)
    jump_private_ip        = local.ec2_jump_cidr
    lb_private_ip          = aws_instance.lb.private_ip
    app_vm1_private_ip     = aws_instance.app_vm1.private_ip
    app_vm2_private_ip     = aws_instance.app_vm2.private_ip
  })

  # Replace the instance when the bootstrap script changes
  user_data_replace_on_change = true

  tags = {
    Name = "${local.project_name}-jump"
    Role = "jump"
  }
}

resource "aws_eip" "jump" {
  instance = aws_instance.jump.id
  domain   = "vpc"

  tags = {
    Name = "${local.project_name}-jump-eip"
  }
}
