# ansible_inventory.tf

# ##############################
# Ansible Inventory: Dynamically created based on TF
# ##############################
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"

  content = <<-EOT
    [jumps]
    jump ansible_host=${aws_instance.jump.private_ip}

    [lbs]
    lb ansible_host=${aws_instance.lb.private_ip}

    [app_canary]
    app-vm1 ansible_host=${aws_instance.app_vm1.private_ip}

    [app_stable]
    app-vm2 ansible_host=${aws_instance.app_vm2.private_ip}

    [apps:children]
    app_canary
    app_stable

    [mons]
    mon ansible_host=${aws_instance.mon.private_ip}

    [fleet:children]
    lbs
    apps
    mons

    [all:vars]
    ansible_user=ubuntu
    ansible_ssh_private_key_file=~/.ssh/${local.project_name}.pem
    ansible_ssh_common_args=-o StrictHostKeyChecking=accept-new
    ansible_python_interpreter=/usr/bin/python3
  EOT
}
