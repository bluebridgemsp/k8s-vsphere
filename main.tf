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

data "vsphere_datacenter" "datacenter" {
  name = var.datacenter_name
}

data "vsphere_resource_pool" "default" {
  name          = var.vsphere_resource_pool
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_datastore" "datastore" {
  name          = var.datastore_name
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.vsphere_cluster_name
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_network" "network" {
  name          = var.network_name
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_host" "host" {
  name          = var.vsphere_host_name
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_folder" "folder" {
  path = "/${data.vsphere_datacenter.datacenter.name}/vm"
}

## Remote OVF/OVA Source
data "vsphere_ovf_vm_template" "ovfRemote" {
  name              = "foo"
  disk_provisioning = "thin"
  resource_pool_id  = data.vsphere_resource_pool.default.id
  datastore_id      = data.vsphere_datastore.datastore.id
  host_system_id    = data.vsphere_host.host.id
  remote_ovf_url    = "https://cloud-images.ubuntu.com/noble/20241004/noble-server-cloudimg-amd64.ova"
  ovf_network_map = {
    "VM Network" : data.vsphere_network.network.id
  }
}

resource "tls_private_key" "ssh_key" {
  algorithm = "ED25519"
}

resource "local_file" "cloud_pem" {
  filename = "cloudtls.pem"
  content = tls_private_key.ssh_key.private_key_openssh
}
resource "local_file" "cloud_pem_pub" {
  filename = "cloudtls.pub"
  content = tls_private_key.ssh_key.public_key_openssh
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
  vip_address = var.vip_address != "" ? var.vip_address : local.main_master.ip_address
}



# Main Master VM
resource "vsphere_virtual_machine" "main_master" {
  name            = local.main_master.hostname
  folder          = trimprefix(data.vsphere_folder.folder.path, "/${data.vsphere_datacenter.datacenter.name}/vm")
  datastore_id    = data.vsphere_datastore.datastore.id
  datacenter_id   = data.vsphere_datacenter.datacenter.id
  host_system_id  = data.vsphere_host.host.id
  resource_pool_id = data.vsphere_resource_pool.default.id
  num_cpus        = var.cpus
  memory          = var.memory
  num_cores_per_socket = data.vsphere_ovf_vm_template.ovfRemote.num_cores_per_socket
  guest_id        = data.vsphere_ovf_vm_template.ovfRemote.guest_id
  nested_hv_enabled = data.vsphere_ovf_vm_template.ovfRemote.nested_hv_enabled

  dynamic "network_interface" {
    for_each = data.vsphere_ovf_vm_template.ovfRemote.ovf_network_map
    content {
      network_id = network_interface.value
    }
  }

  wait_for_guest_net_timeout = 0
  wait_for_guest_ip_timeout  = 0

  ovf_deploy {
    allow_unverified_ssl_cert = false
    remote_ovf_url            = data.vsphere_ovf_vm_template.ovfRemote.remote_ovf_url
    disk_provisioning         = data.vsphere_ovf_vm_template.ovfRemote.disk_provisioning
    ovf_network_map           = data.vsphere_ovf_vm_template.ovfRemote.ovf_network_map
  }
  cdrom {
    client_device = true
  }
  extra_config = {
    "disk.enableUUID"               = "TRUE"  # Ensure disk UUIDs are enabled for cloud-init
  }
  vapp {
    properties = {
      public-keys = tls_private_key.ssh_key.public_key_openssh
      password = "ubuntu!12"
      user-data =  base64encode(templatefile("${path.module}/user-data.sh", {
        cluster_cidr    = var.cluster_cidr,
        vip_address     = local.vip_address,
        hostname        = local.main_master.hostname,
        role            = "main_master",
        main_master     = local.main_master.ip_address,
        gateway         = var.gateway,
        dns             = "8.8.8.8",
        ip_address      = "${local.main_master.ip_address}/${local.subnet_prefix}",
        private_ssh_key = tls_private_key.ssh_key.private_key_openssh,
        public_ssh_key  = tls_private_key.ssh_key.public_key_openssh
      }
      ))
    }
  }

  provisioner "local-exec" {
    command = "chmod 400 cloudtls.pem"
  }
}

# Additional Master VMs
resource "vsphere_virtual_machine" "master" {
  for_each       = length(var.master_ips) > 1 ? local.additional_master_map : {}
  name           = each.value.hostname
  folder          = trimprefix(data.vsphere_folder.folder.path, "/${data.vsphere_datacenter.datacenter.name}/vm")
  datastore_id    = data.vsphere_datastore.datastore.id
  datacenter_id   = data.vsphere_datacenter.datacenter.id
  host_system_id  = data.vsphere_host.host.id
  resource_pool_id = data.vsphere_resource_pool.default.id
  num_cpus        = var.cpus
  memory          = var.memory
  num_cores_per_socket = data.vsphere_ovf_vm_template.ovfRemote.num_cores_per_socket
  guest_id        = data.vsphere_ovf_vm_template.ovfRemote.guest_id
  nested_hv_enabled = data.vsphere_ovf_vm_template.ovfRemote.nested_hv_enabled
  depends_on      = [vsphere_virtual_machine.main_master]

  dynamic "network_interface" {
    for_each = data.vsphere_ovf_vm_template.ovfRemote.ovf_network_map
    content {
      network_id = network_interface.value
    }
  }

  wait_for_guest_net_timeout = 0
  wait_for_guest_ip_timeout  = 0

  ovf_deploy {
    allow_unverified_ssl_cert = false
    remote_ovf_url            = data.vsphere_ovf_vm_template.ovfRemote.remote_ovf_url
    disk_provisioning         = data.vsphere_ovf_vm_template.ovfRemote.disk_provisioning
    ovf_network_map           = data.vsphere_ovf_vm_template.ovfRemote.ovf_network_map
  }
  cdrom {
    client_device = true
  }
  extra_config = {
    "disk.enableUUID"               = "TRUE"  # Ensure disk UUIDs are enabled for cloud-init
  }
  vapp {
    properties = {
      public-keys = tls_private_key.ssh_key.public_key_openssh
      password = "ubuntu!12"
      user-data =  base64encode(templatefile("${path.module}/user-data.sh", {
        cluster_cidr    = var.cluster_cidr,
        vip_address     = local.vip_address,
        hostname        = each.value.hostname,
        role            = "master",
        main_master     = local.main_master.ip_address,
        gateway         = var.gateway,
        dns             = "8.8.8.8",
        ip_address      = "${each.value.ip_address}/${local.subnet_prefix}",
        private_ssh_key = tls_private_key.ssh_key.private_key_openssh,
        public_ssh_key  = tls_private_key.ssh_key.public_key_openssh
      }
      ))
    }
  }

  provisioner "local-exec" {
    command = "ssh-keygen -R 192.168.50.104"
  }

  provisioner "local-exec" {
    command = "chmod 400 cloudtls.pem"
  }
}

# Worker VMs
resource "vsphere_virtual_machine" "worker" {
  for_each        = local.worker_map
  name            = each.value.hostname
  folder          = trimprefix(data.vsphere_folder.folder.path, "/${data.vsphere_datacenter.datacenter.name}/vm")
  datastore_id    = data.vsphere_datastore.datastore.id
  datacenter_id   = data.vsphere_datacenter.datacenter.id
  host_system_id  = data.vsphere_host.host.id
  resource_pool_id = data.vsphere_resource_pool.default.id
  num_cpus        = var.cpus
  memory          = var.memory
  num_cores_per_socket = data.vsphere_ovf_vm_template.ovfRemote.num_cores_per_socket
  guest_id        = data.vsphere_ovf_vm_template.ovfRemote.guest_id
  nested_hv_enabled = data.vsphere_ovf_vm_template.ovfRemote.nested_hv_enabled
  depends_on      = [vsphere_virtual_machine.main_master]

  dynamic "network_interface" {
    for_each = data.vsphere_ovf_vm_template.ovfRemote.ovf_network_map
    content {
      network_id = network_interface.value
    }
  }

  wait_for_guest_net_timeout = 0
  wait_for_guest_ip_timeout  = 0

  ovf_deploy {
    allow_unverified_ssl_cert = false
    remote_ovf_url            = data.vsphere_ovf_vm_template.ovfRemote.remote_ovf_url
    disk_provisioning         = data.vsphere_ovf_vm_template.ovfRemote.disk_provisioning
    ovf_network_map           = data.vsphere_ovf_vm_template.ovfRemote.ovf_network_map
  }
  cdrom {
    client_device = true
  }
  extra_config = {
    "disk.enableUUID"               = "TRUE"  # Ensure disk UUIDs are enabled for cloud-init
  }
  vapp {
    properties = {
      public-keys = tls_private_key.ssh_key.public_key_openssh
      password = "ubuntu!12"
      user-data =  base64encode(templatefile("${path.module}/user-data.sh", {
        cluster_cidr    = var.cluster_cidr,
        vip_address     = local.vip_address,
        hostname        = each.value.hostname,
        role            = "worker",
        main_master     = local.main_master.ip_address,
        gateway         = var.gateway,
        dns             = "8.8.8.8",
        ip_address      = "${each.value.ip_address}/${local.subnet_prefix}",
        private_ssh_key = tls_private_key.ssh_key.private_key_openssh,
        public_ssh_key  = tls_private_key.ssh_key.public_key_openssh
      }
      ))
    }
  }

  provisioner "local-exec" {
    command = "chmod 400 cloudtls.pem"
  }
}


