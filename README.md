# ocis-groupware

Calendar and contacts for ownCloud Infinite Scale — CalDAV/CardDAV, Graph-shaped API, Vue UI

## Development

Requires Go 1.27.4 and [go-task](https://taskfile.dev).

```sh
task build
task test
GROUPWARE_OIDC_ISSUER=https://ocis.localhost GROUPWARE_DATA_DIR=$(mktemp -d) task run
```

Run `task --list-all` for the full list, or `task check` to run fmt/vet/lint/test
together (what CI runs).

Config is env vars and/or a YAML file passed via `--config groupware.yaml`; env wins
over file, file wins over defaults.

[docs/administration.md](docs/administration.md) is the operator's guide. It lists every
setting and a test keeps that list complete.

| Env var | YAML key | Notes |
|---|---|---|
| `GROUPWARE_HTTP_ADDR` | `http_addr` | Listen address, default `:8080` |
| `GROUPWARE_DEBUG_ADDR` | `debug_addr` | Optional, default `127.0.0.1:9180`. A second listener for `/metrics` and `/healthz`, without authentication (see "Metrics and health checks"). Empty turns it off. The container image sets it to `:9180` |
| `GROUPWARE_LOG_LEVEL` | `log_level` | `debug`, `info`, `warn` or `error`, default `info` |
| `GROUPWARE_OIDC_ISSUER` | `oidc_issuer` | **Required.** The oCIS public URL, which is also the OIDC issuer |
| `GROUPWARE_OIDC_AUDIENCE` | `oidc_audience` | Optional. The OAuth client IDs whose tokens are accepted, comma-separated (in YAML a string or a list). Default `web`, the client of oCIS Web. `*` accepts every client and logs a warning at startup. An empty value is refused (see "Accepted clients") |
| `GROUPWARE_OIDC_CA_FILE` | `oidc_ca_file` | Optional PEM bundle of extra CAs to trust when contacting the issuer |
| `GROUPWARE_OCIS_URL` | `ocis_url` | Optional. Where the service calls the oCIS Graph API to look up the signed-in user's id and groups, and to check the users and groups a share names. Defaults to the issuer URL. Uses the same CA file |
| `GROUPWARE_DATA_DIR` | `data_dir` | **Required.** Directory that holds all service state. The image sets it to `/data` |
| `GROUPWARE_ADMIN_SOCKET` | `admin_socket` | Path of the admin API's unix socket, default `admin.sock` in the data directory. Leave it alone unless the data directory cannot hold a socket (see below) |
| `GROUPWARE_LEGACY_TOKEN_SECRET` | `legacy_token_secret` | Optional. The instance secret of a classic installation whose app tokens were imported. Without it, imported tokens do not work (see below) |
| `GROUPWARE_COMPAT_PATHS` | `compat_paths` | Optional boolean, default `false`. Also serves the classic DAV layout below `/remote.php/dav`, for devices set up against a classic server. The ingress has to route those paths to the service (see `docs/routing.md`) |
| `GROUPWARE_LEGACY_TOKEN_TTL` | `legacy_token_ttl` | Optional Go duration, default `4320h` (180 days). How long an imported token stays valid without being used |
| `GROUPWARE_IDENTITY_MAX_AGE` | `identity_max_age` | Optional Go duration, default `720h` (30 days). How long an app password works after oCIS last confirmed its user. `0` turns the check off and logs a warning at startup. Negative values are refused (see "Signing in with an app password after offboarding") |
| `GROUPWARE_APP_PASSWORD_MAX_LIFETIME` | `app_password_max_lifetime` | Optional Go duration, default `4320h` (180 days), at least `24h`. The lifetime of a new app password when the request names none, and the longest it can ask for. Existing passwords keep their expiry (see "App passwords") |
| `GROUPWARE_AUTH_MAX_FAILURES` | `auth_max_failures` | Optional integer, default `10`. How many failed app password sign-ins of one user from one address are allowed within the window (see "Limiting failed sign-ins") |
| `GROUPWARE_AUTH_FAILURE_WINDOW` | `auth_failure_window` | Optional Go duration, default `15m`. How long failed sign-ins count, and so how long a block lasts |
| `GROUPWARE_TRUSTED_PROXIES` | `trusted_proxies` | Optional. Comma-separated addresses and networks (`10.0.0.0/8,192.168.1.5`) of the reverse proxies in front of the service. In YAML, a list. Only they are believed when they send `X-Forwarded-For`. Empty by default |

## Data directory

ocis-groupware keeps its state in one directory, `GROUPWARE_DATA_DIR`, and opens it with
an exclusive lock: a second process on the same directory fails to start. The directory
is created if missing and must be writable by the service. `/healthz` returns `503` when it is not.
It checks by creating and removing a file, and reuses the result for 10 seconds, so a busy
health check does not write to the volume on every request.

The image runs as uid 65532 and declares `/data` as a volume owned by that user. The
compose stack mounts the named volume `groupware-data` there. When you bind-mount a host
directory instead, give uid 65532 write access to it.

[docs/backup.md](docs/backup.md) says how to back the directory up and restore it. [docs/format.md](docs/format.md) describes its layout, which files carry a version, and how to
upgrade and go back.

Each user has a directory below `owners/` with a `principal.json`. Its `disabled` field,
when `true`, refuses every sign-in of that user, with app passwords and with bearer
tokens alike, until it is `false` again. Nothing else changes: calendars, contacts and
app passwords stay, so enabling the user restores every device without pairing it again.
A file without the field counts as enabled. Releases before the field was added do not
know it and ignore it, so a downgrade lets disabled users sign in again.

The same file holds a snapshot of the user's oCIS identity: `ocis_id`, the `groups` the
user belongs to (each with `id` and `name`) and `identity_at`, the time the snapshot was
taken. A file without these fields has no snapshot yet and loads as before.

The snapshot is filled at sign-ins with a bearer token (the web app, and DAV clients that
use OIDC). The service calls `GET /graph/v1.0/me?$expand=memberOf` on `GROUPWARE_OCIS_URL`
with the user's own token, so it needs no credential for oCIS, and it asks at most once
every 5 minutes per user. If the call fails, the old snapshot stays and the failure is
logged; the sign-in still succeeds. Sign-ins with an app password carry no token and
do not refresh it. Group membership is therefore as old as the user's last sign-in with a
token, at most a few minutes behind while the user is active. The snapshot of a disabled
user is not updated.

An owner who shares a calendar or address book gets a `shares.json` next to it. It lists,
for each shared collection, the collection's store id and its members. A member is a user
or a group, named by the oCIS id, with a display name kept for listings and an access
level, `read` or `readwrite`. A collection has at most 200 members, and the owner cannot
be one of them. The service reads all of these files at start and keeps a lookup by
grantee in memory, so a share is stored once, with its owner. A `shares.json` the service
cannot parse is logged and skipped, which means its owner shares nothing until the file
is fixed. Deleting the file stops all sharing by that user. Shares end with what they
belong to: deleting a collection through the service drops its shares, a collection that
disappeared while the service was down is dropped at the next start, and purging a user
removes the user's shares. Shares that name a purged user as the grantee stay in the
owners' files and reach nothing.

A recipient sees a shared collection among their own as `shared-<collection id>`, with the
owner's name for it followed by the owner's display name in brackets. The access level of the
share decides what the recipient may do: `read` reads, `readwrite` also writes objects, and
only the owner changes the collection's description, time zone and components, or deletes it.
The recipient may change the display name, colour and order, because clients do that on
every calendar they add. Those changes are kept for that recipient alone, in
`shared_with_me.json` in the recipient's own directory, next to a flag that hides the
collection from listings. The file holds nothing else about the share. Access is decided
on each request from the recipient's oCIS id and group snapshot, so a revoked share, or a
group the user has left, stops working at once. The snapshot itself is as fresh as the
user's last sign-in with a token.

DAV clients find these collections in the recipient's own home, for example
`/dav/calendars/bob/shared-<id>/`, with the privileges of the share. A write the share does
not allow is answered `403` with `DAV:need-privileges`. This works for HTTP Basic and Bearer
requests alike. There is no way to create a share over DAV; the web application and the Graph
permission endpoints below create them.

The service also creates `admin.sock` in the data directory, a unix socket that serves the
admin API: listing users, disabling and enabling them, and purging a disabled user's data.
The `admin` command (see [Administration](#administration)) uses it; so can
`curl --unix-socket /data/admin.sock http://admin/v1/principals`. There is no token. The
socket has mode 0600 and the data directory is private to the service's user, so only
that user and root can connect. The file is removed on
shutdown and a leftover from a crash is replaced on the next start. The service refuses to
start when it cannot create the socket, which happens on a filesystem without unix socket
support (some bind mounts of Docker Desktop) or when the path is longer than the platform
allows (104 bytes on macOS, 108 on Linux). Set `admin_socket` to a short path on a local
filesystem then.

## Authentication

Every request needs an `Authorization: Bearer <access token>` header, validated
against the keys the oCIS identity provider publishes. The exceptions are
`/healthz`, `/.well-known/*` and `/web/*`. The token's `sub` claim
identifies the user.

CalDAV and CardDAV are served under `/dav`. There a request can also carry
`Authorization: Basic` with the username and an app password, which is how DAV
clients sign in. A request under `/dav` without valid credentials gets `401` with
`WWW-Authenticate: Basic realm="ocis-groupware"`. Each user reaches only their own
calendars and address books. A user's first request with a bearer token creates
their default address book and calendar.

With `GROUPWARE_COMPAT_PATHS=true` the same data is also served below `/remote.php/dav`
in the classic layout: principals at `/remote.php/dav/principals/users/{user}/`, address
books at `/remote.php/dav/addressbooks/users/{user}/` and calendars at
`/remote.php/dav/calendars/{user}/`. Sign-in and access rules are the same as for `/dav`,
and the classic login name has to equal the oCIS login name. `docs/routing.md` says which
paths the ingress sends to the service.

A user whose data was imported before their first sign-in has no subject yet, only the
oCIS user id. At the first bearer sign-in with an unknown subject, the service asks oCIS
who the token belongs to. If an imported user without a subject has that id, the subject
is bound to it and the user finds the imported data. A user that already has a subject is
never taken over, and a disabled imported user is refused with `403`. While imported users
without a subject exist and oCIS cannot be reached, a sign-in with a new subject gets `503`
and is tried again on the next request, so that it does not create a second, empty user.

### Accepted clients

A token is accepted only when it was issued to one of the clients in
`GROUPWARE_OIDC_AUDIENCE`: its `aud` claim contains one of them, or its `azp` claim
equals one. oCIS puts the client ID of the requesting app in `aud`, and the oCIS Web
client is `web`, which is the default. Identity providers such as Keycloak often put a
generic value like `account` in `aud` and name the client in `azp`, so both claims are
checked. Tokens for other clients of the same identity provider get `401` with
`error="invalid_token"`, which keeps a token leaked from an unrelated application from
working here.

The check does not look at the token type. In oCIS the ID token of the `web` client
carries the same audience as its access token, so refusing it would add nothing, and
the claims that tell the types apart differ between identity providers.

`*` turns the check off. An explicitly empty value is a configuration error, so that a
blank variable cannot disable the check by accident.

Upgrading: before this check existed, `GROUPWARE_OIDC_AUDIENCE` was optional and empty
meant that any token of the identity provider was accepted. If your oCIS Web uses a
client ID other than `web` (`WEB_OIDC_CLIENT_ID`), set `GROUPWARE_OIDC_AUDIENCE` to it
before upgrading, or every web sign-in gets `401`. The same goes for scripts that call
the Graph API with a token of another client: list that client too. A setting that held
one client ID keeps working unchanged.

### Usernames

DAV clients sign in with the oCIS username, so a username belongs to one account at a
time. A sign-in with a token that names a username held by another account moves the name
only if the holder can no longer use it: the holder is disabled, or its identity lease
has run out (see "The identity lease"). With the lease off, only a disabled holder frees a
name. A holder who renames in oCIS releases the old name at their own next sign-in.

Otherwise the newcomer is signed in and provisioned without a username. The web
application and the Graph API work for them, DAV and app passwords do not. The service logs
a warning with both owners, `GET /groupware/v1/me` returns `username: ""` and
`username_conflict: true`, and the Devices page says that the name is in use by another
account. The claim is made again at every sign-in and the principal file is written only
when the outcome changes. To resolve it, run `ocis-groupware admin principals disable
<holder>`: the newcomer's next sign-in takes the name. A holder that was deleted or renamed
in oCIS frees the name by itself when its lease runs out.

Upgrading: until now the newest sign-in took a username from its holder at once. That
let anyone who can set `preferred_username` at a permissive identity provider take over an
active user's DAV address. If two accounts really share a name, say after an account was
recreated in oCIS under the same login, the new account has no DAV access until the old one
is disabled or its lease runs out.

## Web application

The service serves its web application, a build of `web/`, under `/web/` without
authentication. The build output is embedded in the binary at compile time from
`web/dist`. That directory holds only a placeholder in git, so a binary built without
the web build answers `404` for every path under `/web/`, and the Go tests do not need
Node. The Docker image always contains the build.

`web/` is a Vue 3 and TypeScript project built with ownCloud's extension SDK. It is an
application for ownCloud Web. It adds two entries to the application menu, Calendar and
Contacts, each with its own navigation, and a Devices page in both. oCIS
Web loads `/web/groupware.js` when the Web configuration lists the application under
`external_apps` (`deploy/ocis/web.yaml` is such a configuration, which the compose
stack mounts as `/etc/ocis/web.yaml`), and provides `vue`, `pinia`, `luxon`, `vue3-gettext`,
`@ownclouders/web-pkg` and `@ownclouders/web-client` to it at run time, so the bundle
contains none of them. `vue-router` is not provided; the application imports only
its types and routes through the composables of `web-pkg`. The ownCloud packages are
pinned to the Web version that the supported oCIS release ships (Web 12.5.0 in oCIS
8.2.x) and are updated by hand with it. [docs/web-integration.md](docs/web-integration.md)
records what Web provides to the application and which versions this was verified
against.

The application reads and writes through the Graph paths of this service with the
authenticated HTTP client of oCIS Web, which carries the signed-in user's token. The
typed client lives in `web/src/api`; its types follow the golden files in
`internal/graphapi/testdata/contract`, which the Go tests of the facade write and the
unit tests of `web/` load, so a change of shape on either side fails a test. A failed
call shows an error toast with the server's message.

The calendar page draws the user's calendars with FullCalendar (MIT, bundled into
`groupware.js`) in month, week and day views. The events come from the server-expanded
calendar view for the range on screen, so recurring events need no recurrence library in
the browser. The controls above the grid (Today, the arrows, the title, Month, Week and Day)
are buttons of the design system that drive FullCalendar, and its colours follow the theme of
oCIS Web, dark mode included. Each calendar has a checkbox in the list beside the grid, with
calendars shared by other people under their own heading; which calendars are switched off is
kept in the browser's local storage. On a narrow window the list folds into a menu behind a
button, and below 640 px the page opens on the day. The keys `t`, `n`, `p`, `m`, `w`, `d` and
`c` go to today, next, previous, the three views and a new event while no field has the focus. A calendar without a colour gets one
from a fixed palette that depends only on its id. Event times are converted from the
zone the server reports to the browser's zone.

A user adds a calendar with the plus button above the list. The other actions of a calendar
are in the menu at the end of its row. Only the owner of a calendar sees Edit, Share and
Delete; a recipient who may edit its events can still import into it. A delete asks for
confirmation first.

Marking a day or a span of time in the grid, or the New event button, opens the event
dialog. It has a title, calendar, all-day switch, start and end, time zone, place,
status, categories, attendees and notes. Clicking an event shows its details in the
sidebar of oCIS Web, with the rows it has something to say about: when, where, the
calendar, the pattern, the reminder, the attendees with their answers and the notes. The
sidebar offers Edit and Delete when the calendar can be written to, and a note when it
cannot; there is no form that is switched off. Edit opens the same dialog as New event
with the values of the event, and so does a second click on the same event; saving sends
only the fields that changed, with the event's ETag in `If-Match`, and delete asks first.
On a narrow window the sidebar closes before a dialog opens. Escape closes every dialog. The page asks the server for times in the browser's
time zone with `Prefer: outlook.timezone`, as Graph clients do, so an event is shown and
edited in that zone whatever zone it was created in.

The dialog sets a display reminder: none, at the time of the event, or a number of
minutes, hours, days or a week before. It is stored as the event's first display alarm,
so other calendar apps show it too. A reminder an event already has with another number
of minutes stays selectable. This page does not show notifications itself.

The dialog also edits the pattern of a repeating event: daily, weekly (with days),
monthly and yearly (on a day of the month or on a weekday such as the second Thursday),
an interval, and an end after a number of times or on a date. The server writes a
pattern as an iCalendar rule and expands it, so the page only draws the occurrences it
gets. Edit and Delete on an occurrence ask whether the choice is for this event or all
events. "This event" edits the occurrence (the server stores an override) and delete excludes that
day. "All events" edits and deletes the series. A series whose rule the Graph pattern
cannot express is reported as such by the server; the sidebar shows its events with a
note and without Edit and Delete.

Each calendar's menu has Export, which downloads it as one `.ics` file named after the
calendar, and the calendars the user can write to have Import too. The Import button above
the grid offers the same for each of them. Import
sends the chosen file to `POST /groupware/v1/calendars/{id}/import` and shows the server's
report: how many events were added, replaced or failed, and for each failure its position in
the file, its UID and the reason. The events on screen are read again afterwards. The two
endpoints are described under Import and export below.

The gear on the calendar page opens the settings for the time zone, the first day of the week and
whether week numbers show. They are kept per user in the browser's local storage, not on the
server, and a value that is missing or unusable falls back to its default (the browser's zone,
Monday, no week numbers). The zone is the one the grid shows times in, the one asked for with
`Prefer: outlook.timezone`, and the one a new event starts in. FullCalendar's Luxon plugin
(MIT) does the conversion, using the Luxon that oCIS Web provides.

The Contacts page (`web/src/contacts` and `web/src/pages/ContactsPage.vue`) shows the
user's address books next to a list of contacts and the details of the chosen one. The
list covers one address book or all of them, is searched by name, company, email
address, phone number and category as you type, and can be sorted by name, surname or
company. Searching and sorting happen in the browser on the contacts that were loaded.

A contact is created in an address book the user may write to and edited or deleted
there; shared address books that are read only offer neither. The form covers every
field the Graph contact has: name parts, display name, company, job title and
department, emails, phones, three addresses, messaging addresses, website, birthday,
spouse, children, assistant, manager, phonetic names and notes. A save sends only the
fields that changed, together with the contact's ETag, so a contact that was changed
elsewhere in the meantime is not overwritten. A birthday without a year is shown in the
details and kept as it is unless a date is picked.

The details show the contact's photo, or its initials when there is none. Where the user
may write, a photo is added, changed or removed from there. The service takes JPEG and
PNG images of at most 1 MB, and the browser refuses anything else before it uploads.
The image is read through the authenticated client and shown from a local object URL,
so the photo needs no extra route and no token in a URL.

Contact groups are categories on the contacts. The sidebar lists the groups of the
contacts that are shown, with the number of members, and choosing one narrows the list.
A contact is added to or taken out of a group in its details, with the existing names
offered while typing. A group can be renamed or deleted, which rewrites the category on
each of its contacts in the shown address books that the user may write to, one request
per contact; contacts in read-only address books keep it. Group cards, which some
clients write, are listed as read-only groups: they can be chosen to filter the list,
and the UI never writes them.

Address books are created from the sidebar. The owner of the chosen address book can
rename it, and delete it after a confirmation that names it and says its contacts go
with it. The default address book cannot be deleted from the UI, and address books that
were shared with the user offer neither action. Any address book the user can read downloads as a `.vcf` file named after it. Where the
user may write, a vCard file can be imported into it: the browser sends the file as it
is, and the page lists how many cards were created, updated or failed, with the reason
for each failed one, then reloads the contacts. Both use the import and export
endpoints described below.

Sharing is done from the lists. The owner of a calendar or address book gets a Share
button that opens a dialog with everyone it is shared with, each with an access menu
(can view or can edit) and a button to remove them. People are added by searching the
oCIS directory: the dialog calls oCIS Graph `users` and `groups` with `$search` from the
browser, using the signed-in user's own token, and offers users and groups together once
three characters are typed, because the directory answers nothing shorter. A search that
the directory refuses, such as the group search for a user who may not list groups, leaves
out those results and keeps the others. Someone who already has access is not offered
again. The service checks the chosen user or group against the directory when it saves the
share. Calendars and address books shared with the user show who owns them and whether
they are read only or can be edited, and only the owner sees the Share button.

The Devices page has the details a CalDAV or CardDAV app needs: the server address, the
username and the calendar and address book home addresses from `GET /groupware/v1/me`,
each with a copy button, and short setup hints for Thunderbird, Apple's apps and DAVx5.
Below them it lists the user's app passwords with their creation, expiry and last use,
and marks the ones that have expired. A new app password takes a name and a lifetime of
90, 30 or 7 days or the longest the server allows, which is also the default. The dialog shows the password once, with a button to copy it, and
cannot be dismissed by accident while it does; once closed, the password cannot be read
again. Revoking one asks first and then refuses the devices that use it.

The application is in English. Every text goes through gettext, and
[docs/translations.md](docs/translations.md) describes how to extract the messages and
add a language. The application's icon is `web/src/assets/icon.svg`.

Development needs Node 26:

```sh
task web:install   # npm ci
task web:check     # eslint, vue-tsc, vitest and the build, what CI runs
task web:build     # writes web/dist; the next go build embeds it
```

In `web/`, `npm run dev` rebuilds on every change. A running local stack then serves
the new build only after the Go binary is rebuilt, since it is embedded.

Only `GET` and `HEAD` are answered, and only for plain files: no directory listings, no
index, nothing whose name starts with a dot. Each response carries its content type
and `X-Content-Type-Options: nosniff`. `/web/groupware.js`, the entry that oCIS Web
loads, is served with `Cache-Control: no-cache` because its name never changes. Every
other file in the build carries a content hash in its name and is served as immutable
for a year.

## App passwords

DAV clients sign in with an app password instead of an OIDC token. Create one with a
bearer token for your user (`$TOKEN`):

```sh
curl -X POST https://ocis.localhost/groupware/v1/app-passwords \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "Phone"}'
```

Add `"expires_in_days": 30` to the body for a password that expires sooner. The value is a
whole number from 1 to the maximum lifetime, 180 days unless `GROUPWARE_APP_PASSWORD_MAX_LIFETIME`
says otherwise. A request for more gets `400` with the limit in the message.

The answer has status `201` and carries the `id`, the `name`, `created_at`, `expires_at`
and the `password`. **The password is shown only once**: it is stored as a hash, and no
request returns it again. An app password is valid for the maximum lifetime unless the request asks for less. A user
can have at most 50, and a name has at most 100 bytes. Creating and revoking an app password
is logged at Info with the owner, the id, the OAuth client of the token and the client
address (the one the rate limiter counts, so set `GROUPWARE_TRUSTED_PROXIES` behind a
proxy), and never with the password. See [docs/security.md](docs/security.md).

Upgrading: new app passwords, and imported tokens after their first use, now last 180
days by default instead of 365, so devices need a new password twice as often. App
passwords that exist keep the expiry they were created with. To keep the old length, set
`GROUPWARE_APP_PASSWORD_MAX_LIFETIME=8760h`.

```sh
# List your app passwords (without their secrets). The answer also carries
# max_lifetime_days, the longest lifetime a new one can have.
curl -H "Authorization: Bearer $TOKEN" https://ocis.localhost/groupware/v1/app-passwords

# Revoke one; clients that use it are refused from then on
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  https://ocis.localhost/groupware/v1/app-passwords/<id>
```

The endpoint accepts bearer tokens only; an app password does not work there. A user
sees and revokes only their own app passwords, and revoking an id that does not exist or
belongs to someone else answers `404`.

To add an account in a CalDAV or CardDAV client, enter the server address (for example
`https://ocis.localhost`), your oCIS username (`preferred_username`) and the app password.
Clients that discover the account themselves find `/dav/` through `/.well-known/caldav` and
`/.well-known/carddav`. Use a separate app password for each device, so you can revoke one
without touching the others.

### Imported classic app tokens

App tokens imported from a classic installation are listed with the app passwords and
sign in the same way, over HTTP Basic with the classic username and the old token. The
classic server keeps a token as `sha512(token . secret)` with its instance secret, so the
service needs that secret in `GROUPWARE_LEGACY_TOKEN_SECRET` to recognise the token. At the
first successful sign-in the service stores a bcrypt hash of the token and forgets the
digest; from then on the token is an ordinary app password and is valid for the maximum lifetime. A
token that is not used expires 180 days after its last use (or its import), or after
`GROUPWARE_LEGACY_TOKEN_TTL`. Checks of imported tokens go through the same limiter as app
passwords (see below).

### The identity lease

The service holds no credential for oCIS and sees a user only through that user's own
bearer token. When someone is disabled or deleted in oCIS, or removed from a group, nothing
tells the service. What it can know is when oCIS last confirmed the user: each bearer
sign-in asks oCIS for the user's id and groups (`GET /me?$expand=memberOf`) with that
user's token, at most every five minutes, and stores the answer with its time.

A Basic sign-in succeeds only if that time lies within `GROUPWARE_IDENTITY_MAX_AGE` of
now, 30 days by default. Otherwise the request gets the same `401` with
`WWW-Authenticate: Basic` as a wrong password. This covers app passwords and imported
classic tokens on `/dav` and on the classic paths. The check runs after the password has
been compared, so the answer and the time it takes do not show it, and it does not count
as a failed guess for the rate limiter: a user whose lease ran out is not locked out, and
signs in again as soon as it is renewed. A principal that oCIS never confirmed has
no lease at all and is refused. A refused imported token is not used up.

Opening oCIS Web, or any other request with a bearer token, renews the lease, and the
device needs no new setup. The web application does this by itself: once per page load, as
soon as oCIS Web knows the user, it calls `GET /groupware/v1/me` with the user's token,
whichever app of oCIS Web is open, so a user who only works in Files keeps their devices
signed in. The call is skipped in public link pages, and a failure is ignored. `GET /groupware/v1/me` returns `app_passwords_valid_until`, the
end of the current lease, or `null` when the check is off. The Devices page shows that date, with a warning when fewer than 7 days remain, and shows nothing when it is `null`. The service logs a refusal at
Info once per user and hour and counts them in `groupware_auth_identity_stale_total`.
`admin principals list` shows the age of each user's last confirmation and marks those that
are past the lease as stale.

The same time bounds the group memberships the service holds. A Basic request never runs
with a membership snapshot older than the lease, so a collection shared with a group stops
being listed to a removed member within that time.

#### Signing in with an app password after offboarding

Disabling or deleting a user in oCIS does not reach this service right away. App
passwords of a removed user keep working until their identity lease runs out
(`GROUPWARE_IDENTITY_MAX_AGE`, 30 days by default), and so do their group shares. To cut
access at once, also run `ocis-groupware admin principals disable <user>`.

The lease does not help against a stolen app password of a user who stays active, because
that user's own sign-ins keep renewing it. Revoke the password.

#### Upgrading

Before the lease, an app password worked until it expired, whether or not the user ever
used oCIS again. A user who only uses DAV clients and does not open oCIS (or call the API
with a token) for 30 days now gets `401` on every device, and one visit to oCIS Web fixes
it without touching the devices. The time counts from the user's last confirmation, so a user
whose last sign-in with a token was a month ago is cut off on the day of the upgrade, and
a principal that never had one is refused until the next sign-in with a token. If you need the old behaviour, set
`GROUPWARE_IDENTITY_MAX_AGE` to a longer duration, or to `0` to switch the check off.

The check also needs the service to reach the oCIS Graph API (`GROUPWARE_OCIS_URL`). If it
cannot, no lease is renewed and every user who only uses DAV clients drops off after the
period. A failed lookup is logged at Warn, and `admin principals list` shows the ages.
Imported principals count from the time of the import, so classic tokens work for the
period after a migration unless the user signs in with a token before then.

### Limiting failed sign-ins

Guessing an app password over HTTP Basic is slowed down. The service counts failed Basic
sign-ins of the DAV endpoints, three ways: per user and address together, per user, and per
address. One user from one address may fail `GROUPWARE_AUTH_MAX_FAILURES` times (default 10)
within `GROUPWARE_AUTH_FAILURE_WINDOW` (default 15 minutes). A whole user, and a whole
address, may fail ten times as often, which stops a guesser who spreads the attempts over
many addresses or many users while one person's typos do not lock others out. Once a limit
is reached, every Basic request that falls under it gets `429 Too Many Requests` with a
`Retry-After` header in seconds, and the password is not checked, not even a right one. The
block ends when the window of the first failure has passed.

A successful sign-in is never counted and clears the failures of that user and address
pair. Bearer tokens are not limited. Imported classic tokens are compared only while the
limiter lets the request through.

The address is the one of the TCP peer. Behind a reverse proxy that is the proxy, and all
clients would share one counter, so list the proxies in `GROUPWARE_TRUSTED_PROXIES`. From a
listed proxy the service takes the client from `X-Forwarded-For`: the rightmost entry that
is not itself a listed proxy. From any other peer the header is ignored, so a client cannot
choose the address it is counted under. IPv6 clients are counted by their /64 network.

The counters live in memory and are lost on restart. At most 10000 are kept; when that is
exceeded the least recently used one is dropped. They are exposed at `/metrics` on the
debug address:
`groupware_auth_failures_total`, `groupware_auth_rate_limited_total` and
`groupware_auth_limiter_entries`.

### Metrics and health checks

`/metrics` is served on its own listener, `GROUPWARE_DEBUG_ADDR`, which defaults to
`127.0.0.1:9180`. It needs no token, so it is not on the public port: the public port
answers `404` for `/metrics`. `/healthz` is served on both. Scrape the debug address from
inside the host or cluster. To reach it from another container or pod, set the address to
`:9180` (the image does) and keep the port off the ingress and off any published port that
untrusted clients can reach. If you scraped `/metrics` through the ingress or on port 8080
before, point the scraper at the debug port instead.

ocis-groupware contacts the issuer on the first authenticated request, and retries after
a failure, so it can start before oCIS is ready. While the issuer is
unreachable, authenticated requests get `503`.

## Graph API

The calendar and contacts part of the Microsoft Graph API is served below
`/graph/v1.0/`. It takes the same OIDC bearer token as the other endpoints and nothing
else, so app passwords do not work here. Errors use Graph's body, `{"error": {"code",
"message", "innerError": {"request-id", "date"}}}`. Anything the service does not
implement answers `501` with the code `notImplemented`, so a client can tell an
unsupported request from a missing item.

[docs/graph.md](docs/graph.md) explains how events and contacts map to Graph fields, what the
mapping loses and what the query options accept. [docs/graph-openapi.yaml](docs/graph-openapi.yaml)
is an OpenAPI 3.0 description of every path, kept in step with the routes and the test fixtures by
the tests of `internal/graphapi`.

Calendars and contact folders have the same id for their owner and for everyone they
are shared with: the URL-safe base64 form, without padding, of the collection id. List
answers carry `@odata.nextLink` when more items follow; `$top` (1 to 1000, default 100)
and `$skip` select the page.

Lists and single items take `$select` with top-level property names, such as
`$select=subject,start`. `id` and `@odata.etag` are always included. An unknown name is
`400`, and a nested one such as `start/dateTime` is `501`. Event and contact lists also take
`$orderby` with one property and an optional `asc` or `desc`. The order is applied before the
page is cut, and the next link keeps all options. Events can be ordered by `subject`,
`start/dateTime`, `end/dateTime`, `createdDateTime` and `lastModifiedDateTime`; contacts by
`displayName` (the default), `givenName`, `surname`, `companyName` and
`lastModifiedDateTime`. Text sorts without regard to case. More than one property, or a
property outside these lists, is `501`; a property the resource does not have is `400`.
`$expand`, `$count`, `$search` and any other `$` option answer `501`, and so does `$filter`
except on event lists.

### Calendars

| Request | Answer |
|---|---|
| `GET /graph/v1.0/me/calendars` | The calendars the user sees, paged |
| `POST /graph/v1.0/me/calendars` | Creates a calendar from `name` and an optional `hexColor` (`#rrggbb`); `201` |
| `GET`, `PATCH /graph/v1.0/me/calendars/{id}` | One calendar; `PATCH` changes `name` and `hexColor` |
| `DELETE /graph/v1.0/me/calendars/{id}` | Deletes the calendar and its events; `204` |
| `GET`, `PATCH /graph/v1.0/me/calendar` | The default calendar, the oldest one the user owns |

A calendar carries `canEdit` (may change events), `canShare` (owner only) and
`owner.name`. A user who is not the owner gets `403` from `PATCH` and `DELETE`. An id
that is not one of the user's calendars answers `404`, whether it does not exist or
belongs to someone else. Calendars made here hold events, and the DAV URL of a new one
carries a generated name.

#### Calendar permissions

The owner of a calendar manages who it is shared with below the calendar:

| Request | Answer |
|---|---|
| `GET /graph/v1.0/me/calendars/{id}/calendarPermissions` | The users and groups the calendar is shared with, paged |
| `POST /graph/v1.0/me/calendars/{id}/calendarPermissions` | Shares the calendar; `201` with the permission |
| `GET`, `PATCH`, `DELETE /graph/v1.0/me/calendars/{id}/calendarPermissions/{permissionId}` | One permission; `PATCH` changes the `role`; `DELETE` revokes it with `204` |

A permission has Graph's `role` (`read` or `write`, the only two a share can give),
`allowedRoles`, `isRemovable` and `emailAddress.name`, which holds the display name the
user or group had when it was shared. One field is added: `grantee`, `{"type": "user" |
"group", "id": "<oCIS id>"}`. A `POST` body carries `role` and `grantee`; any
`emailAddress` in it is ignored. Before it stores a share, the service asks oCIS, with the
caller's own token, whether that user or group exists. A grantee oCIS does not know is
`400`, a failed lookup is `502`, a grantee that already has a permission is `409`, and
sharing with oneself is `400`.

Only the owner can use these endpoints. Someone the calendar is shared with gets `403`,
and anyone else gets `404`, as for the calendar itself. A change takes effect for the
recipients' DAV clients with their next request.

### Events

| Request | Answer |
|---|---|
| `GET /graph/v1.0/me/events`, `/me/calendar/events` | The events of the default calendar, the oldest one the user owns. A series is one item, its master |
| `GET /graph/v1.0/me/calendars/{id}/events` | The events of one calendar, own or shared |
| `GET /graph/v1.0/me/events/{id}`, `/me/calendars/{id}/events/{id}` | One event, or one occurrence of a series |
| `GET /graph/v1.0/me/calendarView?startDateTime=&endDateTime=` | The occurrences that overlap the window, series expanded, from every calendar the user sees; also below `/me/calendar` and `/me/calendars/{id}` |
| `POST /graph/v1.0/me/events`, `/me/calendar/events`, `/me/calendars/{id}/events` | Creates an event from the fields in the event mapping below; `start` and `end` are required; `201` |
| `PATCH /graph/v1.0/me/events/{id}` | Changes the fields in the body and leaves everything else of the stored event as it is; on an occurrence id it writes an override for that occurrence only |
| `DELETE /graph/v1.0/me/events/{id}` | Deletes the event with its series and overrides; on an occurrence id it excludes that date; `204` |

An event id is the calendar id, a dot and the URL-safe base64 form of the object's name in the
calendar. An occurrence id adds a dot and the occurrence's `RECURRENCE-ID` in UTC, such as
`...20261120T090000Z`. `@odata.etag` carries the object's ETag as a weak validator, and
`changeKey` the bare value. Events in the calendar view come with `type` `singleInstance`,
`occurrence` or `exception`, and occurrences have a `seriesMasterId`. The window may be up to five
years long; times without an offset are UTC. An exception date is left out, a moved occurrence
shows at its new time, and an occurrence that overlaps the window by any amount is included.

`If-Match` is honoured on `PATCH` and `DELETE` and answers `412` with the code `preconditionFailed`
when the event changed; `*` and the weak or bare form of the tag all work. Every write is also
checked against the ETag it read, so two writers cannot overwrite each other silently. A user
whose access to the calendar is read-only gets `403`. A `PATCH` on an occurrence cannot carry a
`recurrence`, and an occurrence that the series does not have, or that was excluded, answers
`404`. Changes show to DAV clients at the next sync like any other write, and no invitations or
updates are sent to attendees.

Times are shown in UTC, or in the zone of `Prefer: outlook.timezone="..."`, which the answer
repeats in `Preference-Applied`. `delta` and `/instances` answer `501`.

Event lists, including `calendarView`, take a limited `$filter`: conditions joined by `and`.
A condition is `start/dateTime` or `end/dateTime` with `ge`, `gt`, `le` or `lt` and a time,
or `subject` with `eq`, `startswith(subject,'...')` or `contains(subject,'...')`. A time is a
quoted or bare RFC 3339 value or a date; without an offset it is UTC, and it names an instant,
so the zone events are shown in does not change the result. Text compares without regard to
case, and a quote inside a string is written twice. A series in `/events` is one item and is
tested by its first occurrence; in `calendarView` each occurrence is tested. Valid OData
outside this grammar (`or`, `not`, parentheses, `ne`, `eq` on a time, other properties and
functions) answers `501`; an expression that is not valid answers `400`.

### Event mapping

Events are stored as iCalendar and shown as Graph events. The mapping loses some detail,
and what it does not map is kept as it is.

| Graph | iCalendar |
|---|---|
| `subject`, `body.content`, `location.displayName` | `SUMMARY`, `DESCRIPTION`, `LOCATION`. Bodies are plain text; `html` is refused with `400` |
| `start`, `end`, `isAllDay` | `DTSTART`, `DTEND` (or `DURATION`). Times are shown in the zone of `Prefer: outlook.timezone="..."`, UTC by default. Floating times read as UTC |
| `showAs` | `TRANSP` and `STATUS`: `free` is transparent, `tentative` is `STATUS:TENTATIVE`, everything else is busy |
| `sensitivity` | `CLASS`. `personal` is stored as private |
| `categories`, `attendees` | `CATEGORIES`, `ATTENDEE` (`CN`, `ROLE`, `CUTYPE`, `PARTSTAT`). No invitations are sent |
| `isReminderOn`, `reminderMinutesBeforeStart` | the first display `VALARM` with a trigger before the start |
| `recurrence` | `RRULE`, for daily, weekly, monthly and yearly patterns, absolute and relative |

Zone names are IANA names or Windows names. A Windows name on a single event is stored as
the UTC time; on a recurring event it is kept as the zone of the rule. A rule the pattern
cannot express, such as one with `BYHOUR`, comes back as `recurrence: null` with
`"groupware.recurrenceEditable": false`, and a `PATCH` that sends `recurrence: null` leaves
it alone. A `PATCH` changes only the fields it sends and keeps every other property, alarm
and attendee parameter.

### Contact folders and contacts

| Request | Answer |
|---|---|
| `GET /graph/v1.0/me/contactFolders` | The address books the user sees, paged |
| `POST /graph/v1.0/me/contactFolders` | Creates an address book from `displayName`; `201` |
| `GET`, `PATCH /graph/v1.0/me/contactFolders/{id}` | One address book; `PATCH` changes `displayName` |
| `DELETE /graph/v1.0/me/contactFolders/{id}` | Deletes the address book and its contacts; `204` |
| `GET /graph/v1.0/me/contacts`, `/me/contactFolders/{id}/contacts` | The contacts of the default address book (the oldest one the user owns) or of one address book, sorted by display name, paged |
| `GET /graph/v1.0/me/contacts/{id}`, `/me/contactFolders/{id}/contacts/{id}` | One contact |
| `POST /graph/v1.0/me/contacts`, `/me/contactFolders/{id}/contacts` | Creates a contact from the fields in the contact mapping below; `201` |
| `PATCH /graph/v1.0/me/contacts/{id}` | Changes the fields in the body and leaves everything else of the stored card as it is |
| `DELETE /graph/v1.0/me/contacts/{id}` | Deletes the contact; `204` |

A contact folder has the id of its owner and its recipients, built like a calendar id. Besides
`id` and `displayName` it carries `groupware.isDefault`, `groupware.canEdit` (may change
contacts), `groupware.canShare` (owner only) and `groupware.owner.name`. A contact id is the folder
id, a dot and the URL-safe base64 form of the card's name in the address book. `@odata.etag`
carries the card's ETag as a weak validator, `parentFolderId` the folder id, and
`lastModifiedDateTime` the card's `REV`, or the time it was written.

Cards that stand for a group never show in a list, and asking for one by id answers `404`;
the facade does not write them. `If-Match` is honoured on `PATCH` and `DELETE` and answers `412`
with the code `preconditionFailed`. A `PATCH` that changes nothing does not write the card. A
user with read-only access to the address book, and anyone but the owner changing the folder
itself, gets `403`. Contacts made here show up for CardDAV clients at the next sync like any other
write. `$filter`, `delta` and child folders answer `501`.

### Contact photos

| Request | Answer |
|---|---|
| `GET /graph/v1.0/me/contacts/{id}/photo` | The photo's `@odata.mediaContentType`, `width` and `height`, or `404` without a photo |
| `GET /graph/v1.0/me/contacts/{id}/photo/$value` | The image itself with its content type, or `404` |
| `PUT /graph/v1.0/me/contacts/{id}/photo/$value` | Sets the photo from the request body; answers `200` with the photo's description |
| `DELETE /graph/v1.0/me/contacts/{id}/photo` | Removes the photo; `204`, or `404` without one |

The same paths exist below `/me/contactFolders/{id}/contacts/{id}`. The type of an upload is
taken from the image itself, not from `Content-Type`. Only JPEG and PNG are accepted (`415`
otherwise), the body may be at most 1 MB (`413`), and a body that claims to be an image but does
not decode is `400`. `If-Match` is honoured and a user with read-only access gets `403`. A photo
is stored in the card, as `PHOTO;ENCODING=b` in a vCard 3.0 card and as a `data:` URI in a vCard
4.0 card. A card whose photo is only a link has no photo here. A contact shows
`groupware.hasPhoto` so a client can skip the request.

#### Contact folder permissions

Address books are shared the same way, below `/graph/v1.0/me/contactFolders/{id}/permissions`
(`GET`, `POST`) and `.../permissions/{permissionId}` (`GET`, `PATCH`, `DELETE`). A permission
has the shape, the roles and the answers of a calendar permission. A contact folder shared
with the user shows in `/me/contactFolders` with `groupware.canEdit` set from the share, and its
contacts can be read, and written when the role is `write`.

### Contact mapping

Contacts are stored as vCard 3.0 or 4.0 and shown as Graph contacts. The mapping loses
some detail, and what it does not map is kept as it is: a change touches only the
fields it sends, and a field that already has the value sent is not rewritten. Cards
made through the API are vCard 3.0.

| Graph | vCard |
|---|---|
| `displayName`, `surname`, `givenName`, `middleName`, `title`, `generation` | `FN`, and the five parts of `N`: family, given, additional, prefix, suffix. A display name that was built from the name parts follows them when a part changes; a new contact without one gets the name parts, the first e-mail address or the company |
| `nickName`, `jobTitle`, `profession`, `personalNotes` | `NICKNAME`, `TITLE`, `ROLE`, `NOTE` |
| `companyName`, `department` | the first two parts of `ORG` |
| `yomiGivenName`, `yomiSurname`, `yomiCompany` | `X-PHONETIC-FIRST-NAME`, `X-PHONETIC-LAST-NAME`, `X-PHONETIC-ORG` |
| `emailAddresses` | `EMAIL`. `name` is the address; a name sent in a request is ignored |
| `mobilePhone`, `businessPhones`, `homePhones` | `TEL`. `TYPE=CELL` is the mobile phone (the first one), `WORK` a business phone, and `HOME`, an unknown type or a custom label a home phone. Fax, pager and video numbers are not shown. A `tel:` value is shown without the prefix |
| `homeAddress`, `businessAddress`, `otherAddress` | `ADR` by `TYPE`; an address without a type is the other address. Only the first one of each place is shown. The post office box and the extended address stay as they are |
| `businessHomePage` | the first `URL` |
| `imAddresses` | `IMPP` and `X-SOCIALPROFILE`. New entries are written as `IMPP` |
| `categories` | `CATEGORIES` |
| `birthday` | `BDAY`, as `YYYY-MM-DDT00:00:00Z`. A birthday without a year has the year `0001`; it is stored as `--MMDD` in vCard 4 and with `X-APPLE-OMIT-YEAR` in vCard 3. A time of day is dropped |
| `spouseName`, `children`, `assistantName`, `manager` | `X-ABRELATEDNAMES` with the label Spouse, Child, Assistant or Manager, `RELATED` with `TYPE=spouse` or `child` and a name, and the `X-SPOUSE`, `X-MANAGER`, `X-ASSISTANT` forms of other clients. A `RELATED` that points at a card by URI is not a name |
| `groupware.groups` | read only: the group cards (`KIND:group`, or Apple's `X-ADDRESSBOOKSERVER-KIND`) that list the contact as a member, each with the `id` (the UID of the group card) and a `displayName` |

Labels that Apple clients write in `X-ABLabel` (`_$!<Work>!$_`, `_$!<Mobile>!$_`, `_$!<Home>!$_` and
custom text) decide the place of a phone number or address that has no `TYPE`. When a change
removes a property, its label goes with it. `fileAs`, `initials`, `officeLocation`
and the other Graph fields are not mapped; a request that sends them leaves them out.


## Import and export

Two endpoint pairs move whole calendars and address books in and out as files. They sit
below `/groupware/v1/`, take the same OIDC bearer token as the Graph API, and use the
Graph id of the calendar or contact folder (the same one for its owner and for
everyone it is shared with). Errors have the Graph error body.

| Request | Answer |
|---|---|
| `POST /groupware/v1/calendars/{id}/import` | Reads an iCalendar file from the request body and stores its events |
| `GET /groupware/v1/calendars/{id}/export` | Downloads the calendar as one `.ics` file (`text/calendar`) |
| `POST /groupware/v1/addressbooks/{id}/import` | Reads a vCard file from the request body and stores its cards |
| `GET /groupware/v1/addressbooks/{id}/export` | Downloads the address book as one `.vcf` file (`text/vcard`) |

An import takes the file itself as the body, whatever its content type, up to 20 MB;
a larger body is `413`. Writing needs write access: a calendar or address book that is
shared read-only answers `403`, and an id that is not one of the user's answers `404`. Export
needs only read access. The export carries a `Content-Disposition` header with the
collection's name as file name.

An import holds the whole file in memory while it is parsed, so the service runs at most one
import per user and four at once. Another import answers `429` with `Retry-After: 5`; the
client can send the file again after that. Reads, exports and DAV requests are not limited
by this. The limits are fixed and not configurable.

The file is cut into objects: one event per UID in an iCalendar file, with a series and
its overrides together, and one card per `BEGIN:VCARD` block in a vCard file. Each object is
stored on its own, so a bad one never costs the file's good ones. An object whose UID the
collection already holds replaces that object under its existing name; any other object
is created, named after its UID. An event or card without a UID gets a new one. Time
zone definitions travel with the events that use them and a `METHOD` line is dropped.
Only `VEVENT` components are stored. A single object larger than 10 MB fails.

The answer is `200` with a report of every object, in file order:

```json
{
  "total": 3,
  "created": 2,
  "updated": 0,
  "failed": 1,
  "results": [
    {"index": 0, "uid": "ada", "name": "ada.vcf", "status": "created"},
    {"index": 1, "uid": "", "status": "failed", "error": "not a valid card: ..."},
    {"index": 2, "uid": "grace", "name": "grace.vcf", "status": "created"}
  ]
}
```

`status` is `created`, `updated` or `failed`. `name` is absent and `error` is set for a
failed object, and `uid` is empty when the object could not be read far enough to tell.
A file that cannot be cut into objects at all, such as an iCalendar file with unbalanced
`BEGIN` and `END` lines or a vCard file with text between cards, is `400` and nothing
is stored. A file without any object is `200` with `total` 0. Examples of both reports are
in `internal/graphapi/testdata/contract/import-report.json` and
`import-report-contacts.json`.

An export merges the stored objects into one file. A calendar export has the top-level
properties of the first event, each time zone once and every event in the order of the
object names. A stored object that does not parse is left out of the export. Importing
an export into an empty calendar or address book gives back the same UIDs.

## Account information

`GET /groupware/v1/me` tells the signed-in user their username and where their DAV
data lives, so a client can show the addresses to enter in a CalDAV or CardDAV app. It
takes the bearer token and answers:

```json
{
  "username": "einstein",
  "displayName": "Albert Einstein",
  "dav": {
    "url": "https://ocis.example/dav/",
    "calendarHomeUrl": "https://ocis.example/dav/calendars/einstein/",
    "addressBookHomeUrl": "https://ocis.example/dav/addressbooks/einstein/"
  },
  "username_conflict": false,
  "app_passwords_valid_until": "2026-12-05T10:00:00Z"
}
```

The addresses use the scheme and host of the request, taking the scheme from
`X-Forwarded-Proto` behind a proxy. `username` is the name a DAV client signs in with,
together with an app password. When another account holds the name (see "Usernames"),
`username` is empty, `username_conflict` is `true` and the two home addresses are empty;
`username_conflict` is `false` otherwise. `app_passwords_valid_until` is the end of
the identity lease (see "The identity lease"), or `null` when the lease is off. The same
body is in `internal/graphapi/testdata/contract/account.json`.

## Administration

The same binary administers a running service through the admin socket. It reads the
configuration the way the service does, so in the container it needs no arguments
beyond the command:

```sh
docker exec <container> /ocis-groupware admin principals list
docker exec <container> /ocis-groupware admin principals disable alice
docker exec <container> /ocis-groupware admin principals enable alice
docker exec <container> /ocis-groupware admin principals purge alice
docker exec <container> /ocis-groupware admin principals purge alice --yes
```

Outside the container, pass `--config <file>` or set `GROUPWARE_DATA_DIR` (or
`GROUPWARE_ADMIN_SOCKET`); `--socket <path>` names the socket directly. The command
exits with 1 and says so when the service is not running: it has no way to open the
data directory itself. `migrate classic` is the exception and needs the service stopped.

`list` prints one user per line with the username, display name, state, creation time,
identity age and sub. The identity age is the time since oCIS last confirmed the user, such
as `3d`, or `never`. With the identity lease on, a user at or past the lease shows `(stale)`:
their app passwords are refused until they sign in with a token again.

`--json` prints the admin API's answer as it is. A user without a username, because
another account holds it or because the holder took it over (see "Usernames"), shows `-`,
and `--sub <sub>` reaches it where a username is needed.

Every user also has an owner, the name the user's data is kept under. For someone who
signed in on their own it is the sub, and `list` leaves it out. A user can exist without a
sub, for example when their data was imported before their first sign-in. Then the owner
differs from the sub, `list` adds an OWNER column, and `--owner <owner>` reaches the user
wherever a username is needed.

`disable` refuses every sign-in of the user, with app passwords and with bearer tokens
alike, and takes effect at once. Nothing is deleted, and `enable` lets the user back in
with every device still paired. Both are safe to repeat.

`purge` deletes a disabled user's calendars, contacts and app passwords, the shares of
those collections, and the user's directory with them. Without `--yes` it only shows what would go and exits with 1:

```
would purge alice (sub 4c510ada-c86b-4815-8820-42cdf82c3d51): 2 calendars, 1 address book, 3 app passwords, 0 shares
add --yes to delete this data; it cannot be undone
```

A user that is not disabled is refused, so the account cannot collect new data while
you decide. Purging does not keep the user out: if the account still exists in oCIS and
signs in again, it gets a fresh, empty profile with default collections. To keep someone
out, use `disable`. `purge --owner <owner> --yes` also removes a user directory that lost
its `principal.json`, say after an interrupted purge; such a directory does not appear in
`list`. For a directory named after a sub, `--sub <sub>` does the same.

Every change is logged by the service at Info with the owner and username.

### Migrating from a classic installation

`admin migrate classic` copies calendars, address books, shares and app tokens from a
classic ownCloud database into the data directory. Unlike the commands above it opens the
data directory itself, so the service has to be stopped while it runs; it refuses to start
otherwise. It supports `--dry-run`, `--user <login>` for one user at a time and repeated
runs, and prints a report that lists public links and subscriptions as not migrated. See
[docs/classic-migrate.md](docs/classic-migrate.md) for the command and
[docs/migration.md](docs/migration.md) for the whole move: what to prepare, what does not
come along, what devices need, how to roll back and the ingress routes for the classic
addresses.

## Docker

```sh
task docker:build
task docker:run
```

## Kubernetes

`deploy/helm/ocis-groupware` is a Helm chart that runs one replica with the `Recreate`
strategy, because the service locks its data directory, on a persistent volume mounted at
`/data`. It takes the settings above as values and has an optional Ingress for the paths
in [docs/routing.md](docs/routing.md). See
[deploy/helm/ocis-groupware/README.md](deploy/helm/ocis-groupware/README.md) for the
values and the admin socket path limit.

```sh
helm install groupware deploy/helm/ocis-groupware \
  --set config.oidcIssuer=https://ocis.example.com \
  --set ingress.enabled=true --set ingress.host=ocis.example.com
```

## Local stack

`docker-compose.yml` runs oCIS and ocis-groupware behind one Traefik on the same
domain, which ocis-groupware requires. ocis-groupware's DAV, Graph, `/web/` and ops paths route
to ocis-groupware; everything else goes to oCIS. [docs/routing.md](docs/routing.md) lists
those paths and has the same routing for Traefik's file provider, nginx and Caddy under
`deploy/`.

```sh
task stack:up
```

Then open <https://ocis.localhost> (`admin` / `admin`). The application menu lists
"Calendar" and "Contacts", which oCIS Web loads from ocis-groupware because the stack
mounts `deploy/ocis/web.yaml` into the oCIS configuration directory. A `certs` service
generates a self-signed certificate on each start. Your browser will warn about it;
ocis-groupware trusts it through `GROUPWARE_OIDC_CA_FILE`.
Set `OCIS_DOMAIN`, `OCIS_VERSION` or `IDM_ADMIN_PASSWORD` in the environment
or a `.env` file to override the defaults. This stack is for development only.

### Classic test instance

`test/classic` holds a classic ownCloud 10 server with seeded calendars, contacts,
shares, a public link, subscriptions and app tokens, together with committed
MariaDB and PostgreSQL dumps of it. It uses its own compose project and ports, so it
runs next to the stack above. The dumps are what tests read; the compose file and the
seeding script regenerate them. See [test/classic/README.md](test/classic/README.md).

`internal/migrate/classic` reads such a database (MariaDB, MySQL or PostgreSQL) and its
tests load the dumps into real databases. The schema it assumes is in
[docs/classic-database.md](docs/classic-database.md).
`internal/migrate/idmap` maps the classic user and group ids it finds to oCIS ids, from CSV
files or the Graph API; see [docs/classic-user-mapping.md](docs/classic-user-mapping.md).
`internal/migrate` runs the migration; see [docs/classic-migrate.md](docs/classic-migrate.md).

### Stack tests

`test/stack` holds end-to-end tests that need the running stack. They sign in as the
demo users through the oCIS identity provider, create app passwords and run CalDAV and
CardDAV client flows against `https://ocis.localhost/dav`: discovery through the
well-known paths, calendars and address books with their objects, queries, sync, and
the refusal of requests without credentials. They also check that oCIS announces the
web application in its Web configuration and serves its entry. The Go tests use the
[go-webdav](https://github.com/emersion/go-webdav) client. One test runs the Python
caldav client check that ships with groupkit, which also exercises occurrence
expansion.

`web/tests/e2e` holds a browser test, run with Playwright and a headless Chromium,
that signs in to oCIS Web as a demo user, opens the application from the application
switcher and moves between its pages. CI runs it in the stack job after the Go tests,
on both routes. By hand, with the stack up: `task web:install`, then
`npx playwright install chromium` in `web/`, then `task web:e2e`; `STACK_URL` picks
another stack address.

`TestMigrateClassicInstance` moves the classic fixture into the stack and checks what
a user of the old server sees afterwards. It changes the stack's data and restarts the
service, so it runs only with `STACK_MIGRATE=true`, and needs the classic paths
(`STACK_COMPAT=true`, see [docs/routing.md](docs/routing.md)) and Docker access to the
stack's compose project. It starts a MariaDB from `test/classic/dumps/mariadb.sql` with
`test/stack/classic-db.yml`, creates the users `alice` and `bob` and the group `team` in
oCIS, stops the service, runs `admin migrate classic` in a one-off container on the data
volume, starts the service again and then plays a classic client: the classic URL, the
classic user name and an app token. What it covers and what it leaves out is described
in [docs/classic-migrate.md](docs/classic-migrate.md#what-the-stack-test-covers). CI runs
it after the other stack tests on the `ingress-compat` entry. By hand, with the stack
up with the classic paths:
`STACK_MIGRATE=true go test -tags stack -count=1 -run TestMigrateClassicInstance ./test/stack/`.
Run it once per stack: a second run finds the data of the first.

CI boots the stack with `OCIS_VERSION=8.2.2` and runs them on every pull request. The
tests are behind the `stack` build tag, so `task test` leaves them alone:

```sh
task stack:up
task stack:test
```

The tests take their settings from the environment. `STACK_URL` is the stack's address
(default `https://ocis.localhost`). `STACK_CA_FILE` is a PEM file with the stack's
certificate; without it the Go tests skip certificate verification, which the generated
development certificate needs. `STACK_PYTHON` names a Python interpreter with the
caldav client installed, which brings `requests`; the Python check runs only when it and
`STACK_CA_FILE` are set, and the plain Graph script (`test/stack/graph_script.py`) runs when
it is set:

```sh
docker compose cp traefik:/certs/cert.pem cert.pem
python3 -m venv .venv
.venv/bin/pip install --require-hashes \
  -r "$(go list -m -f '{{.Dir}}' github.com/LukasHirt/groupkit)/test/pyclient/requirements.txt"
STACK_CA_FILE=$PWD/cert.pem STACK_PYTHON=$PWD/.venv/bin/python task stack:test
```

The Go flows use `einstein` and remove what they create. The Python check uses `marie`
and expects her to have nothing but the default calendar, which is the case on a fresh
stack.

CI runs the tests a second time with the groupware paths routed through the proxy
inside oCIS instead of Traefik. `deploy/compose/ocis-proxy.yml` sets that up with the
routes in `deploy/ocis/proxy.yaml`, and `STACK_ROUTE=ocis-proxy` tells the tests which
route they are on. On that route the proxy keeps every REPORT request for itself, so
the CalDAV and CardDAV flows skip and `TestOCISProxyRoute` records what does and does
not get through. [docs/routing.md](docs/routing.md) explains why:

```sh
docker compose -f docker-compose.yml -f deploy/compose/ocis-proxy.yml up -d --build
STACK_ROUTE=ocis-proxy task stack:test
```

## Sizing

[docs/sizing.md](docs/sizing.md) lists the sizes the service was measured at (1,000
principals, calendars of up to 30,000 events, 200 polling clients), what a restart costs
and how to repeat the measurement with the load generator in `test/load`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please also read the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.

## Support

See [SUPPORT.md](SUPPORT.md) for where to get help.

## License

[Apache License 2.0](LICENSE).
