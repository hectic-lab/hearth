locals {
  default_storage_class = "hcloud-volumes"

  control_plane_nodepools = [
    {
      name        = "control-plane"
      server_type = var.control_plane_server_type
      location    = var.hetzner_location
      labels      = []
      taints      = []
      count       = 1
    },
  ]

  agent_nodepools = [
    {
      name        = "runner-workers"
      server_type = var.worker_server_type
      location    = var.hetzner_location
      labels      = ["node-role.hectic-lab/gitea-runner=true"]
      taints      = []
      count       = var.worker_count
    },
  ]
}

module "kube_hetzner" {
  source  = "kube-hetzner/kube-hetzner/hcloud"
  version = "2.19.3"

  providers = {
    hcloud = hcloud
  }

  hcloud_token    = var.hcloud_token
  ssh_public_key  = var.ssh_public_key
  ssh_private_key = var.ssh_private_key

  cluster_name = var.cluster_name
  base_domain  = var.base_domain

  # kube-hetzner v2.19.3 writes <cluster_name>_kubeconfig.yaml; outputs below
  # expose that expected path without outputting kubeconfig private key material.
  create_kubeconfig = true

  network_region          = var.network_region
  load_balancer_location  = var.hetzner_location
  control_plane_nodepools = local.control_plane_nodepools
  agent_nodepools         = local.agent_nodepools
  firewall_ssh_source     = var.firewall_ssh_source
  firewall_kube_api_source = var.firewall_kube_api_source
  hcloud_ssh_key_id       = var.hcloud_ssh_key_id

  # Hetzner CSI is the required StorageClass provider for runner PVCs.
  disable_hetzner_csi = false

  # Longhorn is intentionally off; the initial runner PVCs use Hetzner CSI only.
  enable_longhorn = false

  # Scaling note: for 10 trusted DinD jobs later, keep autoscaling disabled and
  # raise worker_count to 5 or increase worker_server_type after validating pod
  # CPU, memory, and ephemeral-storage pressure in Task 11.
}
