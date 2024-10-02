# Terraform modulis automatizuotam kubernetes klasterio diegimui VSPHERE platformoje.
---
## Virtualios mašinos šablono reikalavimai
* Ubuntu 22.04
---
## VSPHERE reikalavimai
* VLAN su interneto prieiga
* Sudiegtas load balancer (Su statiniu VIP adresu ir pool su nustatytais master nodes IP adresais)
## Naudojimas
---
Terraform projekto `main.tf` failo pavyzdys
```
module "vsphere_cluster" {
  source = "git::https://github.com/bluebridgemsp/k8s-vsphere.git"

  # vSphere configuration
  vsphere_server        = "CHANGE_ME"
  vsphere_user          = "CHANGE_ME"
  vsphere_password      = "CHANGE_ME"
  datacenter_name       = "CHANGE_ME"
  datastore_name        = "CHANGE_ME"
  vsphere_resource_pool = "CHANGE_ME"
  vsphere_cluster_name  = "CHANGE_ME"              # "vSphere Compute Cluster" pavadinimas
  cluster_name          = "my_vsphere cluster"     # Kubernetes klasterio pavadinimas
  network_name          = "VLAN_1"
  master_ips = [
    "192.168.1.1",  # Pagrindinis master node
    "192.168.50.2"  # papildomi klasterio controllers
    # ...
  ]
  worker_ips = [
    "192.168.50.10",  # Worker 1
    "192.168.50.11"   # Worker 2
    # ...
  ]

  # VM configuration
  cpus                 = 2                          # CPU kiekis master nodes
  worker_cpus          = 2                          # CPU kiekis worker nodes
  memory               = 4096                       # Atmintis (megabaitais) master nodes
  worker_memory        = 4096                       # Atmintis (megabaitais) worker nodes
  disk_size            = 20                         # Disko dydis (gigabaitais) master nodes
  worker_disk_size     = 30                         # Disko dydis (gigabaitais) worker nodes

  # Network configuration
  gateway              = "192.168.1.254"              # Gateway IP for the VMs
  domain               = "my.domain"         # Domain name for the VMs
  subnet_cidr           = "192.168.1.0/24"
  cluster_cidr          = "10.20.30.0/24"
  vip_address           = "192.168.2.1"
}


## Modulio veikimas
Modulis pagal nurodytus master ir worker nodes IP adresus sukuria atitinkamą kiekį VM'ų vsphere ir į juos sudiegia kubernetes klasterį. Visas konfiguravimas vyksta naudojant cloud-init, po diegimo visos klasterio mašinos turi sudėtus SSH raktus, todėl gali jungtis vienos į kitas per SSH. Modulis pats parsiunčia ir projekto kataloge patalpina kubeconfig failą, kurį naudojant galima valdyti klasterį.
Klasterio diegimas vyksta naudojant kubeadm, sudiegiamas vanilla klasteris į kurį galite diegti savo norimus komponentus.
