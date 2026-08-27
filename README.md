# cockpit-headscale

A [Cockpit](https://cockpit-project.org/) page for the
[headscale](https://headscale.net/) control server.

It is deliberately **dependency-free**: plain HTML, vanilla JavaScript and CSS,
with no build step, no `npm`, no bundler and no framework. The only external
thing it loads is Cockpit's own `../base1/cockpit.js`. Copy four files into
`/usr/share/cockpit/headscale` and it works.

Written against **headscale 0.26.1**, installed as the Canonical snap.


## What it does

**Honest degradation first.** The single most common state of a fresh headscale
install is "present but not usable yet", so that is the state the page is built
around. It never shows a spinner forever and never shows a bare error page.
Instead it reports a checklist of what it actually verified:

| Row | What it means |
| --- | --- |
| Binary | which `headscale` executable was found, and whether it is a snap |
| Version | resolved version (see the note about `dev` below) |
| Service unit | the real unit name and its systemd state |
| Configuration | which config file is in use |
| Control socket | whether the gRPC socket exists, or that it could not be checked |
| Administrative access | whether this Cockpit session has it |

and picks one accurate diagnosis from: not installed / no service unit /
service failed / service not running / needs administrative access /
configuration rejected / query failed. When the service is not healthy it also
shows the last log lines from the unit, which usually name the exact cause.

**When headscale is running**, six tabs:

- **Overview** — the checklist plus tailnet counts.
- **Users** — id, name, display name, email, and how many nodes and pre-auth
  keys each user owns.
- **Nodes** — online/offline, name, owning user, all tailnet IPs (v4 and v6),
  last seen, expiry, and an approved/advertised route count.
- **Pre-auth keys** — status, user, masked key, reusable/single-use/ephemeral/used
  flags, expiry and creation time.
- **API keys** — status, prefix, expiry, last seen, creation time.
- **Routes** — every advertised prefix joined against what is approved and what
  is actually being served.

**Service control** — start / stop / restart `snap.headscale.headscaled.service`
through `cockpit.spawn` with `superuser: "try"`.


## Safety properties

These are design constraints, not incidental behaviour.

- **Read-only unless you say otherwise.** Opening any action dialog issues zero
  commands. Nothing mutates headscale without an explicit button press followed
  by a confirmation dialog that names the consequence. Most dialogs print the
  exact command that will run.
- **Key secrets are never rendered in full.** `headscale preauthkeys list -o json`
  returns the complete pre-auth secret — it is a bearer credential that lets any
  holder join the tailnet. The page shows only a 6-character prefix plus the
  length, and puts the full value nowhere in the DOM, not even in a `title`
  attribute. Nothing is logged to the console. The one dialog whose command
  line necessarily contains a key (`preauthkeys expire KEY`) deliberately does
  not print its command.
- **No HTML injection.** All DOM is built through helpers that only ever use
  `textContent`, so hostile node or user names cannot inject markup.
- **Privilege refusal is handled.** If administrative access is unavailable or
  declined, the page still shows everything readable without it (binary,
  version, unit state, config path) and says plainly which parts need privilege
  and why.


## Install

```sh
sudo ./install.sh                # -> /usr/share/cockpit/headscale
./install.sh --user              # -> ~/.local/share/cockpit/headscale
sudo ./install.sh --uninstall
DESTDIR=/tmp/stage ./install.sh  # stage for packaging
```

`install.sh` validates `manifest.json` before copying (a malformed manifest
makes Cockpit drop the package silently) and removes files left over from
previous versions. Cockpit picks the package up on the next page load;
restarting `cockpit.service` is not required, though a hard reload
(<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>R</kbd>) clears the browser's cached
manifest list.

Files installed:

```
manifest.json   menu entry, keywords, Cockpit version requirement
index.html      page shell
headscale.js    all logic
headscale.css   all styling, both themes
```


## Notes on this host's headscale (the snap)

The Canonical snap does not behave the way the upstream documentation assumes.

**Paths are under `/var/snap`, not `/etc/headscale`:**

| Thing | Path |
| --- | --- |
| Config | `/var/snap/headscale/common/config.yaml` |
| Control socket | `/var/snap/headscale/common/internal/headscale.sock` |
| SQLite database | `/var/snap/headscale/common/internal/db.sqlite` |
| Noise private key | `/var/snap/headscale/common/internal/noise_private.key` |

`headscale --help` still advertises `-c` defaulting to `/etc/headscale/config.yaml`,
but the snap's wrapper points it at the `/var/snap` copy, so you do not pass `-c`.

**The unit is `snap.headscale.headscaled.service`** — note the trailing `d`.
`snap info headscale` lists the app as `headscale.headscaled`. There is no
`snap.headscale.headscale.service`. The plugin probes for several unit names
rather than assuming one.

**`headscale version` prints `dev`.** The snap is built without a version stamp.
The real version comes from `snap list headscale`, which the plugin falls back
to, labelling the result so the discrepancy is not mysterious.

**The control socket is root-only.** `/var/snap/headscale/common/internal` is
mode `0700` owned by root, so every `headscale` subcommand needs administrative
access even though `unix_socket_permission` is `0770`.

**Two gotchas in the snap's shipped example config**, both of which stop the
service from starting:

1. It contains `oidc.strip_email_domain`, a key **removed in headscale 0.26**.
   The server exits immediately with
   `FATAL: The "oidc.strip_email_domain" configuration key has been removed.`
   Comment the key out.
2. `metrics_listen_addr` defaults to `127.0.0.1:9090` — **the port Cockpit
   itself listens on**. If Cockpit is running, headscale cannot bind it. Move
   headscale's metrics to another port (for example `127.0.0.1:9091`).

With those two edits `headscale configtest` passes and the service starts.

**The CLI does not fail fast when the server is down.** With the socket absent
but the caller privileged, `headscale users list` blocks on the gRPC dial for
the full deadline and then reports
`Could not connect: context deadline exceeded` — roughly ten seconds, not the
`ENOENT` you might expect. The plugin therefore reads the systemd unit state
first (which needs no privilege) and skips the query entirely when the service
is known to be down, so the page renders immediately instead of stalling.


## How this differs from the 2023 upstream

The reference implementation is `gbraad-cockpit/cockpit-headscale`, whose only
commit is from 2023-07-12 and which targets a headscale from before 0.23. It is
a TypeScript + React + PatternFly application built with webpack and 29 npm
dependencies. Beyond the toolchain, it is **wrong about the current CLI and data
model** in ways that matter:

| Area | 2023 upstream | headscale 0.26.1 |
| --- | --- | --- |
| Build | webpack + TypeScript + React + PatternFly | none — plain files |
| Scope | one table of nodes | users, nodes, pre-auth keys, API keys, routes, service control |
| `namespaces` | the concept the schema is built around | renamed **`users`** (old names kept only as aliases) |
| Routes | expected a top-level `routes` command | **removed**; routes are fields on the node object, managed via `nodes list-routes` and `nodes approve-routes` |
| Empty lists | `Object.values(nodes)` on the parsed JSON | headscale returns the literal **`null`**, not `[]`, which would throw — this plugin normalises it |
| `online` | typed as optional boolean and read directly | the field is **omitted entirely when false**, so absence means offline |
| Timestamps | `{seconds, nanos}` rendered as-is | unset times are Go's zero time (`seconds: -62135596800`) and must render as *never*, not as a date in year 1 |
| Node routes | absent from its type | `available_routes`, `approved_routes`, `subnet_routes` |
| Pre-auth keys | not shown | listable only **per user** (`-u <numeric id>`) — there is no list-all, so this plugin fans out one call per user |
| `manifest.json` | `tools` entry only, no keywords | `menu` entry with label, order and search keywords |
| Not-running state | renders `Loading...` forever | explicit diagnosis with a verified checklist |
| Credentials | n/a | pre-auth secrets masked everywhere |
| Errors | unhandled — `.done()` with no `.catch()` | classified into privilege / not-running / config / other |

Also worth knowing: **`preauthkeys list` returns the full key** in 0.26. Any UI
that renders the CLI's JSON naively will put working tailnet credentials on
screen.


## Theming

Cockpit does **not** push its light/dark choice into plugin iframes. Pages built
with Cockpit's toolchain import `pkg/lib/cockpit-dark-theme.js`, which resolves
the preference locally and toggles `.pf-v6-theme-dark` on its own `<html>`.
`base1/cockpit.js` contains none of that, so this plugin reimplements the same
logic in about 30 lines:

```
style = localStorage["shell:style"] || "auto"
dark  = style === "dark" || (style === "auto" && OS prefers dark)
```

listening for the `storage` event (the iframe is same-origin with the shell, so
a change in the shell propagates), the `cockpit-style` event, and
`prefers-color-scheme` changes.

Relying on `prefers-color-scheme` alone would be wrong: a user on a dark desktop
who explicitly picks **Light** in Cockpit would still get a dark plugin. The
stylesheet keeps a `prefers-color-scheme` fallback but disables it as soon as
the script has resolved the real preference.

All text meets WCAG AA contrast in both themes (measured worst case 4.97:1).


## Limitations

- **Read-mostly.** It exposes start/stop/restart, route approve/revoke, key
  expiry and node expire/delete. It does **not** create users, keys or nodes,
  rename or move nodes, manage tags, or edit ACL policy. Creating a pre-auth or
  API key would mean displaying a secret, which this page will not do.
- **No live updates.** Data is read once per load; use Refresh. There is no
  polling and no websocket.
- **Node "online" is a snapshot** from the moment the list was read.
- **No pagination.** Every node and key is rendered. Fine for tens or hundreds;
  a very large tailnet would want filtering.
- **`preauthkeys expire` passes the key on the command line**, because that is
  the only interface headscale offers. The value is never displayed, but on a
  multi-user host it is briefly visible in that process's `argv`.
- **Not translated.** Strings are wrapped for `cockpit.gettext` but no catalogue
  ships.
- **Tested against 0.26.1 only.** The 0.27 series is already in the snap store;
  the route and user commands are the ones most likely to shift again.
- The page does **not** declare a `conditions` block in `manifest.json`, so it
  appears in the Cockpit menu even when headscale is absent — deliberately, so
  it can explain that headscale is missing rather than silently vanishing.


## Licence

BSD-3-Clause, matching headscale and the upstream plugin.
