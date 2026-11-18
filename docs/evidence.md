# Evidence — DSO202 Assignment 4

**Student:** Kuenzang (02230289) · **Repository:** https://github.com/Rabtens/dso202-gitops

Convention: each item shows the command that was run and its output as text. Paste the real output into each block as the task is done. Screenshots are required only where marked. Never paste a credential value or any part of the sealing key.

## Task 1

**1.1 Tool check (section 3.2)**

```bash
docker version --format '{{.Server.Version}}'
kind version
kubectl version --client
helm version --short
git --version
argocd version --client
kubeseal --version
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update
helm search repo sealed-secrets/sealed-secrets --versions | head -5
```

Chart 2.20.0 must appear in the list.

```text
(paste the output here)
```

**1.2 Chart contract C1–C11**

| # | Requirement | Satisfied in |
|---|---|---|
| C1 | Image repository and tag are values for each tier | `charts/tasktracker/values.yaml` → `database.image`, `backend.image`, `frontend.image` (`repository`, `tag`); `_helpers.tpl` → `task-tracker.image` takes the tag from values |
| C2 | Per-tier configuration rendered from values | `values.yaml` → `backend.env`, `frontend.env`; rendered by the `range` blocks in `templates/backend.yaml` and `templates/frontend.yaml` |
| C3 | Chart never renders a Secret | `secret.yaml` removed; `values.yaml` → `existingSecret`; `environments/*/values.yaml` → `existingSecret: tasktracker-credentials`; `secretKeyRef` in `database.yaml`, `backend.yaml` |
| C4 | Readiness probes on all three tiers | `database.yaml` (`pg_isready`), `backend.yaml` (`GET /api/status`), `frontend.yaml` (`GET /`) |
| C5 | Sync waves db 0, backend 1, frontend 2 | `argocd.argoproj.io/sync-wave` on the StatefulSet/Deployment and Service in `database.yaml` (`"0"`), `backend.yaml` (`"1"`), `frontend.yaml` (`"2"`) |
| C6 | `progressDeadlineSeconds: 120` | `templates/backend.yaml`, `templates/frontend.yaml` (Deployment spec) |
| C7 | Requests and limits on every container | `values.yaml` → `database.resources`, `backend.resources`, `frontend.resources`; `templates/smoke-test-job.yaml` |
| C8 | No Namespace, ResourceQuota, LimitRange, Role, RoleBinding | moved to `platform/<env>/` (`namespace.yaml`, `quota-and-limits.yaml`, `rbac.yaml`); chart renders only ServiceAccounts for its Pods |
| C9 | Ingress disabled by default | `values.yaml` → `ingress.enabled: false`; `templates/ingress.yaml` is wrapped in `if` |
| C10 | Frontend Service NodePort, number is a value | `templates/frontend.yaml` → `nodePort: {{ .Values.frontend.service.nodePort }}`; 30080 in `environments/dev`, 30081 in `environments/staging` |
| C11 | `helm lint` clean, `helm template` succeeds for both | items 1.3 and 1.4 below |

**1.3 Lint both environments**

```bash
helm lint charts/tasktracker -f environments/dev/values.yaml
helm lint charts/tasktracker -f environments/staging/values.yaml
```

```text
(paste the output here)
```

**1.4 Kinds rendered by the chart (needed again in Task 3)**

```bash
helm template tasktracker charts/tasktracker -f environments/dev/values.yaml | grep '^kind:' | sort | uniq -c
```

Expected kinds: ConfigMap ×2 (`task-tracker-config`, `frontend-nginx-config`), Deployment ×2, Service ×3, ServiceAccount ×3, StatefulSet; the Job appears once the smoke test is added in Task 5.

```text
(paste the output here)
```

**1.5 Cluster list, context and nodes**

```bash
kind get clusters
kubectl config current-context
kubectl get nodes
```

```text
(paste the output here)
```

**1.6 Port mapping (host port 30080 must be present)**

```bash
docker ps --filter name=dso202-gitops --format '{{.Names}}   {{.Ports}}'
```

```text
(paste the output here)
```

## Task 2

**2.1 Render checks**

```bash
kubectl kustomize bootstrap/argocd | grep -E '^kind: (Deployment|StatefulSet)$' | sort | uniq -c
kubectl kustomize bootstrap/argocd | grep 'image:' | sort -u
```

Expected: 6 Deployments and 1 StatefulSet; images from ghcr.io/dexidp/dex, public.ecr.aws/docker/library/redis and quay.io/argoproj/argocd (v3.5.6).

```text
(paste the output here)
```

**2.2 Apply (server-side) and wait**

```bash
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
```

```text
(paste the output here)
```

**2.3 Pods and CRDs**

```bash
kubectl get pods -n argocd
kubectl get crd | grep argoproj.io
```

Seven Pods Running; three CRDs: applications, appprojects, applicationsets.

```text
(paste the output here)
```

**2.4 Local settings applied and client/server versions**

```bash
kubectl get configmap argocd-cm -n argocd -o yaml | grep -E 'timeout.reconciliation|accounts.reviewer'
argocd version
```

```text
(paste the output here)
```

![Argo CD UI after signing in as admin](screenshots/02-argocd-ui.png)

> 📸 **Screenshot:** save as `docs/screenshots/02-argocd-ui.png` — Argo CD UI after signing in as admin.

## Task 3

**3.1 Final whitelist** (`argocd/projects/dso202.yaml`), built from the kinds in item 1.4. No additions were needed beyond the chart's kinds; `Namespace`, `ResourceQuota`, `LimitRange`, `Role`, `RoleBinding` and `SealedSecret` are deliberately absent.

```yaml
namespaceResourceWhitelist:
  - {group: apps,  kind: Deployment}
  - {group: apps,  kind: StatefulSet}
  - {group: "",    kind: Service}
  - {group: "",    kind: ConfigMap}
  - {group: "",    kind: ServiceAccount}
  - {group: batch, kind: Job}      # the PostSync smoke-test hook
```

**3.2 Apply the bootstrap files and observe**

```bash
kubectl apply -f bootstrap/root
kubectl get appproject,application -n argocd
argocd app get root
argocd proj get dso202
```

Expected: AppProjects default, platform, dso202; Application root Synced and Healthy; dso202 listed in the resource list of `argocd app get root` (created by the root, not by hand).

```text
(paste the output here)
```

![Root Application resource tree in the UI](screenshots/03-root-resource-tree.png)

> 📸 **Screenshot:** save as `docs/screenshots/03-root-resource-tree.png` — Root Application resource tree in the UI.

**Q1** is answered in README section 9.

## Task 4

**4.1 Controller installed through Git**

```bash
kubectl get applications -n argocd
kubectl get pods -n sealed-secrets
kubectl get crd sealedsecrets.bitnami.com
```

```text
(paste the output here)
```

**4.2 Sealing key backed up outside the repository (permissions only, never contents)**

```bash
ls -l ../dso202-keys/
```

```text
(paste the output here)
```

**4.3 Credentials sealed (key names only; never the values)**

```bash
# keys sealed per environment: DB_USER, DB_PASSWORD, POSTGRES_USER, POSTGRES_PASSWORD
ls -l platform/dev/tasktracker-credentials.sealed.yaml platform/staging/tasktracker-credentials.sealed.yaml
```

```text
(paste the output here)
```

**4.4 Platform layer observed**

```bash
kubectl get applications -n argocd
kubectl get namespaces | grep dso202
kubectl get sealedsecret -n dso202-dev
kubectl get sealedsecret -n dso202-staging
kubectl describe secret tasktracker-credentials -n dso202-dev
kubectl describe secret tasktracker-credentials -n dso202-staging
kubectl get resourcequota,limitrange -n dso202-dev
kubectl get resourcequota,limitrange -n dso202-staging
```

Both platform-* Applications Synced and Healthy; the Secret has four keys in each namespace.

```text
(paste the output here)
```

**4.5 No plaintext in Git history (keys tested: DB_USER, DB_PASSWORD, POSTGRES_USER, POSTGRES_PASSWORD, in both environments; plaintext and base64 forms)**

```bash
bash $PACK/extras/scripts/history-scan.sh      # or: git log -p --all -S'<value>' | head
git status --short --ignored
```

Every count must be 0.

```text
(paste the output here)
```

**Q2** is answered in README section 9.

## Task 5

**5.1 All Applications Synced and Healthy**

```bash
kubectl get applications -n argocd
```

```text
(paste the output here)
```

**5.2 Pod creation order (database, then backend, then frontend)**

```bash
kubectl get pods -n dso202-dev -w
```

```text
(paste the output here)
```

**5.3 Smoke test**

```bash
kubectl get job -n dso202-dev
kubectl logs job/tasktracker-smoke-test -n dso202-dev
```

```text
(paste the output here)
```

**5.4 Both environments**

```bash
argocd app get tasktracker-dev
argocd app get tasktracker-staging
```

```text
(paste the output here)
```

**5.5 Staging brought up; root before and after the first staging sync**

```bash
argocd app get root                       # before
argocd app sync tasktracker-staging
kubectl get svc -n dso202-staging
argocd app get root                       # after
```

```text
(paste the output here)
```

**5.6 CRUD cycle in dev** (http://localhost:30080): created, read, updated and deleted one task, as in Assignment 1.

```text
(describe or paste the four API calls / UI steps and results)
```

![tasktracker-dev resource tree in the UI](screenshots/05-tasktracker-dev-tree.png)

> 📸 **Screenshot:** save as `docs/screenshots/05-tasktracker-dev-tree.png` — tasktracker-dev resource tree in the UI.

**5.7 Q3 example (Synced but not Healthy)** — paste the `argocd app get tasktracker-dev` output captured during Task 7, part B, step 5 (Synced / Degraded), or provoke it with a non-starting image tag on a branch.

```text
(paste the output here)
```

**Q3** is answered in README section 9.

## Task 6

**6.1 Accounts**

```bash
argocd account list
```

Two accounts: admin and reviewer.

```text
(paste the output here)
```

**6.2 reviewer before the logs rule**

```bash
argocd login localhost:8080 --username reviewer --insecure --name reviewer
argocd --argocd-context reviewer app list
argocd --argocd-context reviewer account can-i get applications 'dso202/tasktracker-dev'
argocd --argocd-context reviewer account can-i sync applications 'dso202/tasktracker-dev'
argocd --argocd-context reviewer account can-i get logs 'dso202/tasktracker-dev'
argocd --argocd-context reviewer proj get platform
```

Expected: only the two tasktracker apps listed; get applications = yes; sync = no; get logs = no; reading `platform` denied.

```text
(paste the output here)
```

**6.3 Logs rule added by a commit, bootstrap re-applied by hand (the ConfigMap is part of the hand-applied layer)**

```bash
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
argocd --argocd-context reviewer account can-i get logs 'dso202/tasktracker-dev'
```

If still `no` after a minute: kubectl rollout restart deployment argocd-server -n argocd

```text
(paste the output here)
```

![reviewer session in the UI showing Pod logs](screenshots/06-reviewer-logs.png)

> 📸 **Screenshot:** save as `docs/screenshots/06-reviewer-logs.png` — reviewer session in the UI showing Pod logs.

**Q4** is answered in README section 9.

## Task 7

**7.1 Pull requests (titles and numbers)**

```bash
gh pr list --state merged --limit 20
```

Or a screenshot of the GitHub pull-request list.

```text
(paste the output here)
```

**7.2 Part A — frontend 1.1 released to dev**

```bash
kubectl get pods -n dso202-dev -w
argocd app get tasktracker-dev
argocd app history tasktracker-dev
```

```text
(paste the output here)
```

**7.3 Part A — promotion to staging (OutOfSync before the manual sync; old header still on :8081)**

```bash
git tag -a v1.1.0 -m "Release: frontend 1.1" && git push origin v1.1.0
argocd app get tasktracker-staging        # OutOfSync, not deployed
argocd app sync tasktracker-staging
argocd app get tasktracker-staging
```

```text
(paste the output here)
```

**7.4 Part B — bad commit SHA on main**

```bash
git log --oneline -n 5
```

```text
(paste the output here)
```

**7.5 Part B — observation, dev (do not intervene)**

```bash
kubectl get pods -n dso202-dev -w
argocd app get tasktracker-dev
kubectl get applications -n argocd
```

Record: new backend Pod vs old Pod state; sync status and health; whether the smoke test ran; whether the frontend still responds; Degraded after 120 s.

```text
(paste the output here)
```

**7.6 Diagnosis and the exact log line**

```bash
kubectl get pods -n dso202-dev
kubectl describe pod <new-backend-pod> -n dso202-dev
kubectl logs <new-backend-pod> -n dso202-dev
```

Exact line stating what the new image requires:

```text
(paste the output here)
```

**7.7 Argo CD rollback refusal**

```bash
argocd app rollback tasktracker-dev
```

Record exactly what it prints.

```text
(paste the output here)
```

**7.8 Recovery by git revert (pull request merged), dev back to Healthy**

```bash
git checkout -b revert/backend-1.1
git revert --no-edit <bad-commit-sha>
git push -u origin revert/backend-1.1
argocd app get tasktracker-dev
```

```text
(paste the output here)
```

**7.9 Fix forward (backend 1.1 + the required value, as a value) and promotion with v1.2.0**

```bash
argocd app get tasktracker-dev
git tag -a v1.2.0 -m "Release: backend 1.1 with required setting" && git push origin v1.2.0
argocd app sync tasktracker-staging
argocd app get tasktracker-staging
```

```text
(paste the output here)
```

**7.10 History**

```bash
git log --oneline --graph --decorate -n 15
argocd app history tasktracker-dev
argocd app history tasktracker-staging
```

`argocd app history tasktracker-staging` must contain no revision with the faulty backend.

```text
(paste the output here)
```

**Q5** is answered in README section 9.

## Task 8

For each drill: prediction, commands, observation, and one sentence on whether the prediction held.

### Drill 1 — drift in dev is reverted

**Prediction:** Argo CD will scale the Deployment back to its Git value (1 replica) within seconds, because `selfHeal: true` is set on `tasktracker-dev`.

**Commands and observation**

```bash
kubectl get deployment -n dso202-dev
kubectl scale deployment/backend -n dso202-dev --replicas=3
kubectl get deployment/backend -n dso202-dev -w      # start the watch BEFORE the scale
```

```text
(paste the output here)
```

**Result:** (one sentence: did the prediction hold, and which principle or setting explains it)

### Drill 2 — drift in staging is reported, not reverted

**Prediction:** The Deployment will stay at 3 replicas; `tasktracker-staging` will show OutOfSync, because it has no automated sync, until I sync it manually.

**Commands and observation**

```bash
kubectl scale deployment/backend -n dso202-staging --replicas=3
argocd app get tasktracker-staging
argocd app diff tasktracker-staging
argocd app sync tasktracker-staging
```

```text
(paste the output here)
```

**Result:** (one sentence: did the prediction hold, and which principle or setting explains it)

### Drill 3 — removing a file prunes the object

**Prediction:** The ConfigMap `prune-drill` will appear within about a minute of the push and disappear within about a minute of `git rm`, because `prune: true` is set on `platform-dev`. Deleting `namespace.yaml` would not delete the namespace because of `Prune=false` (explained, not tested).

**Commands and observation**

```bash
cp $PACK/extras/drill-files/prune-drill.yaml platform/dev/ && git add platform/dev/prune-drill.yaml && git commit -m "Drill 3: add prune-drill" && git push
kubectl get configmap prune-drill -n dso202-dev
git rm platform/dev/prune-drill.yaml && git commit -m "Drill 3: remove prune-drill" && git push
kubectl get configmap prune-drill -n dso202-dev
```

```text
(paste the output here)
```

**Result:** (one sentence: did the prediction hold, and which principle or setting explains it)

### Drill 4 — the project rejects a resource it does not permit

**Prediction:** The sync of `tasktracker-dev` will be refused with a message that the ResourceQuota is not permitted in project `dso202`. Staging is unaffected because it reads the tag `v1.2.0` (or the latest promoted tag), which does not contain the new file.

**Commands and observation**

```bash
cp $PACK/extras/drill-files/drill-quota.yaml charts/tasktracker/templates/ && git add charts/tasktracker/templates/drill-quota.yaml && git commit -m "Drill 4: add ResourceQuota to the chart" && git push
argocd app get tasktracker-dev
kubectl get applications -n argocd
git revert <commit-sha>      # restore dev; then push through a pull request
```

```text
(paste the output here)
```

**Result:** (one sentence: did the prediction hold, and which principle or setting explains it)

## Task 9

**9.1 Fresh key backup and state before the rebuild**

```bash
bash $PACK/extras/scripts/backup-sealing-key.sh
git rev-parse HEAD
kubectl get applications -n argocd
```

```text
(paste the output here)
```

**9.2 Delete and recreate the cluster (start time recorded)**

```bash
date
kind delete cluster --name dso202-gitops
kind create cluster --name dso202-gitops --config cluster/kind-cluster.yaml
```

```text
(paste the output here)
```

**9.3 Restore the sealing key before the controller exists**

```bash
kubectl create namespace sealed-secrets
kubectl apply -f ../dso202-keys/sealing-key.backup.yaml
```

```text
(paste the output here)
```

**9.4 Bootstrap again (the only hand-applied steps)**

```bash
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl apply -f bootstrap/root
```

```text
(paste the output here)
```

**9.5 Applications appear in wave order (record the order they become Healthy and the elapsed time)**

```bash
kubectl get applications -n argocd -w
```

```text
(paste the output here)
```

**9.6 Sign in again and sync staging**

```bash
argocd admin initial-password -n argocd
argocd login localhost:8080 --username admin --insecure
argocd app sync tasktracker-staging
```

```text
(paste the output here)
```

**9.7 Verification: both environments, smoke tests, same staging tag as before, one task created in each**

```bash
kubectl get applications -n argocd
kubectl logs job/tasktracker-smoke-test -n dso202-dev
kubectl logs job/tasktracker-smoke-test -n dso202-staging
argocd app get tasktracker-staging | grep -i 'target'
curl -s http://localhost:30080 | head
```

```text
(paste the output here)
```

**9.8 Fresh key backup from the rebuilt cluster, and the end time**

```bash
bash $PACK/extras/scripts/backup-sealing-key.sh
date
```

Elapsed time, `kind create cluster` → working dev frontend: ______ minutes.

```text
(paste the output here)
```

**Q6** is answered in README section 9.

## Task 10 (bonus, optional)

The changed Application file is `argocd/applications/tasktracker-dev.yaml`; `source:` is replaced by a two-source `sources:` block (the second source has no path and exists only to be referenced as `$values`):

```yaml
  sources:
    - repoURL: https://github.com/Rabtens/AS2025_DSO202_02230289_Assignment-04.git
      targetRevision: main
      path: charts/tasktracker
      helm:
        releaseName: tasktracker
        valueFiles:
          - $values/environments/dev/values.yaml
    - repoURL: https://github.com/Rabtens/AS2025_DSO202_02230289_Assignment-04.git
      targetRevision: main
      ref: values
```

**10.1 Two sources, Synced and Healthy**

```bash
argocd app get tasktracker-dev
```

```text
(paste the output here)
```

**10.2 When separating the sources is useful**

Chart and values often have different owners and release rhythms. A platform team can publish a chart and pin it to a tag (`targetRevision: v1.2.0` on the chart source) while each environment's values follow a branch in a separate configuration repository that the application team may edit freely. A values change then deploys without a chart release, and a chart upgrade can be rolled through the environments one at a time without touching their values.
