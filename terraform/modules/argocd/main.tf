# =============================================================================
# ArgoCD — per-cluster GitOps controller
#
#   Git (appsets dir) ──► bootstrap Application ──► ApplicationSet(s) ──► Applications
#                                                            │
#   OCI registry (ACR) ────────── chart artifacts ───────────┘
#
# One ArgoCD instance per cluster. Every Application it generates targets the
# cluster ArgoCD itself runs on (destination in-cluster), so no cross-cluster
# credentials are stored anywhere.
#
# This module is the whole cluster-side setup and nothing more:
#   1. the ArgoCD install,
#   2. the two repository credentials it needs (OCI chart registry + Git),
#   3. the single bootstrap Application that makes a directory in Git
#      authoritative for this cluster.
#
# Everything past step 3 is driven by commits, not by Terraform. Adding an
# environment, changing a chart version or a log level is a change to the
# ApplicationSet in Git — this module never needs re-applying for that.
#
# Homes:
#   shared clusters     -> the cluster bootstrap root
#   dedicated clusters  -> the tenant onboarding root
#
# Both call this module identically; only the call site differs.
#
# DESTROY ORDER WARNING
# ---------------------
# ApplicationSets in Git generate Applications carrying
# resources-finalizer.argocd.argoproj.io. Those objects are created by ArgoCD,
# not by Terraform, so `terraform destroy` removes the release -- and the
# controller with it -- leaving those finalizers with nothing to process. The
# Applications then cannot be deleted, and anything they deployed is orphaned.
# Before destroying, empty the appsets directory in Git and let ArgoCD prune,
# or delete the generated Applications first:
#   kubectl -n argocd delete applications --all
# =============================================================================

locals {
  # An SSH URL cannot be read anonymously, so it must be paired with a key.
  repo_is_ssh = startswith(var.appsets_repo_url, "git@") || startswith(var.appsets_repo_url, "ssh://")
}

# The namespace is created by the Helm release itself (create_namespace below).
# Helm creates it only when absent, so this is idempotent on a cluster that
# already has an `argocd` namespace -- no existence check and no flag needed.
# Terraform cannot express "create only if missing" for a resource: a
# data source for a missing namespace is an error, not an empty result.
#
# Consequence worth knowing: Helm does not delete a namespace it created, so
# the namespace outlives `terraform destroy`. Given the finalizer hazard noted
# above, that is the safer default anyway.
removed {
  from = kubernetes_namespace.argocd

  lifecycle {
    # Forget the previously-managed namespace; do not delete it, which would
    # take ArgoCD and everything else in it with it.
    destroy = false
  }
}

# ----- Repository credentials --------------------------------------------
#
# Plain Kubernetes Secrets, read from Key Vault by the caller and handed in --
# the same shape as the other credential secrets the caller provisions.
#
# Deliberately not passed as Helm values: anything in Helm values ends up in
# the release's own secret and in plan output. ArgoCD finds repositories by
# label at runtime, so there is no ordering requirement against the release.

# Chart artifacts (ACR, OCI). The url carries no oci:// scheme -- ArgoCD
# derives that from enableOCI, and an Application's repoURL must match this
# string exactly.
resource "kubernetes_secret" "oci_charts" {
  metadata {
    name      = "repo-oci-charts"
    namespace = var.namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type      = "helm"
    name      = var.oci_registry_name
    url       = var.oci_registry_url
    enableOCI = "true"
    username  = var.oci_username
    password  = var.oci_password
  }

  depends_on = [helm_release.argocd]
}

# The Git repository holding this cluster's ApplicationSets.
#
# Two ways to authenticate. An SSH deploy key is preferred: it belongs to the
# repository rather than to a person, and it is read-only by nature. A
# username/password (a repository access token, used with
# x-token-auth) is the fallback where SSH is not an option.
locals {
  git_auth_ssh = var.git_ssh_private_key != ""

  git_secret_data = local.git_auth_ssh ? {
    type          = "git"
    name          = "appsets"
    url           = var.appsets_repo_url
    sshPrivateKey = var.git_ssh_private_key
    } : {
    type     = "git"
    name     = "appsets"
    url      = var.appsets_repo_url
    username = var.git_username
    password = var.git_password
  }
}

# Skipped entirely when neither credential is supplied, which covers a public
# repository. The precondition on the release below rejects the case where the
# repository is private (SSH) but no credential was handed in.
resource "kubernetes_secret" "git_appsets" {
  count = (local.git_auth_ssh || var.git_username != "") ? 1 : 0

  metadata {
    name      = "repo-git-appsets"
    namespace = var.namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = local.git_secret_data

  depends_on = [helm_release.argocd]
}

# ----- ArgoCD ------------------------------------------------------------
#
# The local-exec below primes Helm's local repository cache, as any module
# installing a remote chart should. It is not redundant: the helm
# provider resolves charts through the local repositories.yaml plus the cached
# index files, and it loads the index of every registered repo -- so a cold or
# partially-cleaned cache fails with "no cached repo found" naming whichever
# repo it stumbled on first, not the chart you asked for. That bites hardest
# on CI runners, where the cache starts empty every job.
#
# `helm repo update` refreshes every registered repo on purpose. Helm 3.12+
# does not fail when one of them is unreachable unless
# --fail-on-repo-update-fail is passed, so one stale entry on a runner cannot
# break this.
#
# The bootstrap Application is a SEPARATE release below, not part of this one.
# Helm resolves every manifest in a release against a discovery cache taken
# before that release installs its CRDs, so an Application shipped here fails
# with "no matches for kind Application" on a first install.
resource "null_resource" "helm_repo" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = "helm repo add argo https://argoproj.github.io/argo-helm && helm repo update"
  }
}

resource "helm_release" "argocd" {
  name       = var.release_name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version
  namespace  = var.namespace

  # Creates the namespace when it does not exist, and quietly uses it when it
  # does -- which is what makes enabling this on a cluster with a pre-existing
  # ArgoCD safe.
  create_namespace = true

  # Chart installs cluster-scoped CRDs; give it room on a busy cluster.
  timeout = var.helm_timeout_seconds

  # Skip Helm's client-side OpenAPI validation. This chart's CRDs are huge
  # (the ApplicationSet CRD alone is over a megabyte), and fetching the API
  # server's schema to validate against reliably times out with
  # "unexpected error when reading response body". Nothing is lost in terms of
  # safety: the API server still validates every object on apply.
  disable_openapi_validation = true

  values = [
    templatefile("${path.module}/argocd-values.tpl.yaml", {
      server_insecure = var.server_insecure
      enable_dex      = var.enable_dex
      enable_notifs   = var.enable_notifications
    })
  ]

  depends_on = [null_resource.helm_repo]

  lifecycle {
    # Callers carry XXX placeholders until the appsets repository and a pinned
    # chart version are agreed. Those only need to be real once someone
    # actually turns ArgoCD on, and this is evaluated only when the module is
    # instantiated -- so it stays inert while enable_argocd is false, and
    # gives a readable failure instead of "chart version XXX not found".
    precondition {
      condition = alltrue([
        var.chart_version != "XXX",
        var.appsets_repo_url != "XXX",
        var.appsets_revision != "XXX",
        var.appsets_path != "XXX",
      ])
      error_message = "ArgoCD is enabled but still has XXX placeholders. Set chart_version, appsets_repo_url, appsets_revision and appsets_path to real values."
    }

    # Without this, a missing credential produces a successful apply and an
    # ArgoCD that can never read the repository -- the failure surfaces only
    # as "failed to list refs" inside the cluster, hours later.
    precondition {
      condition     = !local.repo_is_ssh || local.git_auth_ssh
      error_message = "appsets_repo_url is an SSH URL, which cannot be read anonymously, but no git_ssh_private_key was supplied. Pass the deploy key, or use an https URL for a public repository."
    }

    # The credential type and the URL scheme have to agree.
    precondition {
      condition     = !local.git_auth_ssh || local.repo_is_ssh
      error_message = "An SSH deploy key was supplied, so appsets_repo_url must be the SSH form (git@host:workspace/repo.git), not https."
    }
  }
}

# Give the API server time to register the CRDs the release just installed,
# the same way helm-deployments/external-secrets waits for its own.
resource "time_sleep" "wait_for_crds" {
  depends_on      = [helm_release.argocd]
  create_duration = "30s"
}

# ----- Bootstrap Application ---------------------------------------------
#
# A tiny local chart holding one object. Separate release so its manifest is
# resolved after the Application CRD exists, and so it can be re-pointed at a
# different branch or path without touching the ArgoCD install.
#
# Values are passed as a document, not as set blocks: `set` is a nested BLOCK
# in helm provider 2.x but an ARGUMENT in 3.x, so a module written with blocks
# only works on roots that happen to pin 2.x. yamlencode works on both.
#
# It also keeps what `type = "string"` was doing here: yamlencode quotes a value
# like "1.0", whereas Helm's --set infers the number 1 and renders
# targetRevision: "1", which ArgoCD cannot resolve.
resource "helm_release" "bootstrap" {
  name      = "${var.release_name}-bootstrap"
  chart     = "${path.module}/bootstrap"
  namespace = var.namespace

  # Same reason as the release above: by this point the API server's OpenAPI
  # document includes ArgoCD's very large CRDs, and fetching it to validate a
  # single Application client-side is what times out.
  disable_openapi_validation = true

  values = [yamlencode({
    name      = "bootstrap"
    namespace = var.namespace
    repoUrl   = var.appsets_repo_url
    revision  = var.appsets_revision
    path      = var.appsets_path
  })]

  depends_on = [time_sleep.wait_for_crds]
}
