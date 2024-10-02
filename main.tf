# Define the required provider
terraform {
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.0"
    }
  }
}

# Provider configuration
provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = true
}

provider "tls" {}

# Data source for vSphere components
data "vsphere_datacenter" "dc" {
  name = var.datacenter_name
}

data "vsphere_resource_pool" "pool" {
  name          = var.vsphere_resource_pool
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "datastore" {
  name          = var.datastore_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.vsphere_cluster_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.network_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

# SSH key generation for the cluster nodes
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Local variables
locals {
  subnet_prefix = substr(var.subnet_cidr, length(split("/", var.subnet_cidr)[0]) + 1, 2)  
  
  # The first IP is assigned to the main master
  main_master = {
    hostname   = "${var.cluster_name}-main-master"
    ip_address = element(var.master_ips, 0)  # Use the first IP in the list for the main master
  }

  # Additional master nodes from the second IP onward
  additional_master_map = {
    for idx, ip in slice(var.master_ips, 1, length(var.master_ips)) : "${var.cluster_name}-master-${idx + 1}" => {
      hostname   = "${var.cluster_name}-master-${idx + 1}"
      ip_address = ip
    }
  }

  # Worker nodes (mapped to their IPs)
  worker_map = {
    for idx, ip in var.worker_ips : "${var.cluster_name}-worker-${idx}" => {
      hostname   = "${var.cluster_name}-worker-${idx}"
      ip_address = ip
    }
  }
}



# Main Master VM
resource "vsphere_virtual_machine" "main_master" {
  name          = local.main_master.hostname
  datastore_id  = data.vsphere_datastore.datastore.id
  resource_pool_id = data.vsphere_resource_pool.pool.id
  num_cpus      = var.cpus
  memory        = var.memory
  guest_id      = data.vsphere_virtual_machine.template.guest_id
  scsi_type     = data.vsphere_virtual_machine.template.scsi_type
  firmware      = data.vsphere_virtual_machine.template.firmware
  
  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = "vmxnet3"
  }

  disk {
    label            = "disk0.vmdk"
    size             = var.disk_size
    unit_number      = 0
    thin_provisioned = false
  }

  clone {
    timeout       = "500"
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  extra_config = {
    "guestinfo.metadata" = base64encode(templatefile("${path.module}/meta-data.yaml", {
      hostname    = local.main_master.hostname
    }))
    "guestinfo.metadata.encoding" = "base64"
    "guestinfo.userdata" = base64encode(templatefile("${path.module}/user-data.sh", {
      cluster_cidr    = var.cluster_cidr
      vip_address     = var.vip_address
      hostname        = local.main_master.hostname,
      role            = "main_master",
      main_master     = local.main_master.ip_address,
      gateway         = var.gateway,
      dns             = "8.8.8.8",
      ip_address      = "${local.main_master.ip_address}/${local.subnet_prefix}",
      private_ssh_key = tls_private_key.ssh_key.private_key_pem,
      public_ssh_key  = tls_private_key.ssh_key.public_key_openssh
    }))
    "guestinfo.userdata.encoding" = "base64"
  }
}

# Additional Master VMs
resource "vsphere_virtual_machine" "master" {
  for_each       = length(var.master_ips) > 1 ? local.additional_master_map : {}
  name           = each.value.hostname
  datastore_id   = data.vsphere_datastore.datastore.id
  resource_pool_id = data.vsphere_resource_pool.pool.id
  num_cpus       = var.cpus
  memory         = var.memory
  guest_id       = data.vsphere_virtual_machine.template.guest_id
  scsi_type      = data.vsphere_virtual_machine.template.scsi_type
  firmware       = data.vsphere_virtual_machine.template.firmware
  depends_on     = [vsphere_virtual_machine.main_master]

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = "vmxnet3"
  }

  disk {
    label            = "disk0.vmdk"
    size             = var.disk_size
    unit_number      = 0
    thin_provisioned = false
  }

  clone {
    timeout       = "500"
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  extra_config = {
    "guestinfo.metadata" = base64encode(templatefile("${path.module}/meta-data.yaml", {
      hostname    = each.value.hostname
    }))
    "guestinfo.metadata.encoding" = "base64"
    "guestinfo.userdata" = base64encode(templatefile("${path.module}/user-data.sh", {
      cluster_cidr    = var.cluster_cidr
      vip_address     = var.vip_address
      hostname        = each.value.hostname,
      role            = "controller",
      main_master     = local.main_master.ip_address,
      gateway         = var.gateway,
      dns             = "8.8.8.8",
      ip_address      = "${each.value.ip_address}/${local.subnet_prefix}",
      private_ssh_key = tls_private_key.ssh_key.private_key_pem,
      public_ssh_key  = tls_private_key.ssh_key.public_key_openssh
    }))
    "guestinfo.userdata.encoding" = "base64"
  }
}


# Worker VMs
resource "vsphere_virtual_machine" "worker" {
  for_each        = local.worker_map
  name            = each.value.hostname
  datastore_id    = data.vsphere_datastore.datastore.id
  resource_pool_id = data.vsphere_resource_pool.pool.id
  num_cpus        = var.worker_cpus
  memory          = var.worker_memory
  guest_id        = data.vsphere_virtual_machine.template.guest_id
  scsi_type       = data.vsphere_virtual_machine.template.scsi_type
  firmware        = data.vsphere_virtual_machine.template.firmware
  depends_on      = [vsphere_virtual_machine.main_master]

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = "vmxnet3"
  }

  disk {
    label            = "disk0.vmdk"
    size             = var.worker_disk_size
    unit_number      = 0
    thin_provisioned = false
  }

  clone {
    timeout       = "500"
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  extra_config = {
    "guestinfo.metadata" = base64encode(templatefile("${path.module}/meta-data.yaml", {
      hostname    = each.value.hostname
    }))
    "guestinfo.metadata.encoding" = "base64"
    "guestinfo.userdata" = base64encode(templatefile("${path.module}/user-data.sh", {
      cluster_cidr    = var.cluster_cidr
      vip_address     = var.vip_address
      hostname        = each.value.hostname,
      role            = "worker",
      main_master     = local.main_master.ip_address,
      gateway         = var.gateway,
      dns             = "8.8.8.8",
      ip_address      = "${each.value.ip_address}/${local.subnet_prefix}",
      private_ssh_key = tls_private_key.ssh_key.private_key_pem,
      public_ssh_key  = tls_private_key.ssh_key.public_key_openssh
    }))
    "guestinfo.userdata.encoding" = "base64"
  }
}


resource "local_file" "private_key" {
  content  = tls_private_key.ssh_key.private_key_pem
  filename = "${path.module}/private_key.pem"
  file_permission = "0600"  # Ensure the key file has the correct permissions
}

resource "null_resource" "download_admin_conf" {
  depends_on = [
    vsphere_virtual_machine.main_master,
    local_file.private_key  # Ensure the private key is written first
  ]

  provisioner "local-exec" {
    command = <<EOT
      scp -i ${local_file.private_key.filename} \
      -o StrictHostKeyChecking=no \
      root@${local.main_master.ip_address}:/etc/kubernetes/admin.conf ./admin.conf
    EOT
  }

  connection {
    type        = "ssh"
    user        = "root"  # Adjust if you're using a different user
    private_key = tls_private_key.ssh_key.private_key_pem
    host        = local.main_master.ip_address
  }
}

# Output the location of the admin.conf file
output "admin_conf_location" {
  value = "${path.module}/admin.conf"
}


