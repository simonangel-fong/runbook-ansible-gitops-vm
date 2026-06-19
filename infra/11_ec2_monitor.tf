# ec2_mon.tf

# ##############################
# SG
# ##############################
resource "aws_security_group" "mon" {
  name        = "${local.project_name}-sg-mon"
  description = "Monitoring host: SSH + Prometheus + Grafana from jump SG, egress VPC-only."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.project_name}-sg-mon"
  }
}

resource "aws_vpc_security_group_ingress_rule" "mon_ssh_from_jump" {
  security_group_id            = aws_security_group.mon.id
  description                  = "SSH from jump SG only (Ansible bootstrap)."
  referenced_security_group_id = aws_security_group.jump.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_ingress_rule" "mon_prometheus_from_jump" {
  security_group_id            = aws_security_group.mon.id
  description                  = "Prometheus UI from jump SG (SSH tunnel for debugging)."
  referenced_security_group_id = aws_security_group.jump.id
  ip_protocol                  = "tcp"
  from_port                    = 9090
  to_port                      = 9090
}

resource "aws_vpc_security_group_ingress_rule" "mon_grafana_from_jump" {
  security_group_id            = aws_security_group.mon.id
  description                  = "Grafana UI from jump SG (SSH tunnel - the actual demo signal)."
  referenced_security_group_id = aws_security_group.jump.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

resource "aws_vpc_security_group_egress_rule" "mon_egress_all" {
  security_group_id = aws_security_group.mon.id
  description       = "All egress - mon needs apt for Prometheus/Grafana install (same posture as jump)."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ##############################
# SG glue: allow monitor access app:8080 to scrape
# ##############################
resource "aws_vpc_security_group_ingress_rule" "app_8080_from_mon" {
  security_group_id            = aws_security_group.app.id
  description                  = "App /metrics scrape from mon SG (Prometheus)."
  referenced_security_group_id = aws_security_group.mon.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}


# ##############################
# EC2: Monitor
# ##############################
resource "aws_instance" "mon" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.mgmt.id
  private_ip             = local.ec2_mon_cidr
  vpc_security_group_ids = [aws_security_group.mon.id]
  key_name               = aws_key_pair.fleet.key_name

  tags = {
    Name = "${local.project_name}-mon"
    Role = "mon"
  }
}
