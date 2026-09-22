output "namespace" {
  description = "Namespace ArgoCD was installed into."
  value       = var.namespace
}

output "release_name" {
  description = "Helm release name of the ArgoCD install."
  value       = helm_release.argocd.name
}

output "chart_version" {
  description = "argo-cd chart version installed."
  value       = helm_release.argocd.version
}

output "bootstrap_application_name" {
  description = "Name of the bootstrap Application. Everything else on this cluster descends from it."
  value       = "bootstrap"
}

output "appsets_source" {
  description = "Where this cluster's ApplicationSets are read from: repo, revision and path."
  value = {
    repo_url = var.appsets_repo_url
    revision = var.appsets_revision
    path     = var.appsets_path
  }
}
