# ec2_jump.tf

# ##############################
# AMI
# ##############################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name = "name"
    # Ubuntu 24.04 LTS (Noble), Canonical-owned, gp3 root volume.
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
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
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.mgmt.id
  private_ip             = local.ec2_jump_cidr
  vpc_security_group_ids = [aws_security_group.jump.id]
  key_name               = aws_key_pair.fleet.key_name

  user_data = templatefile("${path.module}/cloud-init/jump.yaml.tftpl", {
    project_name          = local.project_name
    github_owner          = local.github_owner
    github_repo           = local.github_repo
    fleet_private_key_b64 = base64encode(tls_private_key.fleet.private_key_pem)
    jump_private_ip       = local.ec2_jump_cidr
    lb_private_ip         = aws_instance.lb.private_ip
    app_vm1_private_ip    = aws_instance.app_vm1.private_ip
    app_vm2_private_ip    = aws_instance.app_vm2.private_ip
    mon_private_ip        = aws_instance.mon.private_ip
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
