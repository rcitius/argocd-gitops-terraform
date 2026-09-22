# ----- Install ------------------------------------------------------------

variable "chart_version" {
  description = "Version of the argo-cd chart from https://argoproj.github.io/argo-helm. Pin it: an unpinned ArgoCD upgrades itself out from under every Application on the cluster. The POC validated ArgoCD v3.5.1."
  type        = string
}

variable "namespace" {
  description = "Namespace ArgoCD is installed into. Also the namespace its Application and ApplicationSet objects live in -- the applicationset controller only watches its own namespace by default."
  type        = string
  default     = "argocd"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "argocd"
}

variable "helm_timeout_seconds" {
  description = "Helm release timeout. The chart installs cluster-scoped CRDs, which is slow on a busy or small cluster."
  type        = number
  default     = 900
}

variable "server_insecure" {
  description = "Run argocd-server without TLS, for when an ingress terminates it. Note the consequence: the argocd CLI then needs --plaintext, not --insecure."
  type        = bool
  default     = true
}

variable "enable_dex" {
  description = "Install the Dex SSO component. Off by default -- not needed while access is via the admin account or port-forward."
  type        = bool
  default     = false
}

variable "enable_notifications" {
  description = "Install the notifications controller. Off by default; AKS upgrade alerting already goes through Event Grid to the cmi Logic App."
  type        = bool
  default     = false
}

# ----- Git repository holding this cluster's ApplicationSets --------------

variable "appsets_repo_url" {
  description = "Clone URL of the repository holding the ApplicationSets. Must match the git repository Secret's url exactly."
  type        = string
}

variable "appsets_revision" {
  description = "Branch, tag or commit the bootstrap Application tracks."
  type        = string
}

variable "appsets_path" {
  description = "Directory within the repository this cluster's bootstrap Application watches. One directory per cluster: an instance must never see another cluster's ApplicationSets, or it will try to deploy them locally."
  type        = string
}

variable "git_username" {
  description = "Username for the ApplicationSets repository. Leave empty for a public repository -- the git credential Secret is then skipped entirely."
  type        = string
  default     = ""
}

variable "git_password" {
  description = "Password, app password or access token for the ApplicationSets repository."
  type        = string
  default     = ""
  sensitive   = true
}

# ----- OCI registry holding the chart artifacts ---------------------------

variable "oci_registry_url" {
  description = "OCI Helm registry path, with no oci:// scheme (e.g. myregistry.azurecr.io/helm). An Application's repoURL must match this string exactly or the chart pull fails with a 401."
  type        = string
}

variable "oci_registry_name" {
  description = "Display name for the registry in the ArgoCD UI."
  type        = string
  default     = "oci-charts"
}

variable "oci_username" {
  description = "Username for the OCI registry. Needs content/read and metadata/read on the chart repositories -- an image-pull-only token whose scope map excludes them will 401 on the chart pull even though image pulls keep working."
  type        = string
}

variable "oci_password" {
  description = "Password or token for the OCI registry."
  type        = string
  sensitive   = true
}

variable "git_ssh_private_key" {
  description = "PRIVATE half of the SSH deploy key for the ApplicationSets repository, read from Key Vault by the caller. Preferred over username/password: the key belongs to the repository rather than to a person. When set, appsets_repo_url must be the SSH form. The public half goes on the repository as a read-only access key."
  type        = string
  default     = ""
  sensitive   = true
}
