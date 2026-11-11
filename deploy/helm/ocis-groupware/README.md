# ocis-groupware Helm chart

Runs ocis-groupware in a cluster that already runs oCIS. The chart installs one pod, a
volume for its state, a Service and, if you want it, an Ingress for the groupware paths.

```sh
helm install groupware deploy/helm/ocis-groupware \
  --namespace ocis \
  --set config.oidcIssuer=https://ocis.example.com \
  --set ingress.enabled=true \
  --set ingress.host=ocis.example.com
```

The chart is not published to a registry yet; install it from a checkout. The image
defaults to `owncloud/ocis-groupware` on Docker Hub at the chart's `appVersion`.

## What it deploys

- **One replica, `Recreate` strategy.** The service locks its data directory exclusively,
  so a second pod on the same volume fails to start. A rolling update would start the new
  pod while the old one still holds the lock. With `Recreate` the old pod stops first, so
  an upgrade has a short gap. The replica count is not a value for that reason.
- **A PersistentVolumeClaim** for the data directory, mounted at `/data`. Everything the
  service keeps lives there: calendars, contacts, app passwords and the admin socket.
  The claim needs `ReadWriteOnce`. Uninstalling the release deletes the claim with it
  unless you set `persistence.existingClaim` or add `helm.sh/resource-policy: keep` to
  `persistence.annotations`.
- **A probe on `/healthz`** for startup, liveness and readiness. It answers 503 when the
  data directory is not writable. It does not check oCIS: while oCIS is down, the pod
  stays ready and sign-ins answer 503 until the identity provider is back.
- **The security context of the image.** The image is distroless and runs as uid 65532.
  The chart sets `runAsNonRoot`, that uid and gid, `fsGroup: 65532` so the volume is
  writable, a read-only root file system, no added capabilities and the default seccomp
  profile.
- **An optional Ingress** for the paths in [docs/routing.md](../../../docs/routing.md).
  oCIS needs its own Ingress for the same host; the controller merges the two, and the
  paths of this one are the more specific. The Graph paths are listed one by one,
  because an Ingress has no regular expressions.

The service account has no token mounted, because the service does not talk to the
Kubernetes API.

## Configuration

Every `GROUPWARE_*` key of the service has a value. See the README at the top of the
repository for what each one does.

| Value | Key | Default | Notes |
|---|---|---|---|
| `config.oidcIssuer` | `GROUPWARE_OIDC_ISSUER` | none | **Required.** The public URL of oCIS |
| `config.oidcAudience` | `GROUPWARE_OIDC_AUDIENCE` | `web` | The OAuth client IDs whose tokens are accepted, comma-separated. Set it when oCIS Web uses another client ID. `*` accepts every client |
| `config.ocisUrl` | `GROUPWARE_OCIS_URL` | `""` | Graph API address; the issuer when empty. Inside the cluster, use the oCIS Service |
| `config.logLevel` | `GROUPWARE_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `config.httpAddr` | `GROUPWARE_HTTP_ADDR` | `:8080` | The container port is the number at the end |
| `config.debugAddr` | `GROUPWARE_DEBUG_ADDR` | `:9180` | Where `/metrics` and `/healthz` are served without authentication, on a separate port named `metrics`. Empty turns it off |
| `config.compatPaths` | `GROUPWARE_COMPAT_PATHS` | `false` | Serve the classic DAV layout; adds those paths to the Ingress |
| `config.legacyTokenTtl` | `GROUPWARE_LEGACY_TOKEN_TTL` | `""` | A Go duration; the service default is `4320h` |
| `config.identityMaxAge` | `GROUPWARE_IDENTITY_MAX_AGE` | `""` | A Go duration; the service default is `720h`. `0` turns the check off |
| `config.appPasswordMaxLifetime` | `GROUPWARE_APP_PASSWORD_MAX_LIFETIME` | `""` | A Go duration of at least `24h`; the service default is `4320h` |
| `config.adminSocket` | `GROUPWARE_ADMIN_SOCKET` | `""` | See the socket path limit below |
| `persistence.mountPath` | `GROUPWARE_DATA_DIR` | `/data` | Where the volume is mounted |
| `oidcCA.pem` | `GROUPWARE_OIDC_CA_FILE` | `""` | CA bundle text; the chart stores it in a ConfigMap and sets the key to the mounted file |
| `oidcCA.existingConfigMap` | | `""` | Use a ConfigMap that exists instead |
| `oidcCA.existingSecret` | | `""` | Use a Secret that exists instead |
| `oidcCA.key` | | `ca.crt` | The key of the bundle in the ConfigMap or Secret |
| `legacyTokenSecret.value` | `GROUPWARE_LEGACY_TOKEN_SECRET` | `""` | The classic instance secret; the chart stores it in a Secret |
| `legacyTokenSecret.existingSecret` | | `""` | Read it from a Secret that exists instead |
| `legacyTokenSecret.key` | | `legacy-token-secret` | The key in that Secret |

The legacy token secret is only needed to accept app tokens imported from a classic
installation. Keep it out of a values file that is committed: create the Secret
yourself and name it in `legacyTokenSecret.existingSecret`.

If oCIS uses a certificate that the image does not trust, give the bundle through
`oidcCA`. It covers the issuer and the Graph address, which use the same file.

### The admin socket

The admin API listens on a unix socket, `admin.sock` in the data directory by default.
A socket path is limited to about 100 bytes (107 on Linux, 103 on macOS), and the service
creates the socket under a temporary name that is 14 bytes longer than the final one.
`/data/admin.sock` is far below that. A longer `persistence.mountPath` can reach the limit,
and the service then fails to start with an error from `listen`. Set `config.adminSocket`
to a short path outside the data directory, for example `/run/groupware/admin.sock`; the
chart mounts an empty directory there.

Use the admin commands through `kubectl`:

```sh
kubectl -n ocis exec deploy/groupware-ocis-groupware -- /ocis-groupware admin principals list
```

## Values

| Value | Default | Description |
|---|---|---|
| `image.repository` | `owncloud/ocis-groupware` | Image repository |
| `image.tag` | `""` | Image tag; the chart's `appVersion` when empty |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | |
| `nameOverride`, `fullnameOverride` | `""` | |
| `extraEnv` | `[]` | More environment variables for the container |
| `extraEnvFrom` | `[]` | More `envFrom` sources |
| `persistence.enabled` | `true` | With `false` the data directory is an `emptyDir` and is lost with the pod |
| `persistence.size` | `5Gi` | |
| `persistence.storageClass` | `""` | Empty uses the default class; `-` sets an empty class name |
| `persistence.accessModes` | `[ReadWriteOnce]` | |
| `persistence.annotations` | `{}` | Annotations of the claim |
| `persistence.existingClaim` | `""` | Use a claim that exists instead of creating one |
| `service.type` | `ClusterIP` | |
| `service.port` | `8080` | |
| `service.metricsPort` | `9180` | Also publish the debug port on the Service, named `metrics`. Empty leaves it out |
| `service.annotations` | `{}` | |
| `ingress.enabled` | `false` | |
| `ingress.className` | `""` | |
| `ingress.annotations` | `{}` | Controller settings, for example a larger body size for imports |
| `ingress.host` | `""` | **Required** with the Ingress. The public host of oCIS |
| `ingress.tlsSecretName` | `""` | Adds a `tls` block when set |
| `ingress.exposeOps` | `false` | Also route `/healthz`. `/metrics` is never routed |
| `serviceAccount.create` | `true` | |
| `serviceAccount.name` | `""` | |
| `serviceAccount.annotations` | `{}` | |
| `podAnnotations`, `podLabels` | `{}` | |
| `podSecurityContext` | uid and gid 65532, `fsGroup` 65532 | |
| `securityContext` | read-only root file system, no capabilities | |
| `startupProbe`, `livenessProbe`, `readinessProbe` | `GET /healthz` | |
| `terminationGracePeriodSeconds` | `30` | |
| `resources` | 50m CPU, 64Mi memory requested; 512Mi memory limit | |
| `nodeSelector`, `tolerations`, `affinity` | empty | |
| `priorityClassName` | `""` | |

## Metrics

`/metrics` is not served on the HTTP port any more. It is on the debug port (`:9180`,
container port `metrics`), which has no authentication, so it is published on the Service
only and never through the Ingress. Point Prometheus at the Service port named `metrics`,
or at the pod port. A ServiceMonitor selects the Service and names that port:

```yaml
endpoints:
  - port: metrics
```

Add a NetworkPolicy if other workloads in the namespace should not reach it.

## Ingress paths

With `ingress.enabled`, the chart routes these to the service:

- Exact: `/dav`, `/dav/`, `/.well-known/caldav`, `/.well-known/carddav`
- Prefix: `/dav/calendars/`, `/dav/addressbooks/`, `/dav/principals/`, `/groupware/`, `/web/`
- Prefix, Graph: `/graph/v1.0/me/` followed by `calendar`, `calendars`, `calendarView`,
  `events`, `contact`, `contacts` or `contactFolders`
- With `config.compatPaths`: `/remote.php/dav/principals/`, `/remote.php/dav/addressbooks/`,
  `/remote.php/dav/calendars/`
- With `ingress.exposeOps`: `/healthz`

Everything else stays with oCIS. Make sure the oCIS Ingress for the host does not use a
rewrite or a catch-all regular expression that wins over these paths, and that the
controller lets the WebDAV methods (PROPFIND, REPORT, MKCALENDAR and the rest) through.

## Upgrading

`helm upgrade` stops the old pod and then starts the new one on the same volume. Back up
the volume first when the release notes say the on-disk format changes.

## Tests

CI runs `helm lint`, renders the chart with `test/full-values.yaml` and checks the
result with kubeconform, and installs it with chart-testing into a kind cluster with the
image built from the repository. oCIS is not part of that test, so it covers the pod
starting on the volume and answering its probe, not a sign-in.
