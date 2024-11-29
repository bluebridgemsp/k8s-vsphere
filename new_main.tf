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
  user                 = "Administrator@vsphere.local"
  password             = "H*******************************8"
  vsphere_server       = "192.168.54.3"
  allow_unverified_ssl = true
}


data "vsphere_datacenter" "datacenter" {
  name = "OSS-LAB"
}

data "vsphere_datastore" "datastore" {
  name          = "jli-old-vmware-02"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_compute_cluster" "cluster" {
  name          = "OOS-LAB"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_resource_pool" "default" {
  name          = "OOS-LAB/Resources"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_host" "host" {
  name          = "esx2.oss.local"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_network" "network" {
  name          = "VLAN_500"
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
  algorithm = "RSA"             # Specify the key algorithm (RSA, ECDSA, etc.)
  rsa_bits  = 2048              # Specify the key size (bits) for RSA keys

  # Optional: Set the key's usage and exportability attributes
  ecdsa_curve = "P256"         # For ECDSA keys, specify the curve type (P256, P384, P521, etc.)
#  key_usage   = ["digitalSignature", "keyEncipherment", "serverAuth", "clientAuth"]
#  private_key_pem_output_path = "kube_ssh_key.pem"  # Specify the output path for the private key file (optional)

  # Optional: Set additional attributes such as validity period and key type
#  validity_period_hours = 12    # Specify the validity period for the key (hours)
#  key_type = "SSH"              # Specify the key type (SSH, PGP, etc.)
}

resource "local_file" "cloud_pem" {
  filename = "cloudtls.pem"
  content = tls_private_key.ssh_key.private_key_pem
}
resource "local_file" "cloud_pem_pub" {
  filename = "cloudtls.pub"
  content = tls_private_key.ssh_key.public_key_pem
}

## Deployment of VM from Remote OVF
resource "vsphere_virtual_machine" "vmFromRemoteOvf" {
  name                 = "VMfromURL"
  folder               = trimprefix(data.vsphere_folder.folder.path, "/${data.vsphere_datacenter.datacenter.name}/vm")
  datacenter_id        = data.vsphere_datacenter.datacenter.id
  datastore_id         = data.vsphere_datastore.datastore.id
  host_system_id       = data.vsphere_host.host.id
  resource_pool_id     = data.vsphere_resource_pool.default.id
  num_cpus             = 4
  num_cores_per_socket = data.vsphere_ovf_vm_template.ovfRemote.num_cores_per_socket
  memory               = 4096
  guest_id             = data.vsphere_ovf_vm_template.ovfRemote.guest_id
  nested_hv_enabled    = data.vsphere_ovf_vm_template.ovfRemote.nested_hv_enabled
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
      user-data =  base64encode(templatefile("user-data.sh", {
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
