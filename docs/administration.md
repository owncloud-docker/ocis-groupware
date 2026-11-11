# Administration guide

This page is for the person who runs ocis-groupware next to an oCIS installation. It gathers
the settings, the routing choice, what happens to users who leave, the admin commands,
monitoring and the limits you should know about, and points to the page that has the detail.
Where a topic already has a page, this one says what to decide and links to it.

## What you run

One process, `ocis-groupware`, that serves CalDAV and CardDAV under `/dav`, the calendar and
contacts part of the Graph API, its own API under `/groupware/` and the web application that
oCIS Web loads from `/web/`. It keeps all state in one data directory and holds an exclusive
lock on it, so there is one process per directory. It speaks plain HTTP: terminate TLS in the
ingress. It needs the oCIS address (the OIDC issuer) and nothing else of oCIS: no database,
no service account, no shared secret.

## Supported oCIS versions

| oCIS | Status |
|---|---|
| 8.x | Supported. CI runs the stack tests against 8.2.2 on every pull request |
| 7.x and earlier | Not tested, not supported |
| 9.x and later | Not tested yet. The web application is built against the oCIS Web of the 8.x line |

The service depends on four things in oCIS: the OIDC discovery document and signing keys of
the identity provider, the `lg.i.un` claim for the login name, `GET /graph/v1.0/me?$expand=memberOf`
for the user's id and groups, and, for the web application, the way oCIS Web loads external
apps. [web-integration.md](web-integration.md) lists what was verified there. If you run a
different identity provider behind oCIS, the claims it puts in its tokens matter: see
`GROUPWARE_OIDC_AUDIENCE` below.

## Configuration

The service reads a YAML file given with `--config groupware.yaml`, and environment
variables. A variable wins over the file, and the file wins over the default. The image reads
only the environment unless you mount a file and pass `--config`.

The reference below lists every key. A test checks that each `GROUPWARE_*` variable and each
YAML key in the code appears on this page, so a new setting cannot be added without
documenting it. The README has the longer explanation of some of them, linked in the
notes.

| Variable | YAML key | Default | Notes |
|---|---|---|---|
| `GROUPWARE_OIDC_ISSUER` | `oidc_issuer` | none, required | The public URL of oCIS, which is also the OIDC issuer. The service contacts it on the first authenticated request and tries again after a failure, so it can start before oCIS. Meanwhile authenticated requests get `503` |
| `GROUPWARE_DATA_DIR` | `data_dir` | none, required (`/data` in the image) | The directory that holds all state. It must be writable by the service. See [backup.md](backup.md) |
| `GROUPWARE_HTTP_ADDR` | `http_addr` | `:8080` | The public listener |
| `GROUPWARE_DEBUG_ADDR` | `debug_addr` | `127.0.0.1:9180` (`:9180` in the image) | Where `/metrics` and `/healthz` are served, without authentication. Empty turns the listener off |
| `GROUPWARE_LOG_LEVEL` | `log_level` | `info` | `debug`, `info`, `warn` or `error`. Logs are JSON on standard output |
| `GROUPWARE_OIDC_AUDIENCE` | `oidc_audience` | `web` | The OAuth client ids whose tokens are accepted, comma separated (a list in YAML). A token passes when its `aud` or `azp` names one of them. `*` accepts every client and logs a warning at start. Empty is refused. Set it if oCIS Web uses another client id. See [security.md](security.md) |
| `GROUPWARE_OIDC_CA_FILE` | `oidc_ca_file` | none | A PEM file of extra CAs trusted when the service contacts the issuer and the Graph API |
| `GROUPWARE_OCIS_URL` | `ocis_url` | the issuer | Where the service calls the oCIS Graph API with the user's own token. Inside a cluster this can be the oCIS Service. It uses the CA file above |
| `GROUPWARE_ADMIN_SOCKET` | `admin_socket` | `admin.sock` in the data directory | The path of the admin socket. Set a short path when the data directory's path is long (see "The admin socket") |
| `GROUPWARE_IDENTITY_MAX_AGE` | `identity_max_age` | `720h` | The identity lease: how long an app password works after oCIS last confirmed its user. `0` turns it off and logs a warning at start. Negative is refused. See "Users who leave" |
| `GROUPWARE_APP_PASSWORD_MAX_LIFETIME` | `app_password_max_lifetime` | `4320h` | The lifetime of a new app password, and the longest one a request can ask for. At least `24h`. Existing passwords keep their expiry |
| `GROUPWARE_AUTH_MAX_FAILURES` | `auth_max_failures` | `10` | Failed app password sign-ins of one user from one address within the window before the service answers `429`. At least 1. See "Rate limiting" |
| `GROUPWARE_AUTH_FAILURE_WINDOW` | `auth_failure_window` | `15m` | How long a failed sign-in counts, and so how long a block lasts. Must be positive |
| `GROUPWARE_TRUSTED_PROXIES` | `trusted_proxies` | none | Addresses and networks of the reverse proxies in front of the service, comma separated (a list in YAML). Only they are believed when they send `X-Forwarded-For` |
| `GROUPWARE_COMPAT_PATHS` | `compat_paths` | `false` | Also serve the classic DAV layout below `/remote.php/dav`. The ingress has to route those paths. See [routing.md](routing.md) |
| `GROUPWARE_LEGACY_TOKEN_SECRET` | `legacy_token_secret` | none | The instance secret of a classic installation, needed to verify app tokens imported from it. See [migration.md](migration.md) |
| `GROUPWARE_LEGACY_TOKEN_TTL` | `legacy_token_ttl` | `4320h` | How long an imported token stays valid without being used |

Durations are Go durations such as `30m` or `720h`; there is no unit for days. A value that
does not parse stops the service at start with an error that names the variable.

Two more variables belong to the migration command only, and the running service ignores
them: `GROUPWARE_MIGRATE_DB_DSN` (the classic database address, so the password stays out of
the process list) and `GROUPWARE_MIGRATE_OCIS_TOKEN` (an oCIS administrator token that maps
classic users to oCIS users). See [classic-migrate.md](classic-migrate.md).

The Helm chart has a value for each setting; its README maps them.

## Routing

Something in front of oCIS has to send a fixed list of paths to this service, because the
web application, the DAV clients and the token validation all assume one domain.
[routing.md](routing.md) has the list and the snippets, and there are two ways to do it.

- An ingress or reverse proxy in front of oCIS. This is the supported way. Snippets for
  Traefik, nginx and Caddy are under `deploy/`, and the Helm chart can create the Ingress.
  CI runs the stack tests through it, with and without the classic paths.
- The proxy inside oCIS. oCIS can forward paths to another backend through
  `additional_policies` in `proxy.yaml`, which would need no ingress change. It does not
  work for DAV and is not supported. With oCIS 8.2.2 the proxy forwards everything except
  `REPORT`, because oCIS has its own `REPORT` route for any path that contains `/dav` and
  tries it first. Without `REPORT` there is no calendar-query, address-book-query or
  sync-collection, so no client gets past its first sync. The page records how this was
  found and a test fails if it changes.

## Users who leave, and the group snapshot

The service has no credential for oCIS. It sees a user only through the user's own token, so
oCIS cannot tell it that someone was disabled, deleted or removed from a group. Two things
follow, and both are bounded by `GROUPWARE_IDENTITY_MAX_AGE`.

The identity lease bounds how long an app password keeps working. Each sign-in with a token
tells oCIS's Graph API who the caller is, at most every five minutes, and stores when. An app
password works only while that time is younger than the lease, 30 days by default. A user who
is disabled or deleted in oCIS cannot get a token, so their passwords stop working when the
lease runs out. Users who stay active renew it themselves, and opening oCIS Web is enough. To
cut someone off at once, also run `ocis-groupware admin principals disable <user>`. Put that on
your offboarding checklist. [security.md](security.md) explains the reasoning, and the
[README](../README.md) describes the lease and what it changes for an upgrade.

The group snapshot decides who sees a group share. At the same sign-ins the service stores the
user's oCIS id and the ids and names of the user's groups. A collection shared with a group is
visible to a user when the group is in that user's snapshot. The service never asks oCIS for a
group's member list, which users cannot read. A user who joins or leaves a group in oCIS
sees the change at their next sign-in with a token, within five minutes while they are active.
A Basic request never uses a snapshot older than the lease. A user who only uses DAV clients
and does not open oCIS keeps the group shares they had until the lease runs out.

## The admin socket and CLI

The service creates a unix socket, `admin.sock` in the data directory, with mode `0600`. It
serves the admin API. There is no token: whoever can open the socket is an administrator,
which is the service's user and root. The service refuses to start when it cannot create the
socket. A socket path has a length limit of about 100 bytes, so a long data directory needs
`GROUPWARE_ADMIN_SOCKET` set to a short path on a local file system.

The same binary is the client:

```sh
ocis-groupware admin principals list [--json]
ocis-groupware admin principals disable <user>
ocis-groupware admin principals enable <user>
ocis-groupware admin principals purge <user> [--yes]
```

`<user>` is a username, `--sub <sub>` or `--owner <owner>`. `disable` refuses every sign-in
at once and deletes nothing, `enable` undoes it, `purge` deletes a disabled user's data and
shows what it would delete unless you give `--yes`. In a container the command is
`docker exec <container> /ocis-groupware admin principals list`, and on Kubernetes
`kubectl exec deploy/<release>-ocis-groupware -- /ocis-groupware admin principals list`.
Outside a container, pass `--config` or set `GROUPWARE_DATA_DIR` so the command finds the
socket. The [README](../README.md#administration) has the details of each command and its
output.

`admin migrate classic` is different. It opens the data directory itself, so the service has
to be stopped. See [migration.md](migration.md).

## Metrics, health and logs

The debug address (`GROUPWARE_DEBUG_ADDR`) serves `/metrics` in the Prometheus format and
`/healthz`. It has no authentication, so keep it off the ingress and off any port that
untrusted clients reach. The default is the loopback interface, and the image listens on all
interfaces so a scraper in another container can reach it.

`/healthz` returns `200` when the data directory is writable and `503` when it is not. It
does not check oCIS, so the service stays ready while oCIS is down. The check writes a file
and its result is reused for 10 seconds. The public port also answers `/healthz` and returns
`404` for `/metrics`.

Besides the Go and process metrics, the service exports:

| Metric | Meaning |
|---|---|
| `groupware_auth_failures_total` | Failed app password sign-ins counted by the rate limiter |
| `groupware_auth_rate_limited_total` | Sign-in attempts refused with `429` |
| `groupware_auth_limiter_entries` | Counters the rate limiter holds |
| `groupware_auth_identity_stale_total` | Sign-ins refused because oCIS has not confirmed the user within the lease |

A rise in the last one after a change to oCIS, or to `GROUPWARE_OCIS_URL`, means the service
cannot refresh its identity snapshots. Each refusal is also logged once per user and hour.

## Rate limiting

Failed HTTP Basic sign-ins are counted and slowed down, three ways: per user and address
together, per user alone, and per address alone. One user from one address can fail
`GROUPWARE_AUTH_MAX_FAILURES` times in `GROUPWARE_AUTH_FAILURE_WINDOW`. A whole user, and a
whole address, can fail ten times as often. After that the service answers `429` with a
`Retry-After` header and does not check the password, not even a right one. Successful
sign-ins are never counted and clear the pair's failures. Bearer tokens are not limited.

Behind a proxy, the address is the proxy's unless you list it in `GROUPWARE_TRUSTED_PROXIES`.
Then the service uses the rightmost `X-Forwarded-For` entry that is not itself a listed proxy.
Without that setting all clients behind one proxy share one counter. The counters live in
memory, at most 10,000 of them, and are lost at a restart. The
[README](../README.md#limiting-failed-sign-ins) has the rest.

## Sizing

[sizing.md](sizing.md) says what was measured (1,000 principals, calendars of up to 30,000
events, 200 polling clients), what a restart costs and how to repeat the run. It is a single
process, and the figures come from one machine. A size that is not in the tables was not
tried, so test it before you rely on it. Plan the disk for the data directory with room to grow, and alert at 80
percent use, because the service does not limit what a user can store (see below).

## Docker and Helm

The image is distroless and runs as uid 65532. It declares `/data` as a volume and sets
`GROUPWARE_DATA_DIR=/data` and `GROUPWARE_DEBUG_ADDR=:9180`. It exposes 8080 and 9180. With
a bind mount, give uid 65532 write access to the host directory. A minimal run:

```sh
docker run -d --name groupware -v groupware-data:/data \
  -e GROUPWARE_OIDC_ISSUER=https://ocis.example.com \
  -p 8080:8080 owncloud/ocis-groupware:<version>
```

The [Helm chart](../deploy/helm/ocis-groupware/README.md) runs one replica on a
PersistentVolumeClaim with the `Recreate` strategy. A second pod on the same volume cannot
start, so there is no replica count. Its README has every value, the probe, the Ingress and
the admin socket path limit. `docker-compose.yml` is a development stack, not a production
setup.

## Upgrading

[format.md](format.md) describes what a release may change in the data directory and the
steps to upgrade or go back. In short, read the release notes, back up the directory, replace
the image and check the log and `/healthz`. The rollback is the backup, not the old image
alone.

Some upgrades change behaviour without changing the format. The notes under "Upgrading" in
the [README](../README.md) cover the ones so far: the accepted clients check, the username
rule and the identity lease. Read them if you come from a release that predates them.

## Backup

[backup.md](backup.md) covers snapshots and copies, restoring, what a restore brings back and
what the directory does not hold.

## Sharing limits for your users

Users can share a calendar or address book with other users and groups. The limits below
affect what they may expect, so pass them on.

- A share gives `read` or `readwrite`. There is no free/busy-only level: someone who can
  read a shared calendar sees the whole event, including title, location, notes and
  attendees.
- The `CLASS` of an event (public, private, confidential) is stored and shown to clients, but
  the service does not enforce it. A private event in a shared calendar is as visible to the
  recipients as any other. Tell people to keep private events in a calendar they do not
  share.
- Recipients cannot share onward. Only the owner changes who a collection is shared with, and
  only the owner changes its description, time zone and components or deletes it. A recipient
  can change the display name, colour and order for themselves.
- A collection has at most 200 members, and a share names a user or a group, not an
  address.
- A share cannot be created over DAV. The web application and the Graph API create them.
- Group shares follow the group snapshot described above.

## Known limitations

- No storage quota. The service does not limit how much a user stores, in bytes or objects.
  Give the data directory its own volume, alert on its use, and disable a user who abuses it.
  See [security.md](security.md).
- Creating an app password does not ask the user to sign in again. The identity provider does
  not tell the service when the user last signed in, so anyone who controls a user's oCIS Web
  session can create one. The limits that apply are in [security.md](security.md). A step-up
  sign-in for this is planned for after 1.0.
- One process per data directory. There is no clustering or hot standby. A restart takes the
  service down for as long as it needs to load, see [sizing.md](sizing.md).
- Group membership is a snapshot, and offboarding is bounded by the lease, not immediate,
  unless you disable the user.
- The Graph API covers calendars, events, contacts and their sharing, and answers `501` for
  `$expand`, `$count`, `$search`, `delta`, `$batch` and attachments. See [graph.md](graph.md).
- Only oCIS 8.x is supported.
