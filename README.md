# Terraform modulis automatizuotam kubernetes klasterio diegimui VSPHERE platformoje.
---
## Virtualios mašinos šablono reikalavimai
* Ubuntu 22.04
---
## VSPHERE reikalavimai
* VLAN su interneto prieiga
* (Nebūtina) Sudiegtas load balancer (Su statiniu VIP adresu ir pool su nustatytais master nodes IP adresais)
## Naudojimas
---
Terraform projekto `main.tf` failo pavyzdys
```
module "vsphere_cluster" {
  source = "git::https://github.com/bluebridgemsp/k8s-vsphere.git"

  # vSphere konfiguracija
  vsphere_server        = "CHANGE_ME"
  vsphere_user          = "CHANGE_ME"
  vsphere_password      = "CHANGE_ME"
  datacenter_name       = "CHANGE_ME"
  datastore_name        = "CHANGE_ME"
  vsphere_resource_pool = "CHANGE_ME"
  vsphere_cluster_name  = "CHANGE_ME"              # "vSphere Compute Cluster" pavadinimas
  vsphere_host_name     = "CHANGE_ME"

  # Kubernetes konfiguracija
  cluster_name          = "my_vsphere cluster"     # Kubernetes klasterio pavadinimas
  master_ips = [
    "192.168.1.1",  # Pagrindinis master node
    "192.168.1.2"  # papildomas klasterio controllers
    # ...
  ]
  worker_ips = [
    "192.168.1.10",  # Worker 1
    "192.168.1.11"   # Worker 2
    # ...
  ]

  # VM konfiguracija
  cpus                 = 2                          # CPU kiekis master nodes
  worker_cpus          = 2                          # CPU kiekis worker nodes
  memory               = 4096                       # Atmintis (megabaitais) master nodes
  worker_memory        = 4096                       # Atmintis (megabaitais) worker nodes
  disk_size            = 20                         # Disko dydis (gigabaitais) master nodes
  worker_disk_size     = 30                         # Disko dydis (gigabaitais) worker nodes

  # Tinklo konfiguracija
  gateway               = "192.168.1.254"
  domain                = "my.domain"
  subnet_cidr           = "192.168.1.0/24" # vSphere vlan'o potinklis
  cluster_cidr          = "10.20.30.0/24"  # kubernetes klasterio vidinis CIDR
  vip_address           = "192.168.1.1"    # Load Balancer VIP adresas (nebūtina, nenurodžius bus sukonfiguruota su pagrindinio master node IP adresu)
  network_name          = "VLAN_1"
}


## Modulio veikimas
Modulis pagal nurodytus master ir worker nodes IP adresus sukuria atitinkamą kiekį VM'ų vsphere ir į juos sudiegia kubernetes klasterį. Visas konfiguravimas vyksta naudojant cloud-init, po diegimo visos klasterio mašinos turi sudėtus SSH raktus, todėl gali jungtis vienos į kitas per SSH. Modulis pats parsiunčia ir projekto kataloge patalpina kubeconfig failą, kurį naudojant galima valdyti klasterį.
Klasterio diegimas vyksta naudojant kubeadm, sudiegiamas vanilla klasteris į kurį galite diegti savo norimus komponentus.
