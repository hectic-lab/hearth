terraform {
  backend "s3" {
    bucket = "gitea-runner-hectic-lab"
    key    = "gitea-runners/kube-hetzner/terraform.tfstate"
    region = "hel1"

    endpoints = {
      s3 = "https://hel1.your-objectstorage.com"
    }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
    encrypt                     = false
    skip_s3_checksum            = true
    use_lockfile                = true
  }
}

check "remote_state_contract" {
  assert {
    condition     = local.production_remote_state
    error_message = "Production OpenTofu state must use the configured S3 backend; local production state is forbidden."
  }
}
