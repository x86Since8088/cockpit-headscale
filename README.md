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


## Install and deploy

There are **two** processes and they are not the same thing.

| | `install.sh` | `deploy.sh` |
|---|---|---|
| What it is | An in-place install **by symlink**, from wherever it is run | The real deployment: a copy, then config, then `install.sh` |
| Moves bytes? | **No.** It links; it never copies the payload | Yes. It is the only thing that copies |
| Where it runs from | The payload — dev checkout *or* install path | The dev checkout |
| Owns `.env`? | No. Reads it, refuses without it | Yes. Seeds it from `.envdefault`, **missing-only** |
| Owns units? | Renders and places. Never enables or starts | Enables and starts, behind `--with-policy` |

The one idea: **the script is the same; only where it is run from differs.**

### Deploy (the normal case)

```sh
sudo ./deploy.sh                      # -> /opt/cockpit-headscale
sudo ./deploy.sh --install-to /srv/x  # somewhere else
sudo ./deploy.sh --with-policy        # ...and enable the subnet-router reconciler
sudo ./deploy.sh --verify             # standing checks only, change nothing
sudo ./deploy.sh --uninstall          # remove links and units, keep the tree
sudo ./deploy.sh --remove             # remove the deployed tree too
```

That produces:

```
/opt/cockpit-headscale/payload -> payload-1.1.0/     bin/hs-admin, index.html, ...
/opt/cockpit-headscale/.env                          your settings   0644 root:root
/etc/cockpit-headscale/install.conf                  what install.sh did
/usr/share/cockpit/headscale/*  -> payload/*         per-file symlinks
/usr/local/sbin/{hs-admin,hs-policy} -> payload/bin/*
/etc/systemd/system/hs-policy-watch.service          rendered from systemd/*.in
```

**Unmount the share and all of that keeps working.** That is the acceptance
test, and `install.sh` asserts it after every deployed install: no symlink and
no unit may resolve into the dev tree. headscale itself is never touched — not
its binary, not its config, not its database, not its unit.

### Dev install (live editing)

Run the *same* `install.sh` from the checkout. The Cockpit page becomes symlinks
into the checkout, so editing `headscale.js` changes what the browser loads on
the next reload.

```sh
cp .envdefault .env         # TESTS ONLY, gitignored - see below
sudo ./install.sh
sudo ./install.sh --with-units    # only if you really want the unit rendered
sudo ./install.sh --uninstall
```

**`--user` is gone.** It installed into `~/.local/share/cockpit`, which cannot
hold a `/usr/local/sbin` helper — so the page it produced had no backend, which
is the same defect this version exists to fix, in a different disguise. A dev
install is now how you get live editing.

`DESTDIR=` still works, and stages every destination under one root, which is how
the whole flow is tested without touching a live host.

### Which install is this host running?

```sh
for d in /usr/share/cockpit/*/; do
    n=${d%/}; n=${n##*/}
    t=$(readlink -f "$d/index.html" 2>/dev/null) || continue
    case $t in
      */ai-orchestrator-storage/*) k="DEV  (share)";;
      /opt/*)                                    k="prod (/opt)";;
      "")                                        k="?? no index.html";;
      *)                                         k="OTHER";;
    esac
    printf '%-12s %s  %s\n' "$n" "$k" "$t"
done
```

> The snippet matches on `*/ai-orchestrator-storage/*` rather than the full
> share path, and this table says "retired checkout path" rather than spelling
> one. That is not squeamishness: `README.md` ships to the install path, and
> check 9 greps every shipped file for the dev root and for the retired
> `/opt/sc/...` prefix. The check is deliberately blunt - it cannot tell prose
> from a hardcoded path, and an exemption list for "files where it is only
> documentation" is a list that grows until the check means nothing. Rewording
> two lines is the cheaper half of that trade, and the wildcard match is better
> documentation anyway: it works wherever the share is mounted.


Or read `/etc/cockpit-headscale/install.conf`. Neither script ever restarts
`cockpit.socket`; Cockpit picks the package up on the next page load, and a hard
reload (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>R</kbd>) clears the browser's
cached manifest list.

### Windows

`deploy.ps1` and `deploy.bat` exist and **refuse, with an explanation**. This is
a Cockpit plugin and Cockpit is Linux-only, so there is no Windows payload here.
They exist rather than being absent because an absent `deploy.ps1` reads as an
oversight and the next person writes one. To enrol a Windows machine into the
tailnet, run `hs-admin client-config --os windows` on the control server.

---

## Configuration: `.envdefault` → `[install path]/.env`

**This project needs this more than any other in the tree.** headscale is
packaged by no distribution: there is no `/usr/bin/headscale` a package manager
put there and no canonical config path. Whoever installed it chose — a snap, a
tarball, a container — and that choice is not discoverable, only recorded.

`.envdefault` is committed and fully commented. `deploy.sh` copies it to
`[install path]/.env` **only when that file does not exist**. The keys that
matter:

| key | what it decides |
|---|---|
| `HEADSCALE_BIN` | the binary. Required; there is no distribution layout to fall back to |
| `HEADSCALE_CONFIG` | `config.yaml`. Must be passed explicitly on every call — the binary's compiled-in default does not exist under the snap |
| `HEADSCALE_UNIT` | the systemd unit, when it has a name nothing would guess |
| `HEADSCALE_SOCKET` | override only; empty means "read `unix_socket:` from the config", so there is one source of truth |
| `HS_POLICY_FILE`, `HS_ACL_POLICY_FILE` | the two policy files, seeded missing-only to the paths these keys name |
| `HS_POLICY_INTERVAL` | reconcile period, read by the unit and by `hs-policy` |

**The page does not read this file.** It asks `hs-admin status`, which does. A
page carrying its own candidate list would be a second copy of the same decision,
and the two would drift — which is exactly what the old `BIN_CANDIDATES` array
was. That array survives as a *fallback* for a host where `hs-admin` is not
installed, so a half-installed machine still renders a diagnosis naming the
missing file and the `.env` key instead of looking like headscale is absent.

**A `.env` in this checkout is TESTS ONLY and is gitignored.** A deployed helper
cannot read it: resolution is `$HS_ADMIN_ENV` (non-root only, owner-checked) →
`ENV_FILE=` from `/etc/cockpit-headscale/install.conf` → **fail, naming
install.conf**. There is no "look beside me" step, because that step would land
in the checkout on a dev install. Run `hs-admin status` as root with
`HS_ADMIN_ENV` set and it tells you it is ignoring it.

A deployed `.env` carries **locations and settings, never secrets**. Preauth keys
and API keys are minted by headscale, returned to the caller once, and written
nowhere.

---

## The helpers, and why each one ships

| helper | shipped? | why |
|---|---|---|
| `hs-admin` | **yes** | THE root entry point. Every headscale query needs root — the control socket sits in a `drwx------ root root` directory — so there is no unprivileged path that could substitute. It was installed on this host by hand and referenced **zero times** by this project's installer, so a fresh clone produced a page with nothing behind it. |
| `hs-policy` | **yes** | The subnet-router reconciler. Run by an operator (`hs-policy check`) and in a loop by `hs-policy-watch.service`. |

There is no `hs-policy-watch` executable: the unit runs `hs-policy` in a shell
loop so the interval is visible in the unit rather than hidden in a script. That
is a deliberate difference from `cockpit-wireguard`, whose watcher has real work
to do between ticks.

Not shipped: `check.sh`, `.git/`, any `.env`.

**The completeness gate.** `install.sh` carries one declaration (`PAGE`,
`HELPERS`, `LIBS`, `UNITS`, `SEEDS`, `REQUIRED_ENV`) that `deploy.sh` *sources*
rather than restates. Nine pre-flight checks refuse before anything is written;
check 3 greps the shipped page files for `/usr/local/sbin/<x>` literals and
refuses any hit `HELPERS` does not install. That is why `headscale.js` pins
`var HS_ADMIN = "/usr/local/sbin/hs-admin";` in one top-of-file constant — a path
assembled at runtime is invisible to that grep.

The manifest condition is `{"path-exists": "/usr/local/sbin/hs-admin"}`: a
Cockpit condition may test only paths this project's own `install.sh` creates,
because an unmet condition makes the plugin **silently absent**. Anything an
operator configures is checked at runtime and reported *in the page*.

---

## Conformance

Against `cockpit-secrets/source/docs/DEPLOY-CONTRACT.md`, checked 2026-09-07:

| | |
|---|---|
| Deploys to `/opt/<project>`, payload versioned, `.env` a sibling | yes |
| `install.sh` resolves itself with `readlink -f`; links, never copies | yes |
| Per-file symlinks into a real `/usr/share/cockpit/headscale` directory | yes |
| Refuses a `/usr/local/sbin` entry it does not own | yes |
| Writes `/etc/cockpit-headscale/install.conf` | yes |
| Renders units; never enables, starts or stops them | yes |
| Never touches `cockpit.socket` | yes |
| No `rm -r` outside `remove_old_payload`'s three assertions | yes |
| `--uninstall` removes only declared entries and names the data it kept | yes |
| `.envdefault` in the §4.1 grammar; helpers resolve `.env` via `install.conf` | yes |
| All nine pre-flight checks and the post-install assertion present | yes |
| No retired checkout path and no dev-root literal in any shipped file | yes |

Files installed as symlinks:

```
manifest.json   menu entry, keywords, Cockpit version requirement, condition
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

---

## Subnet-router policy and reconciler (`--with-policy`)

The Cockpit panel manages headscale's own object model. It does **not** touch
host networking, and deliberately so — but a headscale *subnet router* depends on
host state that neither headscale nor tailscaled will restore if it disappears.
These files cover that gap.

| File | Purpose |
|---|---|
| `etcdefaults/acl-policy.hujson` | ACL policy seed. `autoApprovers` is the declarative form of route approval. Seeded missing-only to the path `HS_ACL_POLICY_FILE` names. |
| `etcdefaults/routing-policy.json` | The host state a subnet router needs: forwarding sysctls, the advertised set, required chain ordering. Seeded missing-only to `HS_POLICY_FILE`. |
| `hs-policy` | `check` / `apply` / `status` reconciler. Reads its policy path from the deployed `.env`. |
| `systemd/hs-policy-watch.service.in` | Template. Rendered by `install.sh` to run `hs-policy apply` every `HS_POLICY_INTERVAL` seconds. |

Deploy with `sudo ./deploy.sh --with-policy`, which renders the unit **and**
enables it. `install.sh` alone renders it and stops there: enabling a daemon that
rewrites sysctls and firewall rules is a decision, not a side effect of
installing a web page.

Both seeds are **missing-only**. A re-install never overwrites an ACL policy —
that file decides which routes are auto-approved, and clobbering one would
silently change who can reach what.

### Why this is narrower than the WireGuard equivalent

`cockpit-wireguard` needs a full stored routing policy because WireGuard has no
concept of one — which subnets a client may reach exists only as iptables rules.
Headscale already owns that: route approval lives in its database, and
`autoApprovers` declares it. It also owns the forwarding and NAT rules, which
tailscaled programs into its own `ts-*` chains. **Do not write those rules here.**

What is left is genuinely unmanaged:

1. **Forwarding sysctls.** `tailscaled` warns once at `tailscale up` that
   forwarding is off, then carries on forever. Nothing re-asserts them. An exit
   node advertising `::/0` with IPv6 forwarding off fails *only* for IPv6, which
   presents as "some sites hang", not as an outage.
2. **The jump from `FORWARD` into `ts-forward`, and its order.** A podman,
   libvirt or docker restart strips the jump. The `ts-*` chains survive intact
   and are simply never reached — so the rules look perfectly correct while
   nothing routes. If `LIBVIRT_FWI` ends up ahead of `ts-forward`, the libvirt
   networks are REJECTed for tailnet clients while every other route keeps
   working. Verified on this host: deleting the jump breaks routing, and the
   watcher restores it within ~55s by restarting tailscaled.
3. **The advertised set.** `tailscale up` is **not additive** — a later bare
   `tailscale up` drops `--advertise-routes` and `--advertise-exit-node`, and the
   node stops serving while still reporting online.

### Two things it will not do

**It never calls `headscale nodes approve-routes`.** That command *replaces* a
node's entire approved set, so a reconciler could revoke routes it was never told
about. Approval belongs in `autoApprovers`, which is declarative and safe.

**It never runs `tailscale up` unattended.** An earlier version did, and it was a
genuine hazard: `tailscale up` is not additive and may need an auth key, so
running it automatically can log the node out — causing the outage the tool
exists to prevent. Worse, when tailscaled is mid-restart `tailscale debug prefs`
returns nothing, so *every* route reads as missing and the "repair" fires against
a healthy node. Route drift is now reported with the exact command to run by
hand, and an unavailable prefs read is reported as `unknown`, never as drift.
