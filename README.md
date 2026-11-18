# dso202-gitops - GitOps delivery of the Task Tracker with Argo CD

## 1. Purpose

Assignments 1-3 produced a three-tier Task Tracker (database, backend, frontend), extended it with quotas, RBAC and Istio policy, and packaged it with Kustomize and Helm. In each one a person ran a command to get the application into the cluster. This repository removes that step: **Argo CD runs inside the cluster, reads the desired state from this repository, and makes the cluster match it.** After the two bootstrap commands, every change to the cluster is a commit.

What this repository does:

1. Installs Argo CD from versioned, declarative files (`bootstrap/argocd`).
2. Delivers the Task Tracker to **dev** (follows branch `main`, automated sync) and **staging** (pinned to a Git tag, manual sync).
3. Keeps database credentials in Git as **SealedSecrets**, never as plaintext.
4. Ships a release, survives a faulty release, and recovers with `git revert`.
5. Rebuilds the entire environment on a new cluster from this repository and one backed-up key.

### GitOps principles and where each is evidenced

| # | Principle | What it means here | Evidence |
|---|---|---|---|
| 1 | Declarative | Every object after bootstrap is described by a file; nothing is created with `kubectl create` | Tasks 3, 4, 5 |
| 2 | Versioned and immutable | Tool, chart and image versions are pinned; staging follows a tag; a release is a commit; recovery is a `git revert` | Tasks 2, 5, 7 |
| 3 | Pulled automatically | The cluster polls Git every 60 s; no pipeline or person pushes after bootstrap | Tasks 5, 7 |
| 4 | Continuously reconciled | A manual change in dev is reverted, in staging reported; a removed file is pruned | Task 8 |

## 2. Architecture

```
Laptop (Docker)
└── kind cluster "dso202-gitops" (single node, host port 30080 mapped)
    ├── namespace argocd            Argo CD, 7 Pods ───── polls ──────> GitHub: Rabtens/dso202-gitops (public)
    ├── namespace sealed-secrets    Sealed Secrets controller, 1 Pod (holds the sealing key)
    ├── namespace dso202-dev        Task Tracker, follows branch main     (automated sync)
    └── namespace dso202-staging    Task Tracker, pinned to a Git tag     (manual sync)
```

| Applied by hand, once per cluster | Delivered from Git by the `root` Application | Wave |
|---|---|---|
| `bootstrap/argocd` - Argo CD itself | `argocd/projects/dso202.yaml` - AppProject | -3 |
| `bootstrap/root` - `platform` AppProject and `root` Application | `argocd/applications/sealed-secrets.yaml` - controller | -2 |
| | `platform-dev`, `platform-staging` - namespace, quota, RBAC, credentials | -1 |
| | `tasktracker-dev`, `tasktracker-staging` - workloads | 0 |

Order matters: the `SealedSecret` kind does not exist until the controller is installed, and the namespace and credentials must exist before the workloads that read them. Inside a workload sync the chart orders itself: database (wave 0), backend (1), frontend (2), then a PostSync smoke test.

| Property | dev | staging |
|---|---|---|
| Namespace / Application | `dso202-dev` / `tasktracker-dev` | `dso202-staging` / `tasktracker-staging` |
| Git revision followed | branch `main` | tag (`v1.0.0` → `v1.1.0` → `v1.2.0`) |
| Sync | automated, prune + self-heal | manual |
| Values | `environments/dev/values.yaml` | `environments/staging/values.yaml` |
| Frontend | NodePort 30080 → http://localhost:30080 | NodePort 30081, `kubectl port-forward` |
| Credentials | SealedSecret in `platform/dev/` | separate SealedSecret in `platform/staging/` |

Two AppProjects enforce least privilege. **`platform`** (administrator level, applied by hand) owns the root, the controller and the platform objects and is the only project allowed to target `argocd`. **`dso202`** (created by the root) may only read this repository, deploy to the two environment namespaces, and create `Deployment`, `StatefulSet`, `Service`, `ConfigMap`, `ServiceAccount` and `Job`; it has no cluster-scoped kinds.

## 3. Repository layout

```
dso202-gitops/
├── README.md                    this file
├── .gitignore                   keeps keys and plaintext Secrets out of Git (first commit)
├── cluster/kind-cluster.yaml    single-node kind cluster, host port 30080 mapped
├── bootstrap/                   applied by hand, once per cluster
│   ├── argocd/                  namespace, kustomization (pinned v3.5.6), argocd-cm and argocd-rbac-cm patches
│   └── root/                    platform AppProject and the root Application
├── argocd/                      watched by the root Application
│   ├── projects/dso202.yaml
│   └── applications/            sealed-secrets, platform-{dev,staging}, tasktracker-{dev,staging}
├── platform/{dev,staging}/      namespace, quota and limits, RBAC, sealed credentials
├── charts/tasktracker/          the Assignment 3 chart, adjusted to the contract in section 5
├── environments/{dev,staging}/values.yaml
└── docs/
    ├── evidence.md              command output for every task
    └── screenshots/             the four required screenshots (and the optional ones)
```

Design rules followed: one concern per directory; environments differ only in values and in the Application's `targetRevision` (no `if env == "dev"` anywhere in a template); everything is pinned (no `latest`, `stable`, `master` or `HEAD` as a version); Argo CD objects are declared in Git; credentials appear only as SealedSecrets; every file starts with a comment header; the repository URL is spelled identically everywhere (`https://github.com/Rabtens/dso202-gitops.git`).

## 4. Pinned versions

| Component | Version |
|---|---|
| Argo CD (server and `argocd` CLI) | v3.5.6 |
| Sealed Secrets Helm chart | 2.20.0 (installs controller 0.40.0) |
| `kubeseal` CLI | v0.40.0 |
| Task Tracker images | `sarojsanyasi/dso202-{frontend,backend}`: 1.0 → 1.1 (Task 7); `dso202-db`: 1.0 |
| Smoke-test image | `busybox:1.37` |
| kind, kubectl, Helm | as used in Practical 1 and Assignment 3 |

## 5. Chart contract (how the Assignment 3 chart was adjusted)

| # | Requirement | Where it is satisfied |
|---|---|---|
| C1 | Image repository and tag are values for each tier | `values.yaml` `*.image.repository/tag`; `_helpers.tpl` `task-tracker.image` has no tag of its own |
| C2 | Per-tier config from values | `backend.env`, `frontend.env` (maps rendered in `backend.yaml`, `frontend.yaml`) |
| C3 | Chart never renders a Secret | `secret.yaml` deleted; pods read `existingSecret` (`tasktracker-credentials`) via `secretKeyRef` |
| C4 | Readiness probes on all tiers | `database.yaml` (`pg_isready`), `backend.yaml` (`/api/status`), `frontend.yaml` (`/`) |
| C5 | Sync waves | db `"0"`, backend `"1"`, frontend `"2"` (Deployment/StatefulSet and Service of each tier) |
| C6 | `progressDeadlineSeconds: 120` | `backend.yaml`, `frontend.yaml` |
| C7 | Requests and limits on every container | `*.resources` values; smoke-test Job has its own |
| C8 | No Namespace, Quota, LimitRange, Role, RoleBinding | moved to `platform/<env>/`; chart keeps only the three Pod ServiceAccounts |
| C9 | Ingress disabled by default | `ingress.enabled: false`; template renders nothing |
| C10 | Frontend Service NodePort, number is a value | `frontend.service.nodePort` (30080 dev, 30081 staging) |
| C11 | `helm lint` clean, `helm template` works for both | verified in `docs/evidence.md`, Task 1 |

### 5.1 What was carried over from Assignments 1-3

| Source | What | Where it is now |
|---|---|---|
| A1 `frontend/nginx-configmap.yaml` | nginx `/backend/` same-origin proxy (the "backend unreachable" fix) | `templates/frontend-nginx-configmap.yaml`, mounted by `frontend.yaml`. Needed because this assignment has no ingress controller |
| A1 `quota.yaml` | ResourceQuota and LimitRange, with the "pods × defaults" sizing rationale | `platform/<env>/quota-and-limits.yaml` (LimitRange minimum lowered, pod limit raised to 8; reasons in the file) |
| A1 `configmap.yaml`, A2 `configmap.yaml` | `DB_HOST`, `DB_NAME`, `APP_PORT`, `BACKEND_URL=/backend`, … | `templates/configmap.yaml` (values in `values.yaml` → `config`); `DB_HOST=db-0.db-headless` as in A2 |
| A1 `secret.yaml`, A2 `secret.yaml` | `DB_USER`, `DB_PASSWORD`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | Same four key names, now supplied by a SealedSecret named `tasktracker-credentials` |
| A2 `database/statefulset.yaml` | `db` StatefulSet, `db-headless` Service, `pg_isready` probes, PVC retention | `templates/database.yaml` |
| A2 `backend/deployment.yaml`, `frontend/deployment.yaml` | probes (startup, readiness on `/api/status`, TCP liveness), rolling-update strategy, resources, ServiceAccounts, `version: v1` label | `templates/backend.yaml`, `templates/frontend.yaml`, `templates/serviceaccounts.yaml` |
| A2 `rbac.yaml` | ServiceAccounts, Roles, RoleBindings | Roles, RoleBindings and `ci-deployer`/`taskbackup-runner` in `platform/<env>/rbac.yaml`; the three Pod ServiceAccounts stay in the chart |
| A3 `helm/task-tracker` | the chart, helpers, values schema | `charts/tasktracker/` (chart name `task-tracker`), adjusted to the contract |

Left out on purpose: the Ingress and TLS Secret, the Istio policies and the TaskBackup operator of Assignment 2 (none is installed here); in the chart `templates/secret.yaml`, `templates/rbac.yaml`, `templates/istio.yaml` and the `helm test` Pod (a bare `Pod` is not in the project whitelist; the PostSync smoke-test Job replaces it). `ingress.yaml` stays, disabled.

## 6. Build the whole environment from an empty machine

This is the sequence practised in Task 9. Prerequisites: Docker (≥ 6 GB memory, `docker login` done), `kind`, `kubectl`, `helm`, `git`, `argocd` v3.5.6, `kubeseal` v0.40.0.

```bash
# 1. Get the repository
git clone https://github.com/Rabtens/AS2025_DSO202_02230289_Assignment-04
cd dso202-gitops
```

```
# 2. Create the cluster (host port 30080 is mapped)
kind create cluster --name dso202-gitops --config cluster/kind-cluster.yaml
```
![alt text](<evidences/Screenshot from 2026-11-18 17-37-25.png>)

```
# 3. Restore the sealing key BEFORE the controller exists (skip on a first-ever build)
kubectl create namespace sealed-secrets
kubectl apply -f ../dso202-keys/sealing-key.backup.yaml
```
![alt text](<evidences/Screenshot from 2026-11-18 18-38-03.png>)

```
# 4. Bootstrap, part 1: Argo CD from the pinned Kustomize files (server-side apply is required)
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
```
![alt text](<evidences/Screenshot from 2026-11-18 19-29-07.png>)

```
# 5. Bootstrap, part 2: the platform project and the root Application. Nothing else is applied by hand.
kubectl apply -f bootstrap/root
kubectl get applications -n argocd -w          # Applications appear in wave order

# 6. Sign in (separate terminal for the port-forward) and synchronise staging, which is manual by design
kubectl port-forward svc/argocd-server -n argocd 8080:443
argocd admin initial-password -n argocd
argocd login localhost:8080 --username admin --insecure
argocd app sync tasktracker-staging

# 7. Verify
kubectl get applications -n argocd             # all Synced and Healthy
kubectl get pods -n dso202-dev
kubectl get pods -n dso202-staging
curl -s http://localhost:30080 | head          # dev frontend
kubectl port-forward -n dso202-staging svc/frontend-svc 8081:8080   # staging frontend at http://localhost:8081
```

First-ever build only: after step 5 the controller starts and creates a new sealing key; back it up (`kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ../dso202-keys/sealing-key.backup.yaml; chmod 600 …`), then seal the credentials of each environment (section 8) and commit them.

## 7. Cleanup

```bash
argocd app delete root --cascade -y     # or: kubectl delete -f bootstrap/root (the finalizer deletes every child and workload)
kind delete cluster --name dso202-gitops
# PersistentVolumeClaims created by the StatefulSet are not tracked by Argo CD; they disappear with the cluster.
rm -f ../dso202-keys/sealing-key.backup.yaml   # only when the environment is finished with for good
```

Deleting the root Application deletes every Application and, through their finalizers, every workload. This is intentional and must never be done casually.

## 8. How credentials are handled

* The chart never renders a Secret. Pods read `tasktracker-credentials` (an *existing* Secret, named by `existingSecret`).
* That Secret is created **inside the cluster** by the Sealed Secrets controller from a `SealedSecret` file committed in `platform/<env>/`. The ciphertext is encrypted with the controller's public key and can only be decrypted by the controller of the cluster it was sealed for.
* Scope is *strict* (the default): the name and namespace are part of the encrypted payload, so dev and staging are sealed separately, with different passwords.
* The plaintext lives only in `secrets-plain/*.env` (listed in `.gitignore`, mode 600, deleted after sealing; the values are kept in a password manager). The plaintext Secret is never written to disk: `kubectl create secret … --dry-run=client -o yaml | kubeseal --format yaml > platform/<env>/tasktracker-credentials.sealed.yaml`.
* The sealing key is backed up to `../dso202-keys/` **outside the repository**, mode 600, after every key renewal (every 30 days) and before any rebuild. It is never committed, pasted or stored in an unencrypted cloud folder.
* Proof that no plaintext reached Git: a `git log -p --all -S'<value>'` search for every distinct value (and its base64 form) prints nothing (recorded in `docs/evidence.md`, Task 4).

## 9. Written answers

### Q1 — Why is the `platform` project applied by hand while `dso202` is created by the root Application, and what risk arises if `dso202` may deploy into the `argocd` namespace?

Argo CD can only create an Application inside a project that already exists, and the root Application itself must belong to a project, so something has to exist before Argo CD can read anything from Git. That is the bootstrap problem: `platform` and `root` are the two objects that cannot come from Git because Git is read *through* them, so they are applied by hand (and they live in `bootstrap/`, in Git, so the hand step is still reviewable). `dso202` has no such dependency. Creating it from `argocd/projects/` (sync wave -3, before any Application that refers to it) means the workload boundary is itself versioned, reviewed in a pull request and restored by self-heal if someone edits it.

If `dso202` were allowed to deploy into `argocd`, any Application in it could write `Application` and `AppProject` objects into the Argo CD namespace. An Application in `argocd` can name any project, including `platform`, whose destinations and cluster-scoped whitelist are unrestricted. A single mistaken or malicious commit to the chart would therefore be able to create an Application in `platform` that deploys a Namespace, ClusterRole or CRD, or loosen `dso202`'s own whitelist. That is administrator capability, which is why only `platform` may target `argocd`.

### Q2 — What does strict scope prevent, what is lost if the sealing key is lost, and what must be done?

Strict scope binds the encrypted payload to the Secret's **name and namespace**. A SealedSecret for `dso202-dev/tasktracker-credentials` cannot be decrypted if it is renamed or applied in `dso202-staging`. This prevents someone who can create objects in one namespace from copying a SealedSecret out of another (it is in a public repository) and having the controller decrypt it for them, and it prevents the dev password from being used to populate staging.

If the sealing key is lost, **every SealedSecret in Git becomes permanently unreadable**: a new or rebuilt cluster gets a fresh key and answers `no key could decrypt secret`. Secrets already unsealed in a running cluster keep working until that cluster is lost, but nothing can be restored from Git. What must be done: restore the key from the backup if one exists (this is why the backup, taken before every rebuild and after every 30-day renewal, matters); otherwise let the new controller generate a key, **re-seal every Secret from the original plaintext values** (kept in the password manager) with `kubeseal` against the new certificate, commit the new files, and rotate the credentials if the originals cannot be recovered. The old ciphertext in Git history is harmless but useless.

### Q3 — Synced versus Healthy, with an example

**Synced** answers "does the live state equal the desired state in Git?" — a comparison of objects. **Healthy** answers "are the live objects working?" — an assessment of readiness (for a Deployment, that the rollout completed and replicas are available). They are independent: an Application can be Synced and Degraded (the cluster is exactly what Git says, and what Git says is broken), or OutOfSync and Healthy (a working system that no longer matches Git, such as staging after a new tag is committed but before it is synced).

Example from this assignment: in Task 7, part B, the merged backend `1.1` commit makes `tasktracker-dev` **Synced** (the live Deployment matches `main` exactly) but **Degraded** (the new backend Pod never becomes ready and the Deployment exceeds `progressDeadlineSeconds: 120`). The output is recorded in `docs/evidence.md`, Task 5 (Q3) and Task 7, step 5. It can be provoked at any time by committing an image tag that does not start, and it is undone by `git revert`, not by editing the cluster.

### Q4 — Argo CD RBAC versus Kubernetes RBAC, and what would change with SSO?

**Argo CD RBAC** controls what an *Argo CD user* may do inside Argo CD: view, sync, override or delete Applications, read projects, repositories and clusters, and (since 3.0) read logs. It is configured in the `argocd-rbac-cm` ConfigMap (`policy.csv`, `policy.default`) with accounts declared in `argocd-cm`; in this repository both are patched by `bootstrap/argocd`. **Kubernetes RBAC** controls what a *Kubernetes subject* (a user, group or ServiceAccount) may do to objects through the API server. It is configured with `Role`, `RoleBinding`, `ClusterRole` and `ClusterRoleBinding` objects, here in `platform/<env>/rbac.yaml`. They are separate layers: a reviewer who has no Argo CD permission to sync cannot deploy even though the Argo CD application controller itself holds broad Kubernetes permissions, and a developer with Kubernetes rights can still change objects directly with `kubectl` unless Kubernetes RBAC forbids it, which is why Argo CD RBAC governs *what reaches* the cluster and Kubernetes RBAC governs *direct access*.

With SSO the subjects change. Identity comes from the organisation's identity provider (OIDC through `oidc.config` or Dex in `argocd-cm`), so the `reviewer` local account would be replaced by IdP **groups**: `policy.csv` would hold group rules such as `g, <idp-group-name>, role:dso202-viewer` plus `p, role:dso202-viewer, applications, get, dso202/*, allow`, `argocd-rbac-cm` would set `scopes: '[groups]'` so the group claim is read, and the local `accounts.reviewer` and the built-in `admin` account would normally be disabled. Nothing in the policy language changes; only who the subject is.

### Q5 — Why is `argocd app rollback` refused, what is the GitOps equivalent, and why `git revert`?

`argocd app rollback` redeploys an earlier *recorded sync* to the cluster without changing Git. With automated sync enabled this is contradictory: the very next comparison would find the cluster different from `main` and sync it straight back, so Argo CD refuses and states that rollback cannot be performed against an Application with automated sync enabled. Git is the source of truth, so recovery has to be made in Git.

The GitOps equivalent is a new commit that restores the previous desired state: `git revert <bad-commit>` on a branch, a pull request, a merge, and Argo CD pulls the result. Revert is preferred to deleting the bad commit from history because (1) history stays complete and immutable (principle 2): the faulty release and its recovery both remain as an audit trail; (2) deleting would require rewriting and force-pushing `main`, which breaks every clone and any tag or revision already referenced (staging's tags, Argo CD's cached commits); (3) the revert is an ordinary, reviewable change that goes through the same pull-request gate as any release; and (4) the evidence of what failed, and why, is not erased.

### Q6 — (a) Single repository versus separated configuration; (b) what is not under GitOps control

**(a) Advantages of one repository here:** (1) A release is one reviewed commit that changes the chart and the values together, and a tag such as `v1.1.0` pins both consistently, so staging cannot get a chart that does not match its values. (2) One repository is simpler to run, clone, rebuild and prove (one URL in every `sourceRepos`, one history to inspect), which suits a single-person project.
**Disadvantages:** (1) Configuration changes and chart changes share one commit stream and one set of permissions: anyone who can change a dev value can change the chart and the staging Application, and configuration cannot be given to a different team with different write access. (2) Every commit, including a values-only change for dev, makes Argo CD re-fetch and re-render every Application that reads the repository (unless `manifest-generate-paths` is set), and the history mixes application packaging, environment configuration and platform changes, which makes it noisier to review and to revert selectively.

**(b) Not under GitOps control after the rebuild, and how a production team handles it:**

| Item | Why it is outside Git | Usual production handling |
|---|---|---|
| Bootstrap layer (Argo CD install, `argocd-cm`/`argocd-rbac-cm` patches) | Applied by hand with `kubectl apply -k` | Cluster-provisioning pipeline (Terraform, Cluster API, a bootstrap job), then Argo CD manages itself through an Application |
| `root` Application and `platform` project | Must exist before Argo CD can read Git | Created by the same provisioning tooling, or by a cluster-level ApplicationSet |
| Sealing key | A secret by definition; cannot be in Git | Encrypted backup in a vault/KMS-backed store with access control, taken after every renewal, or replaced by an external secrets manager |
| Database contents | Application data, not configuration | Scheduled backups (`pg_dump`, WAL archiving, volume snapshots or a Postgres operator) with tested restores |
| Argo CD passwords (admin, `reviewer`) | Set with the CLI, stored in a cluster Secret | SSO with IdP groups, local accounts disabled |
| The kind cluster itself | Created by a command | Infrastructure as code for the cluster definition |

## 10. Step-by-step walkthrough

The marking checks the commit history ("one or two large commits is not accepted"), so the finished files are **not** copied into your repository all at once. The unzipped pack looks like this:

```
DSO202_Assignment4_02230289/            <- $PACK
├── dso202-gitops/                      the finished repository, exactly the layout of section 3 (README.md is this file)
└── extras/                             NOT part of the repository; never commit these
    ├── scripts/                        tool-check.sh, backup-sealing-key.sh, seal-credentials.sh, history-scan.sh, rebuild-from-git.sh
    ├── drill-files/                    prune-drill.yaml and drill-quota.yaml (Task 8)
    └── examples/                       illustration of a SealedSecret (Listing 12 shape)
```

`dso202-gitops/` holds every finished file, but your own clone starts empty and receives them task by task. The files in `extras/` are helpers and drill inputs. You copy files into your own clone in the order of the tasks below and commit after each step.

```bash
export PACK=~/DSO202_Assignment4_02230289   # the folder you unzipped (it contains dso202-gitops/ and extras/)
export GH_USER=Rabtens
```

The GitHub user name (`Rabtens`) and the image names (`sarojsanyasi/dso202-*`, taken from your Assignment 1–3 manifests) are already filled in; check the image names against what the module tutor issued. Nothing here has been run against a real cluster: commands and expected results come from the assignment brief, so trust your own output where it differs. Paste each command's output into the matching block of `docs/evidence.md` (copy it to your repository in Task 1 step 7), and save the screenshots named in the slots below.

**Before Task 1:** raise Docker Desktop memory to at least 6 GB (section 4). Task 1 tells you when to delete the old `dso202` cluster; it never mapped port 30080, but it would compete for memory.

---

### Task 1 — Repository, chart contract, cluster

```bash
# 1. empty public repo on GitHub named dso202-gitops, then:
git clone https://github.com/$GH_USER/dso202-gitops.git
cd dso202-gitops
git branch -M main

# 2. FIRST commit: .gitignore only
cp $PACK/dso202-gitops/.gitignore .
git add .gitignore && git commit -m "Add .gitignore: keep keys and plaintext Secrets out of Git"
git push -u origin main

# 3. the chart (the smoke test is added in Task 5, so leave it out for now)
mkdir -p charts && cp -r $PACK/dso202-gitops/charts/tasktracker charts/
rm charts/tasktracker/templates/smoke-test-job.yaml      # the pack copy stays untouched; the file is added in Task 5
git add charts && git commit -m "Add Task Tracker Helm chart (from Assignment 3) adjusted to the GitOps chart contract"

# 4. environment values
cp -r $PACK/dso202-gitops/environments .
git add environments && git commit -m "Add per-environment values for dev and staging"

# 5. platform manifests (namespace, quota and limits, RBAC); sealed credentials come in Task 4
cp -r $PACK/dso202-gitops/platform .
git add platform && git commit -m "Add platform manifests: namespaces, quota, limits and RBAC for dev and staging"

# 6. kind configuration (single node, port 30080 mapped: a NEW cluster is required)
cp -r $PACK/dso202-gitops/cluster .
git add cluster && git commit -m "Add kind cluster configuration (single node, NodePort 30080 mapped)"

# 7. this README and the evidence file the brief requires, plus the folder for screenshots
cp $PACK/dso202-gitops/README.md .
mkdir -p docs/screenshots && cp $PACK/dso202-gitops/docs/evidence.md docs/ && touch docs/screenshots/.gitkeep
git add README.md docs && git commit -m "Add README and evidence template"
git push
```

Tool check, lint, kinds and cluster (evidence items 1.1 – 1.6):

```bash
bash $PACK/extras/scripts/tool-check.sh
helm lint charts/tasktracker -f environments/dev/values.yaml
helm lint charts/tasktracker -f environments/staging/values.yaml
helm template tasktracker charts/tasktracker -f environments/dev/values.yaml | grep '^kind:' | sort | uniq -c
kind get clusters
kind delete cluster --name dso202          # only if it exists: frees memory; your old cluster did not map 30080 but would clash on resources
kind create cluster --name dso202-gitops --config cluster/kind-cluster.yaml
kubectl config current-context             # kind-dso202-gitops
kubectl get nodes
docker ps --filter name=dso202-gitops --format '{{.Names}}   {{.Ports}}'
```

The helper scripts are not part of the section 3 layout, so they stay in the pack and are run from the root of your clone: `bash $PACK/extras/scripts/<name>.sh`.

![kubectl get nodes and the 30080 port mapping](docs/screenshots/t1-nodes-and-port.png)

> 📸 **Screenshot:** save as `docs/screenshots/t1-nodes-and-port.png` — kubectl get nodes and the 30080 port mapping.

### Task 2 — Argo CD

```bash
mkdir -p bootstrap && cp -r $PACK/dso202-gitops/bootstrap/argocd bootstrap/   # bootstrap/root comes in Task 3
git add bootstrap/argocd && git commit -m "Add Argo CD bootstrap: pinned v3.5.6 Kustomize install with local settings"
git push

kubectl kustomize bootstrap/argocd | grep -E '^kind: (Deployment|StatefulSet)$' | sort | uniq -c
kubectl kustomize bootstrap/argocd | grep 'image:' | sort -u
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl get pods -n argocd
kubectl get crd | grep argoproj.io
# terminal 2 (keeps running):
kubectl port-forward svc/argocd-server -n argocd 8080:443
# terminal 1:
argocd admin initial-password -n argocd
argocd login localhost:8080 --username admin --insecure
kubectl get configmap argocd-cm -n argocd -o yaml | grep -E 'timeout.reconciliation|accounts.reviewer'
argocd version
```
Screenshot: UI at https://localhost:8080 after signing in → `docs/screenshots/02-argocd-ui.png`.

![Argo CD UI after signing in (required)](docs/screenshots/02-argocd-ui.png)

> 📸 **Screenshot:** save as `docs/screenshots/02-argocd-ui.png` — Argo CD UI after signing in (required).

### Task 3 — Projects and the root Application

```bash
cp -r $PACK/dso202-gitops/bootstrap/root bootstrap/
mkdir -p argocd/projects && cp $PACK/dso202-gitops/argocd/projects/dso202.yaml argocd/projects/
git add bootstrap/root argocd/projects
git commit -m "Add platform project, root Application and the dso202 workload project"
git push origin main                       # the root reads argocd/ from GitHub, so push BEFORE applying

kubectl apply -f bootstrap/root
kubectl get appproject,application -n argocd
argocd app get root
argocd proj get dso202
```
Note: until `argocd/applications/` exists the root has nothing to create besides the project; a warning about an empty directory is normal. Screenshot: root resource tree → `03-root-resource-tree.png`. Q1 is answered in section 9.

![root Application resource tree (required)](docs/screenshots/03-root-resource-tree.png)

> 📸 **Screenshot:** save as `docs/screenshots/03-root-resource-tree.png` — root Application resource tree (required).

### Task 4 — Platform layer and Sealed Secrets

```bash
# 1. controller through Git
mkdir -p argocd/applications && cp $PACK/dso202-gitops/argocd/applications/sealed-secrets.yaml argocd/applications/
git add argocd/applications && git commit -m "Add Sealed Secrets controller Application (chart 2.20.0)" && git push
argocd app get root --refresh
kubectl get applications -n argocd
kubectl get pods -n sealed-secrets
kubectl get crd sealedsecrets.bitnami.com

# 2. back up the sealing key BEFORE sealing anything (outside the repository)
bash $PACK/extras/scripts/backup-sealing-key.sh
ls -l ../dso202-keys/

# 3. plaintext inputs: type the values in an editor, not on the command line.
#    Different passwords for dev and staging. DB_* and POSTGRES_* must match within each file.
mkdir -p secrets-plain
${EDITOR:-nano} secrets-plain/dev.env        # DB_USER= DB_PASSWORD= POSTGRES_USER= POSTGRES_PASSWORD=
${EDITOR:-nano} secrets-plain/staging.env
chmod 600 secrets-plain/*.env

# 4. seal each file for its own namespace
bash $PACK/extras/scripts/seal-credentials.sh dev
bash $PACK/extras/scripts/seal-credentials.sh staging
git add platform/dev/tasktracker-credentials.sealed.yaml platform/staging/tasktracker-credentials.sealed.yaml
git commit -m "Add sealed credentials for dev and staging"

# 5. history scan BEFORE deleting the plaintext, then delete it
bash $PACK/extras/scripts/history-scan.sh       # every count must be 0
rm secrets-plain/*.env                          # keep the values in a password manager

# 6. platform Applications
cp $PACK/dso202-gitops/argocd/applications/platform-*.yaml argocd/applications/
git add argocd/applications && git commit -m "Add platform-dev and platform-staging Applications"
git push
kubectl get applications -n argocd
kubectl get namespaces | grep dso202
kubectl get sealedsecret -n dso202-dev
kubectl describe secret tasktracker-credentials -n dso202-dev
kubectl get resourcequota,limitrange -n dso202-dev
```
Choose NEW passwords (the Assignment 1/2 password is public). Do not use `secrets-plain/` or `*-plain.yaml` names anywhere else; they are in `.gitignore`. Q2 is answered in section 9 of this README.

![platform-dev and platform-staging Synced and Healthy](docs/screenshots/t4-applications-healthy.png)

> 📸 **Screenshot:** save as `docs/screenshots/t4-applications-healthy.png` — platform-dev and platform-staging Synced and Healthy.

### Task 5 — Workloads

```bash
# smoke test (held back in Task 1)
cp $PACK/dso202-gitops/charts/tasktracker/templates/smoke-test-job.yaml charts/tasktracker/templates/
helm template tasktracker charts/tasktracker -f environments/dev/values.yaml | grep -B2 -A3 'kind: Job'
git add charts && git commit -m "Add PostSync smoke-test Job (backend-svc, GET /api/tasks)"
git push origin main

# baseline tag: it must contain the chart, the smoke test AND environments/staging/values.yaml
git tag -a v1.0.0 -m "Baseline release: images 1.0"
git push origin v1.0.0
git ls-remote --tags origin

# the two Applications
cp $PACK/dso202-gitops/argocd/applications/tasktracker-*.yaml argocd/applications/
git add argocd/applications && git commit -m "Add tasktracker-dev (main, automated) and tasktracker-staging (tag v1.0.0, manual) Applications"
git push

# two terminals
kubectl get applications -n argocd -w
kubectl get pods -n dso202-dev -w
kubectl get job -n dso202-dev
kubectl logs job/tasktracker-smoke-test -n dso202-dev
argocd app get tasktracker-dev
# dev frontend: http://localhost:30080 (do a create / read / update / delete cycle)

# staging
argocd app get root                       # state BEFORE the first staging sync
argocd app get tasktracker-staging
argocd app sync tasktracker-staging
kubectl get svc -n dso202-staging
kubectl port-forward -n dso202-staging svc/frontend-svc 8081:8080     # http://localhost:8081
argocd app get root                       # state AFTER
```
Screenshot: tasktracker-dev resource tree → `05-tasktracker-dev-tree.png`. Q3 is answered in section 9; paste the Synced/Degraded output from Task 7 into evidence 5.7.

![tasktracker-dev resource tree (required) and the dev page at localhost:30080](docs/screenshots/05-tasktracker-dev-tree.png)

> 📸 **Screenshot:** save as `docs/screenshots/05-tasktracker-dev-tree.png` — tasktracker-dev resource tree (required) and the dev page at localhost:30080.

### Task 6 — Argo CD access control

```bash
argocd account list
argocd account update-password --account reviewer
argocd login localhost:8080 --username reviewer --insecure --name reviewer
argocd --argocd-context reviewer app list
argocd --argocd-context reviewer account can-i get applications 'dso202/tasktracker-dev'
argocd --argocd-context reviewer account can-i sync applications 'dso202/tasktracker-dev'
argocd --argocd-context reviewer account can-i get logs 'dso202/tasktracker-dev'
argocd --argocd-context reviewer proj get platform
# open https://localhost:8080 in a private window as reviewer: Sync refused, logs hidden

# enable the logs rule by a commit (PR as in Task 7, or directly on main for this one)
git checkout -b feature/reviewer-logs
sed -i 's/^    # p, reviewer, logs, get/    p, reviewer, logs, get/' bootstrap/argocd/argocd-rbac-cm-patch.yaml
git diff
git commit -am "Grant reviewer read access to logs of the dso202 project"
git push -u origin feature/reviewer-logs
gh pr create --fill --base main && gh pr merge --squash --delete-branch && git checkout main && git pull

# this ConfigMap is part of the hand-applied bootstrap layer, so apply it again by hand
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
argocd --argocd-context reviewer account can-i get logs 'dso202/tasktracker-dev'   # yes
# if still "no" after a minute: kubectl rollout restart deployment argocd-server -n argocd

# back to the admin session
argocd login localhost:8080 --username admin --insecure
```
Screenshot: reviewer session showing Pod logs → `06-reviewer-logs.png`. If you use another CLI for pull requests, the web UI works equally well. Q4 is answered in section 9.

![reviewer session showing Pod logs (required)](docs/screenshots/06-reviewer-logs.png)

> 📸 **Screenshot:** save as `docs/screenshots/06-reviewer-logs.png` — reviewer session showing Pod logs (required).

### Task 7 — Release, faulty release, recovery (every change through a pull request)

Helper (paste once per terminal): sets the image tag of one tier in both values files.

```bash
retag() { tier=$1; tag=$2; for e in dev staging; do
  awk -v t="$tier" -v v="$tag" '/^[a-z]/{f=($1==t":")} f&&/tag:/{sub(/"[0-9.]+"/,"\"" v "\"")}1' \
    environments/$e/values.yaml > /tmp/v && mv /tmp/v environments/$e/values.yaml; done; }
pr() { git commit -am "$1" && git push -u origin "$2" && gh pr create --fill --base main && gh pr merge --squash --delete-branch && git checkout main && git pull; }
```

**Part A — frontend 1.1 with promotion**

```bash
git checkout -b release/frontend-1.1
retag frontend 1.1 && git diff --stat
pr "Release frontend 1.1 in dev and staging values" release/frontend-1.1
kubectl get pods -n dso202-dev -w
argocd app get tasktracker-dev --refresh
argocd app history tasktracker-dev
# staging has NOT changed: it reads tag v1.0.0

git tag -a v1.1.0 -m "Release: frontend 1.1" && git push origin v1.1.0
git checkout -b promote/staging-v1.1.0
sed -i 's/targetRevision: v1.0.0/targetRevision: v1.1.0/' argocd/applications/tasktracker-staging.yaml
pr "Promote staging to v1.1.0" promote/staging-v1.1.0
argocd app get root --refresh
argocd app get tasktracker-staging          # OutOfSync, nothing deployed; :8081 still shows the old header
argocd app sync tasktracker-staging
```

**Part B — backend 1.1 fails, recovery by git revert, fix forward**

```bash
git checkout -b release/backend-1.1
retag backend 1.1
pr "Release backend 1.1 in dev and staging values" release/backend-1.1
git log --oneline -n 3                      # note the SHA of this commit: the BAD commit

# observe and do NOT intervene
kubectl get pods -n dso202-dev -w
argocd app get tasktracker-dev
kubectl get applications -n argocd
# diagnose
kubectl get pods -n dso202-dev
kubectl describe pod <new-backend-pod> -n dso202-dev
kubectl logs <new-backend-pod> -n dso202-dev      # record the exact line that says what the image requires
argocd app rollback tasktracker-dev               # record the refusal

# recover through Git
git checkout -b revert/backend-1.1
git revert --no-edit <bad-commit-sha>        # add -m 1 if the PR was merged with a merge commit, not squashed
git push -u origin revert/backend-1.1
gh pr create --fill --base main && gh pr merge --squash --delete-branch && git checkout main && git pull
argocd app get tasktracker-dev     # back to Healthy on the baseline backend

# fix forward: 1.1 again, plus what the log required, as a VALUE (chart contract C2)
git checkout -b fix/backend-1.1-config
retag backend 1.1
${EDITOR:-nano} environments/dev/values.yaml
${EDITOR:-nano} environments/staging/values.yaml
#   under  backend:  add
#     env:
#       <NAME_FROM_THE_LOG>: "<value>"
pr "Release backend 1.1 with the setting it requires" fix/backend-1.1-config
argocd app get tasktracker-dev     # Healthy, smoke test passes

# promote the fixed release
git tag -a v1.2.0 -m "Release: backend 1.1 with required setting" && git push origin v1.2.0
git checkout -b promote/staging-v1.2.0
sed -i 's/targetRevision: v1.1.0/targetRevision: v1.2.0/' argocd/applications/tasktracker-staging.yaml
pr "Promote staging to v1.2.0" promote/staging-v1.2.0
argocd app sync tasktracker-staging
argocd app history tasktracker-staging       # no revision with the faulty backend
git log --oneline --graph --decorate -n 15
gh pr list --state merged --limit 20
```
Staging never ran the faulty backend because it reads tag `v1.1.0` (frontend only) until you promote `v1.2.0`. The tags v1.0.0, v1.1.0 and v1.2.0 must all be on GitHub at submission.

![tasktracker-dev Degraded, then Healthy after the revert](docs/screenshots/t7-degraded-and-recovered.png)

> 📸 **Screenshot:** save as `docs/screenshots/t7-degraded-and-recovered.png` — tasktracker-dev Degraded, then Healthy after the revert.

### Task 8 — Drills (write the prediction BEFORE running; predictions are pre-filled in evidence.md, edit them to your own words)

```bash
# Drill 1 — start the watch first
kubectl get deployment -n dso202-dev
kubectl scale deployment/backend -n dso202-dev --replicas=3
kubectl get deployment/backend -n dso202-dev -w

# Drill 2
kubectl scale deployment/backend -n dso202-staging --replicas=3
argocd app get tasktracker-staging
argocd app diff tasktracker-staging
argocd app sync tasktracker-staging

# Drill 3
cp $PACK/extras/drill-files/prune-drill.yaml platform/dev/
git add platform/dev/prune-drill.yaml && git commit -m "Drill 3: add prune-drill ConfigMap" && git push
kubectl get configmap prune-drill -n dso202-dev
git rm platform/dev/prune-drill.yaml && git commit -m "Drill 3: remove prune-drill ConfigMap" && git push
kubectl get configmap prune-drill -n dso202-dev

# Drill 4
cp $PACK/extras/drill-files/drill-quota.yaml charts/tasktracker/templates/
git add charts && git commit -m "Drill 4: add a ResourceQuota to the chart" && git push
argocd app get tasktracker-dev
kubectl get applications -n argocd
git revert --no-edit HEAD && git push        # restore dev
```
(Drills 3 and 4 push straight to `main`: the "every change through a pull request" rule is stated for Task 7 only.)

![the sync refusal for the ResourceQuota (Drill 4)](docs/screenshots/t8-project-rejection.png)

> 📸 **Screenshot:** save as `docs/screenshots/t8-project-rejection.png` — the sync refusal for the ResourceQuota (Drill 4).

### Task 9 — Rebuild from Git

```bash
bash $PACK/extras/scripts/backup-sealing-key.sh
git rev-parse HEAD
kubectl get applications -n argocd
date
bash $PACK/extras/scripts/rebuild-from-git.sh        # deletes and recreates the cluster, restores the key, bootstraps
kubectl get applications -n argocd -w                # record the order and elapsed time
# new terminal: kubectl port-forward svc/argocd-server -n argocd 8080:443
argocd admin initial-password -n argocd
argocd login localhost:8080 --username admin --insecure
argocd app sync tasktracker-staging
kubectl logs job/tasktracker-smoke-test -n dso202-dev
kubectl logs job/tasktracker-smoke-test -n dso202-staging
curl -s http://localhost:30080 | head
bash $PACK/extras/scripts/backup-sealing-key.sh      # fresh backup of the rebuilt cluster
date
```
Create one task in each environment to show the database works. Record the total time from `kind create cluster` to a working dev frontend. If the backup reports a `resourceVersion`/`uid` error on restore, delete `resourceVersion`, `uid` and `creationTimestamp` from each item in the backup file and apply again. Q6 is answered in section 9.

![both environments Healthy after the rebuild](docs/screenshots/t9-rebuilt.png)

> 📸 **Screenshot:** save as `docs/screenshots/t9-rebuilt.png` — both environments Healthy after the rebuild.

### Task 10 — Bonus (optional)

Replace the `source:` block of `argocd/applications/tasktracker-dev.yaml` with the `sources:` block shown in `docs/evidence.md`, Task 10; commit, push, and record `argocd app get tasktracker-dev`.

### Final checklist before submitting

- [ ] `git log --oneline` shows many commits; `.gitignore` is the first
- [ ] Tags `v1.0.0`, `v1.1.0`, `v1.2.0` are on GitHub (`git ls-remote --tags origin`)
- [ ] `git status --short --ignored` shows `secrets-plain/` ignored and no key material tracked
- [ ] `docs/evidence.md` has real output in every block, four screenshots in `docs/screenshots/`
- [ ] Repository is public; submit the URL and `git rev-parse origin/main`
- [ ] no YAML line outside a comment uses latest, stable, master or HEAD as a version

Command output for every task: [`docs/evidence.md`](docs/evidence.md); screenshots: `docs/screenshots/`.
# AS2025_DSO202_02230289_Assignment-04
