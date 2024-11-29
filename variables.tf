# variables.tf

# vSphere authentication variables
variable "vsphere_user" {
  description = "The username for vSphere authentication"
  type        = string
}

variable "vsphere_password" {
  description = "The password for vSphere authentication"
  type        = string
  sensitive   = true
}

variable "vsphere_server" {
  description = "The vSphere server address"
  type        = string
}

variable "master_ips" {
  description = "List of static IP addresses for the master nodes."
  type        = list(string)
}

variable "worker_ips" {
  description = "List of static IP addresses for the worker nodes."
  type        = list(string)
}

# vSphere infrastructure variables
variable "datacenter_name" {
  description = "The name of the vSphere datacenter"
  type        = string
}

variable "vsphere_resource_pool" {
  description = "If you don't have any resource pools, put 'Resources' after the cluster name"
  type        = string
}

variable "datastore_name" {
  description = "The name of the vSphere datastore"
  type        = string
}

variable "cluster_name" {
  description = "The name of the kuberentes cluster"
  type        = string
}

variable "vsphere_cluster_name" {
  description = "The name of the vSphere compute cluster"
  type        = string
}

variable "network_name" {
  description = "The name of the vSphere network"
  type        = string
}

variable "subnet_cidr" {
  description = "Your networks CIDR expressed in the form '0.0.0.0/24'"
  type    = string
}

variable "cluster_cidr" {
  description = "your kubernetes clusters CIDR expressed in the form 0.0.0.0/24"
  type    = string
}

variable "vip_address" {
  description = "your load balancers VIP address"
  type        = string
  default     = ""
}


variable "cpus" {
  description = "The number of CPUs for each master VM"
  type        = number
  default     = 2
}

variable "memory" {
  description = "The memory size (in MB) for each master VM"
  type        = number
  default     = 4096
}

variable "disk_size" {
  description = "The disk size (in GB) for each master VM"
  type        = number
  default     = 40
}

variable "worker_cpus" {
  description = "The number of CPUs for each worker VM"
  type        = number
  default     = 2
}

variable "worker_memory" {
  description = "The memory size (in MB) for each worker VM"
  type        = number
  default     = 4096
}

variable "worker_disk_size" {
  description = "The disk size (in GB) for each worker VM"
  type        = number
  default     = 40
}

variable "gateway" {
  description = "The gateway IP address for the VMs"
  type        = string
}

variable "domain" {
  description = "The domain name for the VMs"
  type        = string
}

variable "vsphere_host_name" {
  description = "Host name of your esxi server"
}
