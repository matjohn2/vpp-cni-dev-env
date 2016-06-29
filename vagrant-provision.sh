#!/bin/bash

set -e
set -o pipefail

# Dependancies for Kubernetes CNI Testbed (Vagrant up)
# Target is Ubuntu 16.04 LTS

## IP Helper function
function int-ip { /sbin/ifconfig $1 | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}'; }

## Install Some PreReqs
sudo apt-get install -y apt-transport-https ca-certificates bridge-utils
sudo apt-get update
## Install Docker
sudo apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
sudo cp /vagrant/docker.list /etc/apt/sources.list.d/docker.list

sudo apt-get update
sudo apt-get install -y linux-image-extra-$(uname -r)
sudo apt-get install -y docker-engine
sudo usermod -aG docker ubuntu

## Setup our MASTER
if [[ $(hostname -s) = cni-master* ]]; then
    echo "*** THIS IS A MASTER ***"
    echo "***    Setting up    ***"

    #if /vagrant/ssl/ca.pem already exists. Don't generate new keys.
    if [ ! -f /vagrant/ssl/ca.pem ]; then
      # Generate the root CA.

      openssl genrsa -out /vagrant/ssl/ca-key.pem 2048
      openssl req -x509 -new -nodes -key /vagrant/ssl/ca-key.pem -days 10000 -out /vagrant/ssl/ca.pem -subj "/CN=kube-ca"

      # Generate the API server keypair.
      openssl genrsa -out /vagrant/ssl/apiserver-key.pem 2048
      openssl req -new -key /vagrant/ssl/apiserver-key.pem -out /vagrant/ssl/apiserver.csr -subj "/CN=kube-apiserver" -config /vagrant/ssl/openssl.cnf
      openssl x509 -req -in /vagrant/ssl/apiserver.csr -CA /vagrant/ssl/ca.pem -CAkey /vagrant/ssl/ca-key.pem -CAcreateserial -out /vagrant/ssl/apiserver.pem -days 365 -extensions v3_req -extfile /vagrant/ssl/openssl.cnf

    fi

    #Check our SSL key now esists
    if [ ! -f /vagrant/ssl/ca.pem ]; then
      echo "Our CA Didn't generate. Aborting"
      exit 1
    fi

    # Move SSL keys (needed for master)
    sudo mkdir -p /etc/kubernetes/ssl/
    sudo cp -t /etc/kubernetes/ssl/ /vagrant/ssl/ca.pem /vagrant/ssl/apiserver.pem /vagrant/ssl/apiserver-key.pem

    # Set permissions (needed for master)
    sudo chmod 600 /etc/kubernetes/ssl/apiserver-key.pem
    sudo chown root:root /etc/kubernetes/ssl/apiserver-key.pem

    # Get Kubelet and KubeCTL for master
    sudo wget -N -P /usr/bin http://storage.googleapis.com/kubernetes-release/release/v1.3.0-beta.2/bin/linux/amd64/kubectl
    sudo wget -N -P /usr/bin http://storage.googleapis.com/kubernetes-release/release/v1.3.0-beta.2/bin/linux/amd64/kubelet
    sudo chmod +x /usr/bin/kubelet /usr/bin/kubectl

    # Configure Kubelet as a SystemD service
    sudo cp -v /vagrant/systemd-manifests/master/kubelet.service /etc/systemd/kubelet.service
    # Enable the unit file so that it runs on boot
    sudo systemctl enable /etc/systemd/kubelet.service
    # Start the kubelet service
    sudo systemctl start kubelet.service

    # Bootstrap our Kubernetes master as containers (onto our local kubelet)
    sudo mkdir -p /etc/kubernetes/manifests
    sudo cp -v /vagrant/kubelet-manifests/master.manifest  /etc/kubernetes/manifests/.
    echo "*** Kubernetes Master Components Scheduled ***"

fi

## Setup our WORKERS
if [[ $(hostname -s) = cni-worker* ]]; then
    echo "*** THIS IS A WORKER ***"
    echo "***    Setting up    ***"

    # Check we already have a CA Cert. If not something went wrong.
    if [ ! -f /vagrant/ssl/ca.pem ]; then
      echo "No CACERT! This should have been generated by now. Exiting."
      exit 1
    fi

    # Use our VM's IP to generate worker certs.
    WORKER_IP=$(int-ip enp0s8)

    cat <<EOF > /tmp/worker-openssl.cnf
      [req]
      req_extensions = v3_req
      distinguished_name = req_distinguished_name
      [req_distinguished_name]
      [ v3_req ]
      basicConstraints = CA:FALSE
      keyUsage = nonRepudiation, digitalSignature, keyEncipherment
      subjectAltName = @alt_names
      [alt_names]
      IP.1 = ${WORKER_IP}
EOF

    # Generate keys.
    openssl genrsa -out /tmp/worker-key.pem 2048
    openssl req -new -key /tmp/worker-key.pem -out /tmp/worker.csr -subj "/CN=worker-key" -config /tmp/worker-openssl.cnf
    openssl x509 -req -in /tmp/worker.csr -CA /vagrant/ssl/ca.pem -CAkey /vagrant/ssl/ca-key.pem -CAcreateserial -out /tmp/worker.pem -days 365 -extensions v3_req -extfile /tmp/worker-openssl.cnf

    # Move keys into place
    sudo mkdir -vp /etc/kubernetes/ssl
    sudo cp -t /etc/kubernetes/ssl /tmp/worker-key.pem /vagrant/ssl/ca.pem /tmp/worker.pem

    # Move ssl worker config into place (Redundant, keep on box for future)
    sudo cp /tmp/worker-openssl.cnf /etc/kubernetes/worker-openssl.cnf

    # Enable CNI Working Directories
    sudo mkdir -p /opt/cni/bin/
    sudo mkdir -p /etc/cni/net.d/
    sudo cp -v /vagrant/cni/conf/* /etc/cni/net.d/.
    sudo cp -v /vagrant/cni/bin/* /opt/cni/bin/.

    # Install Kubelet
    sudo wget -N -P /usr/bin http://storage.googleapis.com/kubernetes-release/release/v1.3.0-beta.2/bin/linux/amd64/kubelet
    sudo chmod +x /usr/bin/kubelet
    sudo cp -v /vagrant/systemd-manifests/worker/kubeconfig.yaml /etc/kubernetes/worker-kubeconfig.yaml

cat <<EOF > /tmp/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
Requires=networking.service
After=docker.service

[Service]
EnvironmentFile=/etc/network-environment
ExecStart=/usr/bin/kubelet \
--address=0.0.0.0 \
--allow-privileged=true \
--cluster-dns=192.168.10.240 \
--cluster-domain=cluster.local \
--config=/etc/kubernetes/manifests \
--hostname-override=${WORKER_IP} \
--api-servers=https://192.168.10.10:443 \
--kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml \
--tls-private-key-file=/etc/kubernetes/ssl/worker-key.pem \
--tls-cert-file=/etc/kubernetes/ssl/worker.pem \
--logtostderr=true \
--network-plugin=cni \
--network-plugin-dir=/etc/cni/net.d
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Move our systemd manifest for kubelet into place.
    sudo cp -v /tmp/kubelet.service /etc/systemd/kubelet.service

    # Enable and start the unit files so that they run on boot
    sudo systemctl enable /etc/systemd/kubelet.service
    sudo systemctl start kubelet.service

    # Start kube proxy on our workers.
    sudo mkdir -p /etc/kubernetes/manifests/
    sudo cp -v /vagrant/kubelet-manifests/worker/kube-proxy.manifest /etc/kubernetes/manifests/.

    echo "*** Kubernetes Worker Components Deployed ***"

fi
