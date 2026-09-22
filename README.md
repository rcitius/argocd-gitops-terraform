# ArgoCD GitOps — Terraform installs it, Git drives it

A production-shaped pattern for running ArgoCD on AKS: **Terraform owns the
platform, Git owns the applications**, and the boundary between them is a single
bootstrap Application.

Extracted from a live multi-tenant setup and genericised. Every identifier here
is a placeholder.

---

## The split

```
 TERRAFORM                                  GIT
 ---------                                  ---
 installs ArgoCD (pinned chart)             clusters/<cluster>/*.yaml
 creates the repo credentials               +- ApplicationSets
 creates ONE bootstrap Application ------>  values/*.yaml
                                            +- merged into the charts
 then stops.                                every later change is a PR.
```

Terraform runs once per cluster. After that, deploying an application — or a new
environment of one — is a merged pull request and nothing else. No pipeline step
applies manifests, no one runs `kubectl`, no credential leaves the cluster.

## How a change reaches a pod

```
  PR merged to the GitOps repo
        |
        |  ArgoCD polls (default 180s; no webhook needed into a private cluster)
        v
  bootstrap Application          watches one directory, recurse: true
        |                        automated + prune + selfHeal
        v
  ApplicationSet                 one element per environment
        |
        v
  Application                    chart from OCI registry + values from Git
        |
        v
  helm template -> diff against live state -> apply
        |
        v
  Deployment pod template changes -> Kubernetes rolls the pods
```

Measured on a real cluster: merge to 10 Deployments rolled, unchanged services
untouched, nothing restarted that did not need to be.

## Layout

```
terraform/
  modules/argocd/          the module: ArgoCD + credentials + bootstrap app
    main.tf
    variables.tf
    outputs.tf
    argocd-values.tpl.yaml
    bootstrap/             a 1-object local chart: the app-of-apps Application
  example/main.tf          a caller, with the reasoning inline

gitops/
  clusters/demo-dev/       what the bootstrap Application watches
    demo-app-appset.yaml
  values/                  NOT watched — see below
    base.yaml
    dev.yaml
```

## Design decisions worth explaining

**The bootstrap Application is a separate Helm release from ArgoCD itself.**
Helm resolves every manifest in a release against a discovery cache taken
*before* that release installs its CRDs. An `Application` shipped inside the
argo-cd release fails on a first install with `no matches for kind Application`.
Two releases, no ordering problem.

**Values files live outside the watched directory.** The bootstrap Application
syncs its directory with `recurse: true` and applies everything there as a
Kubernetes manifest. A values document has no `kind`, so putting one there
breaks the sync — and takes every app on that cluster with it. They sit under
`gitops/values/` and are reached through a second source declared `ref: values`.

**The GitOps repo is not the infrastructure repo.** An ArgoCD repository
credential grants read access to the *entire* repository. Pointing clusters at
the Terraform repo would hand every cluster a token that can read all of your
infrastructure code. A dedicated repo can read manifests and nothing else.

**One directory per cluster.** Two clusters pointed at one directory will each
deploy the other environments.

**The chart version pins the images.** Image tags are stamped into the chart
artifact at package time, so a chart version *is* an exact image set. There is
nothing image-related in values, and a rollback is a version change.

**`ignoreDifferences` on `/spec/replicas`.** The chart writes `replicas` and the
HPA immediately scales away from it. Without this the app sits permanently
OutOfSync and you stop trusting the status column. A sync still applies
replicas; only the UI diff is suppressed.

**CRDs are kept on uninstall** (`crds.keep: true`). Removing the ArgoCD release
would otherwise delete every Application and ApplicationSet on the cluster as a
side effect.

## Two failures worth inheriting

**`creationPolicy: Merge` fails silently.** The External Secrets `Merge` policy
does nothing at all when the target Secret does not exist — no error, no log.
A setup can appear to work only because something else pre-created an empty
Secret to merge into. Use `Owner` wherever a group is the sole producer of its
target, and know that `Owner` puts an `ownerReference` on the Secret: deleting
the CR then garbage-collects it and every pod referencing it fails to start.

**`set` blocks are not portable across Helm provider majors.** In the Terraform
Helm provider, `set` is a nested *block* in 2.x and an *argument* in 3.x, so a
module written with blocks silently only works on roots that happen to pin the
matching version. `values = [yamlencode({...})]` works on both — and preserves
string typing, where `--set` would turn a tag like `"1.0"` into the number `1`
and render an unresolvable `targetRevision: "1"`.

## Using it

```hcl
module "argocd" {
  source = "./terraform/modules/argocd"

  chart_version    = "10.4.0"
  appsets_repo_url = "git@github.com:example-org/gitops.git"
  appsets_revision = "main"
  appsets_path     = "clusters/demo-dev"

  git_ssh_private_key = var.gitops_deploy_key
  oci_registry_url    = "myregistry.azurecr.io/helm"
  oci_username        = var.registry_username
  oci_password        = var.registry_password
}
```

Then put an ApplicationSet in `clusters/demo-dev/` and merge. That is the whole
workflow.

### Prerequisites

- Public half of the SSH deploy key on the GitOps repo as a **read-only** key
- A registry token with `content/read` **and** `metadata/read` on the chart
  repositories — an image-pull-only token 401s on the chart pull while image
  pulls keep working

### Adopting an existing Helm release

If Terraform currently installs the app, drop it from state rather than letting
Terraform destroy it:

```bash
terraform state rm 'module.<name>.helm_release.<app>'
```

The release keeps running and ArgoCD adopts it on first sync — no downtime and
no pod churn. Setting the deploy flag to `false` *without* the `state rm` runs
`helm uninstall` and deletes every pod.

## Notes

- Verified with ArgoCD v3.5.1 (argo-cd chart 10.4.0) on AKS.
- The ArgoCD server runs plain HTTP behind an ingress that terminates TLS, so
  the CLI needs `--plaintext` (not `--insecure`). The declarative `kubectl` path
  works regardless and is what the examples use.

## License

MIT — see [LICENSE](LICENSE).
