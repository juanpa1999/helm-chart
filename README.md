# helm-chart

Helm charts for the three-tier sensor monitoring application (temperature, humidity and
weight): **frontend**, **backend** and **PostgreSQL**. It is the Helm version of the
plain manifests in `kubernetes-Digital-ocean` (`dp-db.yaml`, `dp-back.yaml`,
`dp-front.yaml`): the default Deployment and Service names are the same, so the backend
still finds the DB (`db-service`) and the frontend (`front-service`).

The repo also serves as a **Helm repository** published on GitHub Pages
(`index.yaml` + `.tgz` packages in `charts/`). It contains no application code: the
images come from Docker Hub (`jpcc141999/*`).

## Architecture

```
            localhost:3000                 localhost:8000
                  │  (port-forward)              │  (port-forward)
                  ▼                              ▼
   ┌──────────────────────────┐   ┌──────────────────────────┐
   │ front-service (NodePort) │   │ back-service (NodePort)  │
   │ 3000 → nodePort 32000    │   │ 8000 → nodePort 32001    │
   └────────────┬─────────────┘   └────────────┬─────────────┘
                ▼                              ▼
       front-deploy (chart frontend)   back-deployment (chart backend)
       jpcc141999/front4               jpcc141999/back3
                                       DB_HOST=db-service
                                       + Job back-deployment-migrate (alembic)
                                                 │
                                                 ▼
                                    db-service (ClusterIP :5432)
                                                 │
                                                 ▼
                                    db-deployment (chart db)
                                    jpcc141999/db1 (PostgreSQL)
```

| Chart      | Image               | Port   | Service                          | Deployment        |
|------------|---------------------|--------|----------------------------------|-------------------|
| `db`       | `jpcc141999/db1`    | 5432   | `db-service` (ClusterIP)         | `db-deployment`   |
| `backend`  | `jpcc141999/back3`  | 8000   | `back-service` (NodePort 32001)  | `back-deployment` |
| `frontend` | `jpcc141999/front4` | 3000   | `front-service` (NodePort 32000) | `front-deploy`    |

## Structure

```
.
├── db/                        # PostgreSQL chart (Deployment + Service + optional PVC)
├── backend/                   # Backend chart (Deployment + Service + migration Job)
├── frontend/                  # Frontend chart (Deployment + Service)
├── charts/                    # Published .tgz packages (helm package)
├── index.yaml                 # Helm repo index (helm repo index)
├── sql/
│   └── seed_pablodevops.sql   # Test data (user, sensors, 24 h of readings)
└── up.sh                      # Full deploy + seed + port-forward
```

## Requirements

- An accessible Kubernetes cluster with `kubectl` pointing at it
  (`kubectl config current-context`).
- [Helm](https://helm.sh/docs/intro/install/) v3.
- Access to Docker Hub to pull the `jpcc141999/*` images.

## Quick deploy

From the repo root:

```bash
./up.sh
```

The script:

1. Installs/upgrades the `db` chart and waits for PostgreSQL to be ready (`pg_isready`).
2. Installs/upgrades the `backend` chart. Helm waits for the migration Job
   (`alembic upgrade head`) to finish, which runs as a `post-install`/`post-upgrade` hook.
3. Loads the test data from `sql/seed_pablodevops.sql` (idempotent).
4. Installs/upgrades the `frontend` chart.
5. Opens a port-forward for both services and stays in the foreground (Ctrl+C stops it):
   - Frontend: <http://localhost:3000>
   - Backend: <http://localhost:8000>

Since it uses `helm upgrade --install`, it can be run multiple times safely.

Optional variables:

| Variable    | Default                          | Effect                                                     |
|-------------|----------------------------------|------------------------------------------------------------|
| `NAMESPACE` | current context's namespace      | Target namespace (created if it doesn't exist)             |
| `SOURCE`    | `local`                          | `local` = charts from this repo; `repo` = published charts |
| `SKIP_SEED` | `0`                              | `1` = don't load the seed                                  |
| `NO_PF`     | `0`                              | `1` = exit without opening port-forward                    |

```bash
NAMESPACE=sensores SOURCE=repo NO_PF=1 ./up.sh
```

**Test user:** the seed creates the user `pablodevops` (role `master`). Only the bcrypt
hash is stored in the DB; the plaintext password is not in this repo.

## Using it as a Helm repository

```bash
helm repo add pablo-charts https://juanpa1999.github.io/helm-chart
helm repo update
helm search repo pablo-charts

helm install db       pablo-charts/db
helm install backend  pablo-charts/backend
helm install frontend pablo-charts/frontend
```

## Relevant configuration

Each chart is configured in its `values.yaml`. The most important bits:

- **Image tags**: all use `latest`. Pin a real tag as soon as one exists
  (`--set image.tag=...`), or every redeploy may pull a different version.
- **Migrations** (`backend` → `migrations.mode`):
  - `job` (default): Job as a Helm hook; with ArgoCD it translates to `PostSync`.
    If it fails, the Job is kept so you can check the logs: `kubectl logs job/back-deployment-migrate`.
  - `initContainer`: migrates before each pod starts. Only safe with `replicaCount: 1`.
  - `none`: manually, `kubectl exec deploy/back-deployment -- alembic upgrade head`.
- **DB persistence** (`db` → `persistence.enabled`): disabled by default,
  same as `dp-db.yaml` — **data is lost if the pod restarts**. When enabled, a PVC is
  created with `helm.sh/resource-policy: keep` (survives `helm uninstall`) and the
  strategy switches to `Recreate`.
- **Names across charts**: `backend` → `db.host` must match `db` →
  `service.name` (default `db-service`). They are not linked automatically.
- **DB credentials**: they live inside the `jpcc141999/db1` image; the charts don't
  create Secrets.

Preview without touching the cluster:

```bash
helm lint ./backend
helm template backend ./backend --set migrations.mode=initContainer
```

## Publishing a new chart version

1. Bump `version` in the modified chart's `Chart.yaml`.
2. Package and regenerate the index:

   ```bash
   helm package db backend frontend -d charts/
   helm repo index . --url https://juanpa1999.github.io/helm-chart
   ```

3. Commit `charts/*.tgz` and `index.yaml` and push to `main` (GitHub Pages serves the repo).

## Cleanup

```bash
helm uninstall frontend backend db
# if persistence.enabled=true, the PVC is kept; delete it manually if you no longer need it:
kubectl delete pvc db-deployment-data
```
