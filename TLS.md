# TLS para `pablodevops.store` con cert-manager + Let's Encrypt

Resumen de lo que se hizo para servir la app por HTTPS con un certificado válido de
Let's Encrypt desde el cluster local k3d (`k3d-k3s-default`), expuesto a internet con
port forward desde el router de casa.

## 1. Arquitectura final

```
Navegador ──▶ DNS (Squarespace)  A pablodevops.store → <IP pública>
                    │
             Router (port forward)
   externo 80  ─────┼──▶ 192.168.1.13:3000 ──port-forward──▶ svc/traefik :80  (entrypoint web)
   externo 443 ─────┴──▶ 192.168.1.13:3443 ──port-forward──▶ svc/traefik :443 (entrypoint websecure)
                                                                   │
                     :80  → Ingress ingress-http-redirect → 301 a https://
                            (+ Ingress temporal de cert-manager para /.well-known/acme-challenge/)
                     :443 → TLS con Secret pablodevops-store-tls
                            ├─ /api → back-service:8000 (StripPrefix /api)
                            └─ /    → front-service:3000
```

Validación de Let's Encrypt: **HTTP-01**. Let's Encrypt entra desde internet por el
puerto **80** a `http://pablodevops.store/.well-known/acme-challenge/<token>`, que
cert-manager publica con un Ingress temporal.

## 2. Red: DNS, router y port-forwards

| Pieza                    | Configuración                                                                       | Para qué                                              |
|--------------------------|-------------------------------------------------------------------------------------|-------------------------------------------------------|
| DNS (Squarespace)        | Registro `A` `pablodevops.store` → IP pública de la casa                            | Que Let's Encrypt y los navegadores lleguen a la casa |
| Router — regla 80        | externo **80** → `192.168.1.13:3000`                                                | Challenge HTTP-01 + redirección a https               |
| Router — regla 443       | externo **443** → `192.168.1.13:3443`                                               | Tráfico HTTPS                                         |
| Forward en la Mac (3000) | `kubectl -n kube-system port-forward --address 192.168.1.13 svc/traefik 3000:80`    | HTTP → entrypoint `web` de Traefik                    |
| Forward en la Mac (3443) | `kubectl -n kube-system port-forward --address 192.168.1.13 svc/traefik 3443:443`   | HTTPS → entrypoint `websecure` de Traefik             |

Puertos del pod de Traefik (k3s), para no confundirse al crear forwards (p. ej. desde k9s):

| Nombre      | containerPort | Service port | Uso                                   |
|-------------|---------------|--------------|---------------------------------------|
| `web`       | 8000          | 80           | HTTP — **destino del forward 3000**   |
| `websecure` | 8443          | 443          | HTTPS — **destino del forward 3443**  |
| `traefik`   | 8080          | —            | Interno (dashboard/ping), no usar     |
| `metrics`   | 9100          | —            | Métricas, no usar                     |

### Problemas encontrados en el camino

1. **Los dos forwards del router apuntaban al mismo puerto interno (3000).** No funciona:
   un puerto de Traefik espera HTTP plano *o* TLS. Se separó el 443 externo al 3443.
2. **El forward de k9s en 3000 apuntaba al puerto `traefik` (8080)** en vez de a `web`
   (8000). Antes funcionaba de casualidad (los Ingress sin entrypoint fijo se enganchaban
   a todos los puertos de Traefik); con TLS los Ingress quedaron fijados a
   `web`/`websecure` y el 3000 empezó a dar `404 page not found`. Se recreó apuntando a
   `svc/traefik:80`.
3. **El 443 externo rechazaba la conexión** (respondía el propio router en ~3 ms). Se
   corrigió la regla del router.

## 3. Instalación en el cluster

```bash
# 1. cert-manager v1.21.3 con sus CRDs
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.3 --namespace cert-manager --create-namespace --set crds.enabled=true

# 2. ClusterIssuers de Let's Encrypt (staging + prod)
kubectl apply -f cert-manager/cluster-issuers.yaml
kubectl get clusterissuer            # ambos READY=True

# 3. Releases con TLS y variables en https
helm upgrade backend  ./backend      # NGROK=https://pablodevops.store
helm upgrade frontend ./frontend     # REACT_APP_API_URL=https://pablodevops.store/api
helm upgrade ingress  ./ingress      # Certificate + TLS + redirección http→https

# 4. Seguir la emisión
kubectl get certificate,certificaterequest,order,challenge
kubectl describe certificate ingress-tls
```

Secuencia seguida:

1. Primero con **staging** (`--set tls.issuer.name=letsencrypt-staging`): emisor
   `(STAGING) Ersatz Emmer YR2`. Cert no confiable para el navegador, pero sin rate limits;
   sirve para validar que el challenge y el routing funcionan.
2. Verificado HTTPS y redirección, se cambió a **producción** (`letsencrypt-prod`, ahora
   valor por defecto en `ingress/values.yaml`): emisor `Let's Encrypt YR1`, válido 90 días.
   cert-manager lo renueva solo ~30 días antes de expirar.

## 4. Cambios en el repo

| Archivo                                      | Cambio                                                                                                    |
|----------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| `cert-manager/cluster-issuers.yaml` (nuevo)  | `ClusterIssuer` `letsencrypt-staging` y `letsencrypt-prod`: ACME HTTP-01, `ingressClassName: traefik`     |
| `ingress/values.yaml`                        | Bloque `tls`: `enabled`, `secretName: pablodevops-store-tls`, `issuer` (`letsencrypt-prod` / `ClusterIssuer`), `redirectHttps` |
| `ingress/templates/certificate.yaml` (nuevo) | `Certificate` explícito para `host`                                                                       |
| `ingress/templates/ingress.yaml`             | Bloque `tls` en ambos Ingress + anotaciones `router.entrypoints: websecure` y `router.tls: "true"`        |
| `ingress/templates/redirect-https.yaml` (nuevo) | Middleware Traefik `redirectScheme` (https, permanente) + Ingress en entrypoint `web` que lo aplica    |
| `frontend/values.yaml`                       | `REACT_APP_API_URL` → `https://pablodevops.store/api` (con http el navegador bloquea por *mixed content*) |
| `backend/values.yaml`                        | `NGROK` (origin CORS) → `https://pablodevops.store` (CORS compara el esquema exacto)                      |

### Decisiones de diseño

- **`Certificate` explícito en vez de la anotación `cert-manager.io/cluster-issuer`:** hay
  dos Ingress con el mismo host (el backend necesita su propio Ingress por el Middleware
  StripPrefix); con la anotación en ambos, cert-manager crearía dos `Certificate` peleando
  por el mismo Secret.
- **Redirección http→https que no rompe las renovaciones:** el Ingress temporal del
  challenge tiene una regla más específica (`/.well-known/acme-challenge/<token>`) y
  Traefik la prioriza sobre la redirección de `/`.
- **ClusterIssuers fuera del chart `ingress`:** son recursos cluster-wide que se aplican
  una vez; así el chart sigue siendo reutilizable.
- **TLS desactivable:** `--set tls.enabled=false` vuelve al comportamiento anterior (solo HTTP).

## 5. Verificación

```bash
# Certificado listo
kubectl get certificate ingress-tls                    # READY=True

# Qué certificado sirve Traefik
echo | openssl s_client -connect 192.168.1.13:3443 -servername pablodevops.store 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates

# Redirección http → https
curl -sI http://pablodevops.store/                     # 301 Location: https://pablodevops.store/

# HTTPS validando la cadena (sin -k)
curl -sI https://pablodevops.store/                    # 200
curl -sI https://pablodevops.store/api/docs            # 200
```

## 6. A tener en cuenta

- **Los dos port-forwards deben estar corriendo.** Si cae el del 3000, además de perder
  HTTP fallan las **renovaciones** del certificado (el challenge entra por el 80). Opción
  más estable: publicar 80/443 en el load balancer de k3d
  (`k3d node edit k3d-k3s-default-serverlb --port-add 80:80@loadbalancer` y lo mismo con
  443) y apuntar el router a esos puertos.
- **IP pública dinámica:** si cambia, hay que actualizar el registro `A` en Squarespace o
  las renovaciones fallarán.
- **`/etc/hosts`:** no debe tener `127.0.0.1 pablodevops.store`; si no, el navegador local
  va a `127.0.0.1:443`, donde no escucha nada.
- **Caché del navegador:** si quedó recordada la advertencia del cert staging, probar en
  ventana privada.
- **Exposición:** mientras el cluster y los forwards estén arriba, la Mac queda expuesta
  en 80/443 (Traefik y el login de la app; Postgres no, es un Service interno).

## 7. Pendientes

- Publicar los charts: `./release.sh -b minor ingress` (→ 0.2.0) y
  `./release.sh frontend backend`, luego commit + push.
- Actualizar `README.md` (acceso local en `http`/`port-forward 80:80`, tabla de valores en
  sync con el esquema `https`, carpeta `cert-manager/`) y `up.sh` (no instala cert-manager
  ni los ClusterIssuers).
