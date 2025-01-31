#!/bin/bash

HOSTNAME=${hostname}
PUBLIC_SSH_KEY='${public_ssh_key}'
PRIVATE_SSH_KEY='${private_ssh_key}'
VIP_ADDRESS=${vip_address}
CIDR=${cluster_cidr}
MAIN_MASTER=${main_master}
SERVER_USER=root
ROLE=${role}
JOIN_COMMAND_FILE="/root/join.txt"
KEY_FILE=/root/key.txt


# Set hostname and manage /etc/hosts
echo "### Changing hostname"
sudo hostnamectl set-hostname "$HOSTNAME"

echo "### Changing ubuntu user password settings"
passwd -x -1 ubuntu
passwd -u ubuntu
chage -d $(date +%Y-%m-%d) ubuntu

echo "### Configuring network"
rm -rf /etc/netplan/*
cat > /etc/netplan/00-installer-config.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $(ip -o link|grep -v lo:|head -1|awk '{print $2}')
      dhcp4: no
      dhcp6: no
      addresses:
        - ${ip_address}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses:
          - ${dns}
EOF

sudo netplan apply

echo "### Disabling firewall"
ufw disable

snap install go --classic

echo "### Saving ssh keys"
sudo echo "${private_ssh_key}" > /root/.ssh/id_rsa
sudo chmod 600 /root/.ssh/id_rsa
sudo systemctl restart ssh
sudo echo "${public_ssh_key}" > /root/.ssh/authorized_keys

apt update
apt full-upgrade -y
echo "### Setting up kernel modules"
sudo tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
echo "### Setting up sysctl"
sudo tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
echo "### Adding docker gpg"
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
echo "### Adding docker repo"
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
echo "### Installing containerd"
sudo apt update
sudo apt install -y containerd.io
echo "### Configuring containerd"
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
echo "### Restarting containerd"
sudo systemctl restart containerd
sudo systemctl enable containerd
apt-get install -y apt-transport-https ca-certificates curl gnupg
echo "### Adding kubernetes repo key"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "### Adding kubernetes repo"
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list   # helps tools such as command-not-found to work correctly
echo "### Installing kubernetes"
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

if [[ "$ROLE" == "main_master" ]]; then
  echo "### Initialize the Kubernetes cluster"
  kubeadm init  --upload-certs --control-plane-endpoint "$VIP_ADDRESS:6443" --pod-network-cidr=$CIDR

  echo "### Generate key file"
  kubeadm init phase upload-certs --upload-certs | tail -n1 | tee $KEY_FILE

  echo "### Generate join command file"
  kubeadm token create --print-join-command | sudo tee $JOIN_COMMAND_FILE

  echo  "### Installing antrea"
  export KUBECONFIG="/etc/kubernetes/admin.conf"
  kubectl apply -f https://raw.githubusercontent.com/antrea-io/antrea/main/build/yamls/antrea.yml

  echo "### Restarting kubelet"
  sudo systemctl restart kubelet.service

fi

if [[ "$ROLE" == "main_master" ]]; then
  echo "### Initialize the Kubernetes cluster"
  kubeadm init  --upload-certs --control-plane-endpoint "$VIP_ADDRESS:6443" --pod-network-cidr=$CIDR

  echo "### Generate key file"
  kubeadm init phase upload-certs --upload-certs | tail -n1 | tee $KEY_FILE

  echo "### Generate join command file"
  kubeadm token create --print-join-command | sudo tee $JOIN_COMMAND_FILE

  echo  "### Installing antrea"
  export KUBECONFIG="/etc/kubernetes/admin.conf"
  kubectl apply -f https://raw.githubusercontent.com/antrea-io/antrea/main/build/yamls/antrea.yml

  echo "### Restarting kubelet"
  sudo systemctl restart kubelet.service

else
  echo "### Waiting for the master node to be fully installed"

    while ! ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
                -o ServerAliveInterval=10 -o ServerAliveCountMax=1 \
                $SERVER_USER@$MAIN_MASTER 'test -f /etc/kubernetes/admin.conf'; do
        echo "admin.conf not found, retrying in 10 seconds..."
        sleep 10
    done
    echo "### admin.conf found, joining to master"


  if [[ "$ROLE" == "master" ]]; then
    if ssh -o StrictHostKeyChecking=no "$SERVER_USER@$MAIN_MASTER" "[[ -f \"$KEY_FILE\" ]] && [[ \$(find \"$KEY_FILE\" -mmin -120 -print) ]]"; then
      echo "### The file exists and is younger than 2 hours."
      echo "### Retrieve the key"
      KEY=$(ssh -o StrictHostKeyChecking=no $SERVER_USER@$MAIN_MASTER "cat $KEY_FILE")
    else
      echo "### The file does not exist or is not younger than 2 hours."
      echo "### Generate new key"
      ssh -o StrictHostKeyChecking=no $SERVER_USER@$MAIN_MASTER "kubeadm init phase upload-certs --upload-certs | tail -n1 | tee $KEY_FILE"
      KEY=$(ssh -o StrictHostKeyChecking=no $SERVER_USER@$MAIN_MASTER "cat $KEY_FILE")
    fi
    if ssh -o StrictHostKeyChecking=no "$SERVER_USER@$MAIN_MASTER" "[[ -f \"$JOIN_COMMAND_FILE\" ]] && [[ \$(find \"$JOIN_COMMAND_FILE\" -mmin -120 -print) ]]"; then
      echo "### The file exists and is younger than 2 hours."
      echo "### Retrieve the join command"
      JOIN_COMMAND=$(ssh -o StrictHostKeyChecking=no $SERVER_USER@$MAIN_MASTER "cat $JOIN_COMMAND_FILE")
    else
      echo "### The file does not exist or is not younger than 2 hours."
      echo "### Generate new join command"
      ssh -o StrictHostKeyChecking=no $SERVER_USER@$MAIN_MASTER "kubeadm token create --print-join-command | sudo tee $JOIN_COMMAND_FILE"
      JOIN_COMMAND=$(ssh -o StrictHostKeyChecking=no $SERVER_USER@$MAIN_MASTER "cat $JOIN_COMMAND_FILE")
    fi
    # Form the control plane join command
    CONTROL_PLANE_JOIN_COMMAND="$JOIN_COMMAND --control-plane --certificate-key $KEY"

    # Execute the join command
    echo "Executing control plane join command... "
    eval $CONTROL_PLANE_JOIN_COMMAND

  elif [[ "$ROLE" == "worker" ]]; then
    # Check if the join command file exists and is newer than 2 hours
    if ssh -o StrictHostKeyChecking=no "$SERVER_USER@$MAIN_MASTER" "[[ -f \"$JOIN_COMMAND_FILE\" ]] && [[ \$(find \"$JOIN_COMMAND_FILE\" -mmin -120 -print) ]]"; then
      echo "### The file exists and is younger than 2 hours."
      echo "### Retrieve the join command"
      JOIN_COMMAND=$(ssh -o StrictHostKeyChecking=no $SERVER_USER@$MAIN_MASTER "cat $JOIN_COMMAND_FILE")
    else
      echo "### The file does not exist or is not younger than 2 hours."
      echo "### Generate new join command"
      ssh -o StrictHostKeyChecking=no $SERVER_USER@$MAIN_MASTER "kubeadm token create --print-join-command | sudo tee $JOIN_COMMAND_FILE"
      JOIN_COMMAND=$(ssh -o StrictHostKeyChecking=no $SERVER_USER@$MAIN_MASTER "cat $JOIN_COMMAND_FILE")
    fi
    # Execute the join command
    echo "Executing join command..."
    eval $JOIN_COMMAND
  fi
fi
