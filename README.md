# helm-chart

Helm charts for the three-tier sensor monitoring application (temperature, humidity and
weight): **frontend**, **backend** and **PostgreSQL**, plus an **ingress** chart that
exposes frontend and backend under a single host. It is the Helm version of the plain
manifests in `kubernetes-Digital-ocean` (`dp-db.yaml`, `dp-back.yaml`, `dp-front.yaml`):
the default Deployment and Service names are the same, so the backend still finds the DB
(`db-service`) and the ingress finds the frontend (`front-service`) and backend
(`back-service`).

The repo also serves as a **Helm repository** published on GitHub Pages
(`index.yaml` + `.tgz` packages in `charts/`). It contains no application code: the
images come from Docker Hub (`jpcc141999/*`).

The target cluster is **k3s / k3d**, which ships **Traefik** as its default ingress
controller (IngressClass `traefik`). The `ingress` chart depends on it (it uses a Traefik
`Middleware` CRD).

## Architecture

```
                  Browser → http://pablodevops.store
                                │
            /etc/hosts: 127.0.0.1 pablodevops.store
                                │
          kubectl port-forward svc/traefik 80:80 (kube-system)
                                │
                                ▼
                 ┌──────────────────────────────┐
                 │ Traefik (k3s ingress ctrl)   │
                 │ host: pablodevops.store      │
                 └──────┬────────────────┬──────┘
             path /api  │                │  path /
   (Middleware strips   │                │
         /api prefix)   ▼                ▼
   ┌──────────────────────────┐   ┌──────────────────────────┐
   │ back-service (ClusterIP) │   │ front-service (ClusterIP)│
   │ :8000                    │   │ :3000                    │
   └────────────┬─────────────┘   └────────────┬─────────────┘
                ▼                              ▼
     back-deployment (chart backend)   front-deploy (chart frontend)
     jpcc141999/back3                  jpcc141999/front4
     DB_HOST=db-service                REACT_APP_API_URL=
     NGROK=http://pablodevops.store      http://pablodevops.store/api
     + Job back-deployment-migrate (alembic)
                │
                ▼
     db-service (ClusterIP :5432)
                │
                ▼
     db-deployment (chart db)
     jpcc141999/db1 (PostgreSQL)
```

| Chart      | Image               | Port | Service                    | Deployment / resources                                  |
|------------|---------------------|------|----------------------------|---------------------------------------------------------|
| `db`       | `jpcc141999/db1`    | 5432 | `db-service` (ClusterIP)   | `db-deployment`                                         |
| `backend`  | `jpcc141999/back3`  | 8000 | `back-service` (ClusterIP) | `back-deployment` + Job `back-deployment-migrate`       |
| `frontend` | `jpcc141999/front4` | 3000 | `front-service` (ClusterIP)| `front-deploy`                                          |
| `ingress`  | —                   | 80   | — (uses Traefik)           | Ingress `<release>-backend`, `<release>-frontend` + Middleware `<release>-strip-api` |

## Structure

```
.
├── db/                        # PostgreSQL chart (Deployment + Service + optional PVC)
├── backend/                   # Backend chart (Deployment + Service + migration Job)
├── frontend/                  # Frontend chart (Deployment + Service)
├── ingress/                   # Ingress chart (2 Ingress + Traefik StripPrefix Middleware)
├── charts/                    # Published .tgz packages (helm package)
├── index.yaml                 # Helm repo index (helm repo index)
├── sql/
│   └── seed_pablodevops.sql   # Test data (user, sensors, 24 h of readings)
└── up.sh                      # Deploy draft (see "Deploy")
```

## Requirements

- A k3s / k3d cluster with Traefik enabled (default) and `kubectl` pointing at it
  (`kubectl config current-context`). Check Traefik is there:
  `kubectl -n kube-system get svc traefik`.
- [Helm](https://helm.sh/docs/intro/install/) v3.
- Access to Docker Hub to pull the `jpcc141999/*` images.

## Deploy

Install the charts **in this order** (from the repo root, local charts):

```bash
helm upgrade --install db       ./db
kubectl rollout status deploy/db-deployment          # wait for PostgreSQL
helm upgrade --install backend  ./backend              # waits for the migration Job (hook)
helm upgrade --install frontend ./frontend
helm upgrade --install ingress  ./ingress

# test data (user, sensors, readings) — idempotent
kubectl exec -i deploy/db-deployment -- \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 < sql/seed_pablodevops.sql
```

Or from the published Helm repo, replacing `./<chart>` with `pablo-charts/<chart>`
(see [Using it as a Helm repository](#using-it-as-a-helm-repository)).

> **About `up.sh`:** it is currently a draft that runs these steps with plain
> `helm install` (not idempotent). Note it adds the repo as `test-name` but installs from
> `ak8s/...`, so the repo alias must match whatever you registered with `helm repo add`.
> It does not install the `ingress` chart nor open any port-forward yet.

**Test user:** the seed creates the user `pablodevops` (role `master`). Only the bcrypt
hash is stored in the DB.

## Local access through the Ingress

Frontend and backend are `ClusterIP`, so the only entry point is Traefik. Everything is
served under **one host**, `pablodevops.store`:

| URL                                   | Goes to                                        |
|---------------------------------------|------------------------------------------------|
| `http://pablodevops.store/`           | `front-service:3000`                           |
| `http://pablodevops.store/api/<path>` | `back-service:8000/<path>` (`/api` is stripped)|

Two steps are needed to reach it from your machine.

### 1. Point the host to localhost (`/etc/hosts`)

The Ingress only matches requests whose `Host` header is `pablodevops.store`, so your
machine must resolve that name to `127.0.0.1`. Add this line to the hosts file:

```
127.0.0.1   pablodevops.store
```

| OS            | File                                          |
|---------------|-----------------------------------------------|
| macOS / Linux | `/etc/hosts` (edit with `sudo`, e.g. `sudo nano /etc/hosts`) |
| Windows       | `C:\Windows\System32\drivers\etc\hosts` (editor run as Administrator) |

On macOS, flush the DNS cache if the name doesn't resolve right away:

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
ping -c1 pablodevops.store     # must answer from 127.0.0.1
```

If you use a different host, change it in `ingress/values.yaml` (`host`) **and** in the
other places that depend on it (see [Values that must stay in sync](#values-that-must-stay-in-sync)).

### 2. Port-forward to Traefik

A single port-forward to the Traefik Service gives access to **all** the resources behind
the Ingress (frontend and backend), instead of one port-forward per service:

```bash
kubectl -n kube-system port-forward svc/traefik 80:80
```

Leave it running (Ctrl+C stops it) and open <http://pablodevops.store>.

- It must be **local port 80**: the frontend calls `http://pablodevops.store/api` and the
  backend only allows CORS from `http://pablodevops.store`, both without a port. Using
  e.g. `8080:80` would load the page at `:8080` but the API calls and CORS would fail.
- On Linux, binding port 80 needs root: `sudo -E kubectl -n kube-system port-forward svc/traefik 80:80`
  (`-E` keeps your `KUBECONFIG`). Recent macOS versions allow it without `sudo`; if you
  get `permission denied`, use `sudo` there as well.
- If something else already uses port 80 locally, stop it first
  (`sudo lsof -iTCP:80 -sTCP:LISTEN`).

**Alternative with k3d (no port-forward):** create the cluster mapping port 80 of the
load balancer to your host, and Traefik is reachable directly on `localhost:80`:

```bash
k3d cluster create sensores -p "80:80@loadbalancer"
```

Quick checks:

```bash
curl -i http://pablodevops.store/                 # frontend HTML
curl -i http://pablodevops.store/api/docs         # backend (FastAPI docs, if exposed)
# without touching /etc/hosts, forcing the Host header:
curl -i -H 'Host: pablodevops.store' http://127.0.0.1/
kubectl get ingress,middleware
```

### Debugging without the Ingress

To hit a service directly (bypassing Traefik), port-forward it:

```bash
kubectl port-forward svc/front-service 3000:3000
kubectl port-forward svc/back-service  8000:8000
```

Keep in mind the frontend still calls `REACT_APP_API_URL` (`http://pablodevops.store/api`),
so the full app only works end to end through the Ingress.

## Using it as a Helm repository

```bash
helm repo add pablo-charts https://juanpa1999.github.io/helm-chart
helm repo update
helm search repo pablo-charts

helm install db       pablo-charts/db
helm install backend  pablo-charts/backend
helm install frontend pablo-charts/frontend
helm install ingress  pablo-charts/ingress
```

## Relevant configuration

Each chart is configured in its `values.yaml`. The most important bits:

- **Image tags**: all use `latest`. Pin a real tag as soon as one exists
  (`--set image.tag=...`), or every redeploy may pull a different version.
- **Service type** (`backend`/`frontend` → `service.type`): `ClusterIP` by default, since
  access goes through the Ingress. To expose a service directly without Ingress, set
  `service.type=NodePort` and `service.nodePort` (`32001` backend, `32000` frontend).
- **Ingress** (`ingress/values.yaml`):
  - `ingressClassName`: `traefik` (k3s default).
  - `host`: `pablodevops.store`. Empty = matches any Host.
  - `backend.path` (`/api`) + `backend.stripPrefix`: the backend routes have no `/api`
    prefix (`/auth`, `/admin`, ...), so a Traefik `StripPrefix` Middleware removes it.
    Two Ingress objects are created because the Middleware is applied per Ingress
    (annotation `<namespace>-<release>-strip-api@kubernetescrd`), so it only affects `/api`.
  - `backend.serviceName` / `frontend.serviceName`: must match `service.name` of each chart.
- **Migrations** (`backend` → `migrations.mode`):
  - `job` (default): Job as a Helm hook; with ArgoCD it translates to `PostSync`.
    If it fails, the Job is kept so you can check the logs: `kubectl logs job/back-deployment-migrate`.
  - `initContainer`: migrates before each pod starts. Only safe with `replicaCount: 1`.
  - `none`: manually, `kubectl exec deploy/back-deployment -- alembic upgrade head`.
- **DB persistence** (`db` → `persistence.enabled`): disabled by default,
  same as `dp-db.yaml` — **data is lost if the pod restarts**. When enabled, a PVC is
  created with `helm.sh/resource-policy: keep` (survives `helm uninstall`) and the
  strategy switches to `Recreate`.
- **DB credentials**: they live inside the `jpcc141999/db1` image; the charts don't
  create Secrets. The backend currently receives `DB_PASSWORD` as a plain value in
  `backend/values.yaml` (`extraEnv`).

### Values that must stay in sync

These are not linked automatically between charts — if you change one, change the others:

| What                    | Where                                                                                 |
|-------------------------|---------------------------------------------------------------------------------------|
| DB service name         | `db` → `service.name` = `backend` → `db.host` (`db-service`)                          |
| Backend service name    | `backend` → `service.name` = `ingress` → `backend.serviceName` (`back-service`)       |
| Frontend service name   | `frontend` → `service.name` = `ingress` → `frontend.serviceName` (`front-service`)    |
| Public host             | `ingress` → `host` + `frontend` → `REACT_APP_API_URL` + `backend` → `NGROK` (CORS) + `/etc/hosts` |
| API path                | `ingress` → `backend.path` (`/api`) = suffix of `frontend` → `REACT_APP_API_URL`      |

Preview without touching the cluster:

```bash
helm lint ./backend
helm template backend ./backend --set migrations.mode=initContainer
helm template ingress ./ingress
```

## Publishing a new chart version

1. Bump `version` in the modified chart's `Chart.yaml`.
2. Package and regenerate the index:

   ```bash
   helm package db backend frontend ingress -d charts/
   helm repo index . --url https://juanpa1999.github.io/helm-chart
   ```

3. Commit `charts/*.tgz` and `index.yaml` and push to `main` (GitHub Pages serves the repo).

## Cleanup

```bash
helm uninstall ingress frontend backend db
# if persistence.enabled=true, the PVC is kept; delete it manually if you no longer need it:
kubectl delete pvc db-deployment-data
```

Remember to remove the `pablodevops.store` line from your hosts file if you no longer need it.
