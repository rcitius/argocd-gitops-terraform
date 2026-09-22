# =============================================================================
# Example caller.
#
# ArgoCD is installed once per cluster. Where that call lives depends on who
# owns the cluster:
#
#   dedicated cluster  -> the tenant's own onboarding root (shown here)
#   shared cluster     -> the cluster bootstrap root, so the tenants that share
#                         it do not each try to install their own
#
# Getting that wrong is the classic failure: two roots racing over one argocd
# namespace and one set of cluster-scoped CRDs.
# =============================================================================

module "argocd" {
  source = "../modules/argocd"

  # Pin it. An unpinned ArgoCD upgrades itself out from under every Application
  # on the cluster. Chart 10.4.0 ships ArgoCD v3.5.1.
  chart_version = "10.4.0"

  # ----- the GitOps repository ---------------------------------------------
  #
  # Deliberately NOT the repository that holds this Terraform. An ArgoCD
  # repository credential grants read on the WHOLE repository, so pointing
  # clusters at the infrastructure repo hands every cluster a token that can
  # read all of it. A dedicated GitOps repo can read manifests and nothing else.
  appsets_repo_url = "git@github.com:example-org/gitops.git"
  appsets_revision = "main"

  # One directory per cluster. Two clusters watching one directory would each
  # try to deploy the other's environments.
  appsets_path = "clusters/demo-dev"

  # Preferred over username/password: the key belongs to the repository rather
  # than to a person. Read it from a secret store; never put it in tfvars.
  git_ssh_private_key = var.gitops_deploy_key

  # ----- the OCI chart registry --------------------------------------------
  #
  # No oci:// scheme. Must match every Application's repoURL character for
  # character, or the chart pull 401s.
  #
  # The token needs content/read AND metadata/read on the chart repositories.
  # An image-pull-only token 401s on the chart pull while image pulls carry on
  # working, which is a confusing way to spend an afternoon.
  oci_registry_url = "myregistry.azurecr.io/helm"
  oci_username     = var.registry_username
  oci_password     = var.registry_password
}

variable "gitops_deploy_key" {
  description = "PRIVATE half of the SSH deploy key for the GitOps repository. The public half goes on the repository as a read-only key."
  type        = string
  sensitive   = true
}

variable "registry_username" {
  type      = string
  sensitive = true
}

variable "registry_password" {
  type      = string
  sensitive = true
}
