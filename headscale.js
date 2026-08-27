/*
 * cockpit-headscale - a dependency-free Cockpit page for the headscale
 * control server.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Design notes
 * ------------
 * - No build step, no npm, no framework. Plain DOM built through el()/append(),
 *   which only ever uses textContent, so hostile node names cannot inject HTML.
 * - Every headscale call goes through run(), which uses cockpit.spawn with
 *   superuser:"try" and classifies failures instead of dumping raw stderr.
 * - Read-only by default. Nothing that changes state is issued without an
 *   explicit button press followed by a confirmation dialog.
 * - Pre-auth key secrets and API keys are NEVER rendered in full and never
 *   written to the console.
 *
 * Targets headscale 0.26.x. See README.md for how this differs from the
 * 2023-era upstream plugin.
 */

(function () {
    "use strict";

    var _ = cockpit.gettext;

    /* ------------------------------------------------------------------ *
     * Theme
     * ------------------------------------------------------------------ *
     *
     * Cockpit does NOT push its light/dark choice into plugin iframes. Pages
     * built with Cockpit's toolchain import pkg/lib/cockpit-dark-theme.js,
     * which resolves the choice locally and toggles .pf-v6-theme-dark on its
     * own <html>. base1/cockpit.js contains none of that, so a build-free
     * plugin has to do it itself. This mirrors Cockpit 360's own logic:
     *
     *   style = localStorage["shell:style"] || "auto"
     *   dark  = style === "dark" || (style === "auto" && OS prefers dark)
     *
     * The iframe is same-origin with the shell, so localStorage is shared and
     * a change made in the shell raises a "storage" event here. Reading the
     * preference rather than only prefers-color-scheme is what makes an
     * explicit "Light" choice on a dark-themed desktop behave correctly.
     */
    function applyTheme(style) {
        var root = document.documentElement;
        var chosen = style;
        if (!chosen) {
            try {
                chosen = localStorage.getItem("shell:style");
            } catch (e) {
                chosen = null; // storage can throw in restricted contexts
            }
        }
        chosen = chosen || "auto";

        var prefersDark = false;
        try {
            prefersDark = !!(window.matchMedia &&
                window.matchMedia("(prefers-color-scheme: dark)").matches);
        } catch (e) { /* ignore */ }

        var dark = (chosen === "dark") || (chosen === "auto" && prefersDark);

        // Tells the stylesheet that the preference has been resolved, so its
        // prefers-color-scheme fallback must stop applying.
        root.classList.add("hs-theme-managed");
        if (dark)
            root.classList.add("pf-v6-theme-dark");
        else
            root.classList.remove("pf-v6-theme-dark");
    }

    function initTheme() {
        applyTheme();
        window.addEventListener("storage", function (ev) {
            if (ev.key === "shell:style")
                applyTheme();
        });
        // Dispatched by the shell in the same document tree on an explicit change.
        window.addEventListener("cockpit-style", function (ev) {
            applyTheme(ev && ev.detail ? ev.detail.style : null);
        });
        try {
            var mq = window.matchMedia("(prefers-color-scheme: dark)");
            var onChange = function () { applyTheme(); };
            if (mq.addEventListener)
                mq.addEventListener("change", onChange);
            else if (mq.addListener)
                mq.addListener(onChange);
        } catch (e) { /* ignore */ }
    }

    initTheme();

    /* ------------------------------------------------------------------ *
     * Constants
     * ------------------------------------------------------------------ */

    // Snap first: on this class of host headscale is normally the Canonical
    // snap, whose shim lives in /snap/bin. Cockpit's bridge does not usually
    // have /snap/bin on PATH, so absolute paths are required.
    var BIN_CANDIDATES = [
        "/snap/bin/headscale",
        "/usr/bin/headscale",
        "/usr/local/bin/headscale",
        "/usr/sbin/headscale"
    ];

    // The Canonical snap names its service "headscaled", not "headscale".
    // Older/other packagings differ, so probe rather than assume.
    var UNIT_CANDIDATES = [
        "snap.headscale.headscaled.service",
        "snap.headscale.headscale.service",
        "headscale.service"
    ];

    var CONFIG_CANDIDATES = [
        "/var/snap/headscale/common/config.yaml",
        "/etc/headscale/config.yaml",
        "/var/lib/headscale/config.yaml"
    ];

    // Go's zero time.Time marshals to this in a protobuf Timestamp.
    var GO_ZERO_SECONDS = -62135596800;

    var TABS = [
        { id: "overview", label: "Overview" },
        { id: "users", label: "Users" },
        { id: "nodes", label: "Nodes" },
        { id: "preauth", label: "Pre-auth keys" },
        { id: "apikeys", label: "API keys" },
        { id: "routes", label: "Routes" }
    ];

    /* ------------------------------------------------------------------ *
     * State
     * ------------------------------------------------------------------ */

    var state = {
        booted: false,
        busy: false,
        tab: "overview",

        bin: null,          // resolved absolute path to the headscale binary
        binSearched: false,
        isSnap: false,
        version: null,      // best-effort version string
        versionNote: null,  // caveat about where the version came from

        unit: null,         // resolved systemd unit name
        service: null,      // { active, sub, load, enabled, result, since }
        journal: null,      // last few log lines, if readable

        configPath: null,
        socketPath: null,
        socketExists: null, // true / false / null (unknown)

        adminAllowed: null, // from cockpit.permission

        // data
        users: null,
        nodes: null,
        apikeys: null,
        preauth: null,      // flat array, each entry carries ._user

        // failure describing why data could not be read
        dataError: null,    // { kind, msg }
        partial: []         // non-fatal problems collected while loading
    };

    /* ------------------------------------------------------------------ *
     * DOM helpers
     * ------------------------------------------------------------------ */

    function append(node, kid) {
        if (kid === null || kid === undefined || kid === false || kid === true)
            return;
        if (Array.isArray(kid)) {
            for (var i = 0; i < kid.length; i++)
                append(node, kid[i]);
            return;
        }
        if (typeof kid === "object" && kid.nodeType)
            node.appendChild(kid);
        else
            node.appendChild(document.createTextNode(String(kid)));
    }

    function el(tag, attrs) {
        var node = document.createElement(tag);
        if (attrs) {
            for (var k in attrs) {
                var v = attrs[k];
                if (v === null || v === undefined || v === false)
                    continue;
                if (k === "class")
                    node.className = v;
                else if (k === "text")
                    node.textContent = v;
                else if (k.indexOf("on") === 0 && typeof v === "function")
                    node.addEventListener(k.slice(2), v);
                else
                    node.setAttribute(k, v === true ? "" : String(v));
            }
        }
        for (var i = 2; i < arguments.length; i++)
            append(node, arguments[i]);
        return node;
    }

    function clear(node) {
        while (node.firstChild)
            node.removeChild(node.firstChild);
    }

    /* ------------------------------------------------------------------ *
     * Formatting
     * ------------------------------------------------------------------ */

    // headscale emits protobuf Timestamps as { seconds, nanos }. Unset values
    // arrive as Go's zero time (year 1), which must render as "never" rather
    // than as a date in the year 1.
    function pbDate(t) {
        if (!t)
            return null;
        var s = Number(t.seconds);
        if (!isFinite(s) || s <= 0 || s === GO_ZERO_SECONDS)
            return null;
        return new Date(s * 1000);
    }

    function fmtAbs(d) {
        if (!d)
            return null;
        try {
            return d.toLocaleString();
        } catch (e) {
            return d.toISOString();
        }
    }

    function fmtRel(d) {
        if (!d)
            return null;
        var secs = Math.round((Date.now() - d.getTime()) / 1000);
        var future = secs < 0;
        var a = Math.abs(secs);
        var out;
        if (a < 45) out = "moments";
        else if (a < 90) out = "a minute";
        else if (a < 3600) out = Math.round(a / 60) + " minutes";
        else if (a < 5400) out = "an hour";
        else if (a < 86400) out = Math.round(a / 3600) + " hours";
        else if (a < 172800) out = "a day";
        else if (a < 2592000) out = Math.round(a / 86400) + " days";
        else if (a < 5184000) out = "a month";
        else if (a < 31536000) out = Math.round(a / 2592000) + " months";
        else out = Math.round(a / 31536000) + " years";
        return future ? ("in " + out) : (out + " ago");
    }

    // A timestamp cell: relative text with the absolute time in the tooltip.
    function timeCell(t, neverLabel) {
        var d = pbDate(t);
        if (!d)
            return el("span", { class: "hs-muted", text: neverLabel || "never" });
        return el("span", { title: fmtAbs(d) }, fmtRel(d));
    }

    /*
     * Credential hygiene: pre-auth key secrets are returned in full by
     * `headscale preauthkeys list -o json`. They are bearer credentials -- a
     * reusable one lets anyone join the tailnet. We show only a short prefix
     * so an operator can correlate a row with a key they already hold, and we
     * never place the full value in the DOM (not even in a title attribute,
     * which would land in the accessibility tree and in screenshots).
     */
    function maskSecret(secret, keep) {
        if (!secret)
            return el("span", { class: "hs-muted", text: "—" });
        keep = keep || 6;
        var shown = String(secret).slice(0, keep);
        var len = String(secret).length;
        return el("span", { class: "hs-mono" },
            shown,
            el("span", { class: "hs-muted", text: "…(" + len + " chars hidden)" }));
    }

    function pill(kind, label, nodot) {
        return el("span", { class: "hs-pill " + kind + (nodot ? " hs-nodot" : ""), text: label });
    }

    function plural(n, one, many) {
        return n === 1 ? one : many;
    }

    /* ------------------------------------------------------------------ *
     * Command execution
     * ------------------------------------------------------------------ */

    /*
     * All privileged reads go through here. superuser:"try" means Cockpit
     * escalates when it can and silently runs unprivileged when it cannot --
     * so a refusal surfaces either as a channel problem (access-denied,
     * authentication-failed, cancelled) or, more often, as headscale itself
     * failing to open its root-owned control socket. classify() folds both
     * shapes into one "privilege" verdict.
     */
    function run(argv, opts) {
        var options = { err: "message", superuser: "try" };
        if (opts) {
            for (var k in opts)
                options[k] = opts[k];
        }
        return cockpit.spawn(argv, options);
    }

    function classify(err) {
        var problem = err && err.problem ? String(err.problem) : "";
        var msg = "";
        if (err) {
            if (err.message)
                msg = String(err.message);
            else if (problem)
                msg = problem;
            else
                msg = String(err);
        }
        var low = msg.toLowerCase();

        if (problem === "access-denied" || problem === "authentication-failed" ||
            problem === "cancelled" || problem === "not-authorized")
            return { kind: "privilege", msg: msg, problem: problem };

        if (problem === "not-found")
            return { kind: "missing", msg: msg, problem: problem };

        // headscale's own socket diagnostics
        if (low.indexOf("permission denied") !== -1)
            return { kind: "privilege", msg: msg, problem: problem };

        // When the socket is absent but readable-in-principle, headscale does
        // not report ENOENT -- it blocks on the gRPC dial and eventually says
        // "Could not connect: context deadline exceeded". Observed on 0.26.1.
        if (low.indexOf("connection refused") !== -1 ||
            low.indexOf("no such file or directory") !== -1 ||
            low.indexOf("connect: no such file") !== -1 ||
            low.indexOf("could not connect") !== -1 ||
            low.indexOf("context deadline exceeded") !== -1)
            return { kind: "notrunning", msg: msg, problem: problem };

        if (low.indexOf("configuration key has been removed") !== -1 ||
            low.indexOf("failed to read config") !== -1 ||
            low.indexOf("error initializing") !== -1 ||
            low.indexOf("fatal") !== -1)
            return { kind: "config", msg: msg, problem: problem };

        return { kind: "other", msg: msg, problem: problem };
    }

    // headscale returns the JSON literal `null` (not `[]`) for an empty
    // collection. Normalise so callers can always treat the result as a list.
    function parseList(text) {
        var trimmed = (text || "").trim();
        if (!trimmed || trimmed === "null")
            return [];
        var parsed = JSON.parse(trimmed);
        if (parsed === null || parsed === undefined)
            return [];
        return Array.isArray(parsed) ? parsed : [parsed];
    }

    /* ------------------------------------------------------------------ *
     * Probes
     * ------------------------------------------------------------------ */

    function probeBinary() {
        // One shell round-trip instead of four channels.
        var script = 'for p in ' + BIN_CANDIDATES.join(" ") + '; do ' +
                     'if [ -x "$p" ]; then echo "$p"; exit 0; fi; done; ' +
                     'command -v headscale 2>/dev/null || true';
        return cockpit.spawn(["/bin/sh", "-c", script], { err: "message" })
            .then(function (out) {
                var path = (out || "").trim().split("\n")[0].trim();
                state.bin = path || null;
                state.isSnap = !!path && path.indexOf("/snap/") === 0;
                state.binSearched = true;
            })
            .catch(function () {
                state.bin = null;
                state.binSearched = true;
            });
    }

    function probeUnit() {
        // `systemctl show` on an unknown unit succeeds with LoadState=not-found,
        // so this is a safe, unprivileged way to identify the real unit name.
        var props = "Id,LoadState,ActiveState,SubState,UnitFileState,Result,ExecMainStatus,ActiveEnterTimestamp,InactiveEnterTimestamp,Description";
        var argv = ["systemctl", "show", "--no-pager", "--property=" + props];
        argv = argv.concat(UNIT_CANDIDATES);
        return cockpit.spawn(argv, { err: "message" })
            .then(function (out) {
                // Output is one blank-line-separated block per unit, in order.
                var blocks = String(out).split(/\n\s*\n/);
                var found = null;
                for (var i = 0; i < blocks.length; i++) {
                    var info = {};
                    blocks[i].split("\n").forEach(function (line) {
                        var eq = line.indexOf("=");
                        if (eq > 0)
                            info[line.slice(0, eq)] = line.slice(eq + 1);
                    });
                    if (!info.Id)
                        continue;
                    if (info.LoadState && info.LoadState !== "not-found") {
                        found = info;
                        break;
                    }
                }
                if (found) {
                    state.unit = found.Id;
                    state.service = {
                        id: found.Id,
                        load: found.LoadState,
                        active: found.ActiveState,
                        sub: found.SubState,
                        enabled: found.UnitFileState,
                        result: found.Result,
                        exitStatus: found.ExecMainStatus,
                        description: found.Description,
                        activeSince: found.ActiveEnterTimestamp,
                        inactiveSince: found.InactiveEnterTimestamp
                    };
                } else {
                    state.unit = null;
                    state.service = null;
                }
            })
            .catch(function (err) {
                state.service = null;
                state.partial.push({
                    what: "systemd unit lookup",
                    detail: classify(err).msg
                });
            });
    }

    function probeConfig() {
        var script = 'for p in ' + CONFIG_CANDIDATES.join(" ") + '; do ' +
                     'if [ -f "$p" ]; then echo "$p"; exit 0; fi; done';
        return cockpit.spawn(["/bin/sh", "-c", script], { err: "message" })
            .then(function (out) {
                state.configPath = (out || "").trim().split("\n")[0].trim() || null;
                if (!state.configPath)
                    return null;
                // The snap's config.yaml is world-readable, so this needs no
                // privilege. Used only to learn the control socket path.
                return cockpit.file(state.configPath).read()
                    .then(function (content) {
                        if (!content)
                            return;
                        var m = /^[ \t]*unix_socket:[ \t]*["']?([^"'\s#]+)/m.exec(content);
                        if (m)
                            state.socketPath = m[1];
                    })
                    .catch(function () { /* unreadable config is not fatal */ });
            })
            .catch(function () {
                state.configPath = null;
            });
    }

    function probeSocket() {
        if (!state.socketPath) {
            state.socketExists = null;
            return Promise.resolve();
        }
        // The snap keeps its socket in a 0700 root-owned directory, so this
        // check genuinely needs privilege; unknown is an acceptable answer.
        return run(["/bin/sh", "-c", '[ -S "' + state.socketPath + '" ] && echo yes || echo no'])
            .then(function (out) {
                state.socketExists = (out || "").trim() === "yes";
            })
            .catch(function () {
                state.socketExists = null;
            });
    }

    function probeVersion() {
        if (!state.bin)
            return Promise.resolve();
        return cockpit.spawn([state.bin, "version"], { err: "message" })
            .then(function (out) {
                var v = (out || "").trim().split("\n")[0].trim();
                state.version = v || null;
                // The Canonical snap builds headscale without stamping the
                // version, so `headscale version` reports "dev". The snap
                // metadata carries the real number.
                if (!v || v === "dev" || v.indexOf("dev") !== -1)
                    return snapVersion();
            })
            .catch(function (err) {
                var c = classify(err);
                state.version = null;
                state.partial.push({ what: "headscale version", detail: c.msg });
                return snapVersion();
            });
    }

    function snapVersion() {
        return cockpit.spawn(["/bin/sh", "-c",
            "snap list headscale 2>/dev/null | awk 'NR==2 {print $2\" (snap revision \"$3\")\"}'"],
            { err: "message" })
            .then(function (out) {
                var v = (out || "").trim();
                if (v) {
                    state.versionNote = state.version === "dev"
                        ? "`headscale version` reports \"dev\" because the snap is built without a version stamp; the number above comes from snap metadata."
                        : null;
                    state.version = v;
                }
            })
            .catch(function () { /* not a snap, keep what we have */ });
    }

    /* ------------------------------------------------------------------ *
     * Data loading
     * ------------------------------------------------------------------ */

    function hs(args) {
        return run([state.bin].concat(args));
    }

    function loadData() {
        state.dataError = null;
        state.users = null;
        state.nodes = null;
        state.apikeys = null;
        state.preauth = null;

        if (!state.bin) {
            state.dataError = { kind: "missing", msg: "The headscale binary was not found." };
            return Promise.resolve();
        }

        // Don't query a server we already know is down. headscale does not fail
        // fast on a missing socket -- it blocks on the gRPC dial for the full
        // deadline (~10s on 0.26.1) before giving up, which would leave the
        // page on its loading state for no information gained. The service
        // state was read without privilege and is authoritative here.
        if (state.service && state.service.active !== "active" &&
            state.service.active !== "activating") {
            state.dataError = {
                kind: "notrunning",
                msg: "",
                problem: ""
            };
            return Promise.resolve();
        }

        // Users first: it is the cheapest call and it is the probe that tells
        // us whether the control socket is reachable at all. Everything else
        // is only attempted once that succeeds.
        return hs(["users", "list", "-o", "json"])
            .then(function (out) {
                state.users = parseList(out);
                return Promise.all([loadNodes(), loadApiKeys()])
                    .then(loadPreauthKeys);
            })
            .catch(function (err) {
                state.dataError = classify(err);
            });
    }

    function loadNodes() {
        return hs(["nodes", "list", "-o", "json"])
            .then(function (out) { state.nodes = parseList(out); })
            .catch(function (err) {
                state.nodes = [];
                state.partial.push({ what: "nodes list", detail: classify(err).msg });
            });
    }

    function loadApiKeys() {
        return hs(["apikeys", "list", "-o", "json"])
            .then(function (out) { state.apikeys = parseList(out); })
            .catch(function (err) {
                state.apikeys = [];
                state.partial.push({ what: "apikeys list", detail: classify(err).msg });
            });
    }

    /*
     * There is no "list every pre-auth key" command in 0.26: `preauthkeys list`
     * requires -u <numeric user id>. So the full picture costs one call per
     * user, fanned out and stitched back together here.
     */
    function loadPreauthKeys() {
        var users = state.users || [];
        if (!users.length) {
            state.preauth = [];
            return Promise.resolve();
        }
        var all = [];
        return Promise.all(users.map(function (u) {
            return hs(["preauthkeys", "list", "-u", String(u.id), "-o", "json"])
                .then(function (out) {
                    parseList(out).forEach(function (k) {
                        k._user = (k.user && k.user.name) || u.name || String(u.id);
                        all.push(k);
                    });
                })
                .catch(function (err) {
                    state.partial.push({
                        what: "pre-auth keys for user " + (u.name || u.id),
                        detail: classify(err).msg
                    });
                });
        })).then(function () {
            all.sort(function (a, b) { return (b.id || 0) - (a.id || 0); });
            state.preauth = all;
        });
    }

    function loadJournal() {
        if (!state.unit)
            return Promise.resolve();
        return run(["journalctl", "-u", state.unit, "-n", "12", "--no-pager", "-o", "short-iso"])
            .then(function (out) {
                var txt = (out || "").trim();
                state.journal = txt || null;
            })
            .catch(function () {
                state.journal = null;
            });
    }

    /* ------------------------------------------------------------------ *
     * Refresh cycle
     * ------------------------------------------------------------------ */

    function refresh() {
        state.busy = true;
        state.partial = [];
        render();

        return probeBinary()
            .then(function () {
                return Promise.all([probeUnit(), probeConfig(), probeVersion()]);
            })
            .then(probeSocket)
            .then(loadData)
            .then(function () {
                // Only bother with the journal when something is wrong; it is
                // the single most useful thing to show in that case.
                var serviceBad = !state.service ||
                    state.service.active !== "active";
                if (serviceBad || state.dataError)
                    return loadJournal();
                state.journal = null;
            })
            .catch(function (err) {
                state.dataError = classify(err);
            })
            .then(function () {
                state.busy = false;
                state.booted = true;
                render();
            });
    }

    /* ------------------------------------------------------------------ *
     * Confirmation dialog
     * ------------------------------------------------------------------ */

    /*
     * Every state-changing operation funnels through here. There is no code
     * path in this plugin that mutates headscale without the operator having
     * read this dialog, seen the exact command, and pressed the confirm button.
     */
    function confirm(opts) {
        var root = document.getElementById("modal-root");
        clear(root);

        var busyNote = el("div", { class: "hs-inline-note" });
        var errBox = el("div");
        var confirmBtn;

        function close() {
            clear(root);
            document.removeEventListener("keydown", onKey);
        }

        function onKey(ev) {
            if (ev.key === "Escape")
                close();
        }

        function onConfirm() {
            confirmBtn.disabled = true;
            clear(busyNote);
            append(busyNote, [el("span", { class: "hs-spin" }), " ", "Running…"]);
            clear(errBox);
            opts.action()
                .then(function () {
                    close();
                    refresh();
                })
                .catch(function (err) {
                    var c = classify(err);
                    confirmBtn.disabled = false;
                    clear(busyNote);
                    clear(errBox);
                    append(errBox, el("div", { class: "hs-banner err" },
                        el("h2", { text: c.kind === "privilege"
                            ? "Administrative access required"
                            : "The command failed" }),
                        el("p", { text: c.kind === "privilege"
                            ? "This action needs administrative access and it was not granted, so nothing was changed."
                            : "Nothing was changed. headscale reported:" }),
                        c.msg ? el("pre", { class: "hs-pre", text: c.msg }) : null));
                });
        }

        confirmBtn = el("button", {
            class: "hs-btn primary" + (opts.danger ? " danger" : ""),
            onclick: onConfirm,
            text: opts.confirmLabel || "Confirm"
        });

        var dialog = el("div", { class: "hs-modal", role: "dialog", "aria-modal": "true" },
            el("div", { class: "hs-modal-head", text: opts.title }),
            el("div", { class: "hs-modal-body" },
                el("p", { text: opts.body }),
                opts.detail ? el("p", { class: "hs-muted", text: opts.detail }) : null,
                opts.command
                    ? el("div", null,
                        el("div", { class: "hs-inline-note", text: "Command to be run:" }),
                        el("pre", { class: "hs-pre", text: opts.command.join(" ") }))
                    : null,
                errBox,
                busyNote),
            el("div", { class: "hs-modal-foot" },
                el("button", { class: "hs-btn", onclick: close, text: "Cancel" }),
                confirmBtn));

        var backdrop = el("div", {
            class: "hs-modal-backdrop",
            onclick: function (ev) { if (ev.target === backdrop) close(); }
        }, dialog);

        root.appendChild(backdrop);
        document.addEventListener("keydown", onKey);
        confirmBtn.focus();
    }

    /* ------------------------------------------------------------------ *
     * Actions (all confirmed)
     * ------------------------------------------------------------------ */

    function serviceAction(verb) {
        if (!state.unit)
            return;
        var argv = ["systemctl", verb, state.unit];
        var human = { start: "Start", stop: "Stop", restart: "Restart" }[verb];
        confirm({
            title: human + " the headscale service",
            body: human + " " + state.unit + "?",
            detail: verb === "stop"
                ? "Connected tailnet clients will lose their control-plane connection. Existing peer-to-peer tunnels usually keep working until they need to renew."
                : "This affects the whole tailnet served by this host.",
            command: argv,
            danger: verb !== "start",
            confirmLabel: human,
            action: function () { return run(argv); }
        });
    }

    function approveRoutes(node, newRoutes, label, detail, danger) {
        // approve-routes REPLACES the approved set; an empty string clears it.
        var argv = [state.bin, "nodes", "approve-routes",
                    "-i", String(node.id),
                    "-r", newRoutes.join(",")];
        confirm({
            title: label,
            body: detail,
            detail: "headscale's approve-routes replaces the node's entire approved set, so the full resulting list is passed below.",
            command: argv,
            danger: !!danger,
            confirmLabel: danger ? "Revoke" : "Approve",
            action: function () { return run(argv); }
        });
    }

    function expirePreauthKey(key) {
        var argv = [state.bin, "preauthkeys", "expire",
                    "-u", String((key.user && key.user.id) || 0),
                    String(key.key)];
        confirm({
            title: "Expire pre-auth key",
            body: "Expire pre-auth key #" + key.id + " belonging to user " +
                  (key._user || "?") + "?",
            detail: "Once expired the key can no longer be used to join nodes to the tailnet. Nodes already registered with it are unaffected. This cannot be undone.",
            // Deliberately not passing `command:` -- the argv contains the key
            // secret, and the dialog renders the command verbatim.
            danger: true,
            confirmLabel: "Expire key",
            action: function () { return run(argv); }
        });
    }

    function expireApiKey(key) {
        var argv = [state.bin, "apikeys", "expire", "--prefix", String(key.prefix)];
        confirm({
            title: "Expire API key",
            body: "Expire API key with prefix " + key.prefix + "?",
            detail: "Any automation authenticating with this key will immediately start receiving authentication failures. This cannot be undone.",
            command: argv,
            danger: true,
            confirmLabel: "Expire key",
            action: function () { return run(argv); }
        });
    }

    function expireNode(node) {
        var argv = [state.bin, "nodes", "expire", "-i", String(node.id), "--force"];
        confirm({
            title: "Expire node",
            body: "Expire (log out) " + (node.given_name || node.name) + "?",
            detail: "The node is forced to re-authenticate before it can rejoin the tailnet. Its record and IP addresses are kept.",
            command: argv,
            danger: true,
            confirmLabel: "Expire node",
            action: function () { return run(argv); }
        });
    }

    function deleteNode(node) {
        var argv = [state.bin, "nodes", "delete", "-i", String(node.id), "--force"];
        confirm({
            title: "Delete node",
            body: "Permanently delete " + (node.given_name || node.name) + "?",
            detail: "The node record, its tailnet IP addresses and any approved routes are removed. The device must register again from scratch. This cannot be undone.",
            command: argv,
            danger: true,
            confirmLabel: "Delete node",
            action: function () { return run(argv); }
        });
    }

    /* ------------------------------------------------------------------ *
     * Rendering: header and diagnostics
     * ------------------------------------------------------------------ */

    function serviceState() {
        if (!state.service)
            return { kind: "unknown", label: "no service unit" };
        var s = state.service;
        if (s.active === "active")
            return { kind: "ok", label: "running" };
        if (s.active === "failed")
            return { kind: "err", label: "failed" + (s.result && s.result !== "success" ? " (" + s.result + ")" : "") };
        if (s.active === "activating")
            return { kind: "warn", label: "starting" };
        if (s.active === "deactivating")
            return { kind: "warn", label: "stopping" };
        return { kind: "idle", label: s.active || "inactive" };
    }

    function renderHeader() {
        var svc = serviceState();
        var svcPill = pill(svc.kind === "idle" ? "" : svc.kind, "Service: " + svc.label);

        var buttons = [];
        if (state.unit) {
            if (state.service && state.service.active === "active") {
                buttons.push(el("button", {
                    class: "hs-btn", onclick: function () { serviceAction("restart"); },
                    text: "Restart"
                }));
                buttons.push(el("button", {
                    class: "hs-btn danger", onclick: function () { serviceAction("stop"); },
                    text: "Stop"
                }));
            } else {
                buttons.push(el("button", {
                    class: "hs-btn primary", onclick: function () { serviceAction("start"); },
                    text: "Start"
                }));
            }
        }

        return el("div", { class: "hs-header" },
            el("h1", { text: "Headscale" }),
            state.version ? pill("info", state.version, true) : null,
            svcPill,
            el("div", { class: "hs-spacer" }),
            buttons,
            el("button", {
                class: "hs-btn", onclick: function () { refresh(); },
                disabled: state.busy, text: state.busy ? "Refreshing…" : "Refresh"
            }));
    }

    function checkItem(mark, label, value, note) {
        return el("li", null,
            el("span", { class: "hs-mark " + mark, text: mark === "ok" ? "✓" : (mark === "bad" ? "✗" : (mark === "warn" ? "!" : "?")) }),
            el("span", { class: "hs-label", text: label }),
            el("span", { class: "hs-value" },
                value,
                note ? el("div", { class: "hs-inline-note", text: note }) : null));
    }

    // The honest-degradation checklist. Each row states a fact we actually
    // verified, or says plainly that we could not verify it.
    function renderChecklist() {
        var items = [];

        items.push(state.bin
            ? checkItem("ok", "Binary", el("code", { class: "hs-code", text: state.bin }),
                state.isSnap ? "Provided by a snap package." : null)
            : checkItem("bad", "Binary", "not found",
                "Looked in " + BIN_CANDIDATES.join(", ") + " and on $PATH."));

        if (state.version)
            items.push(checkItem("ok", "Version", state.version, state.versionNote));

        if (state.unit) {
            var svc = serviceState();
            var mark = svc.kind === "ok" ? "ok" : (svc.kind === "err" ? "bad" : "warn");
            var note = null;
            if (state.service) {
                var bits = [];
                if (state.service.enabled)
                    bits.push("unit file " + state.service.enabled);
                if (state.service.sub && state.service.sub !== state.service.active)
                    bits.push("sub-state " + state.service.sub);
                if (state.service.exitStatus && state.service.exitStatus !== "0" &&
                    state.service.active !== "active")
                    bits.push("last exit status " + state.service.exitStatus);
                note = bits.length ? bits.join(", ") : null;
            }
            items.push(checkItem(mark, "Service unit",
                el("span", null,
                    el("code", { class: "hs-code", text: state.unit }), " — ", svc.label),
                note));
        } else {
            items.push(checkItem("bad", "Service unit", "none found",
                "Looked for " + UNIT_CANDIDATES.join(", ") + "."));
        }

        items.push(state.configPath
            ? checkItem("ok", "Configuration", el("code", { class: "hs-code", text: state.configPath }))
            : checkItem("bad", "Configuration", "not found",
                "Looked in " + CONFIG_CANDIDATES.join(", ") + "."));

        if (state.socketPath) {
            if (state.socketExists === true)
                items.push(checkItem("ok", "Control socket",
                    el("code", { class: "hs-code", text: state.socketPath })));
            else if (state.socketExists === false)
                items.push(checkItem("bad", "Control socket", "not present",
                    "Expected at " + state.socketPath + ". headscale creates it when the server starts."));
            else
                items.push(checkItem("unk", "Control socket",
                    el("code", { class: "hs-code", text: state.socketPath }),
                    "Could not check — the containing directory is root-only and administrative access was not available."));
        }

        items.push(state.adminAllowed === true
            ? checkItem("ok", "Administrative access", "granted for this session")
            : (state.adminAllowed === false
                ? checkItem("warn", "Administrative access", "not active",
                    "headscale's control socket is root-owned, so users, nodes and keys cannot be read without it. Use the “Administrative access” control in the Cockpit header to turn it on.")
                : checkItem("unk", "Administrative access", "unknown")));

        return el("ul", { class: "hs-check" }, items);
    }

    // The core "degrade honestly" surface. Chooses one accurate diagnosis
    // rather than showing a spinner forever or an unexplained error page.
    function renderDiagnosis() {
        var svcActive = state.service && state.service.active === "active";
        var kind, title, paragraphs = [];

        if (!state.bin) {
            kind = "err";
            title = "headscale is not installed on this host";
            paragraphs.push("No headscale executable was found. Install it (for example " +
                "with snap install headscale, or from the packages at github.com/juanfont/headscale/releases) and reload this page.");
        } else if (!state.unit) {
            kind = "warn";
            title = "headscale is installed, but there is no service to manage";
            paragraphs.push("The headscale binary is present, but none of the service units this page knows about exist, " +
                "so it cannot report or control the server's run state.");
        } else if (state.service && state.service.active === "failed") {
            kind = "err";
            title = "headscale is installed but the service has failed to start";
            paragraphs.push("The unit " + state.unit + " is in the failed state, so no control socket exists and no tailnet " +
                "data can be read. The most recent log lines are shown below and usually name the exact cause — a configuration " +
                "key the installed version no longer accepts, or a listening address already taken by another service, are the two common ones.");
        } else if (!svcActive) {
            kind = "warn";
            title = "headscale is installed but not running";
            paragraphs.push("Everything needed to run headscale is present, but the service is " +
                (state.service ? state.service.active : "not active") + ", so there is no control socket " +
                "and no users, nodes or keys can be listed.");
            paragraphs.push("Use the Start button above to start it. Check the configuration first if this host has never run headscale before.");
        } else if (state.dataError && state.dataError.kind === "privilege") {
            kind = "warn";
            title = "The service is running, but reading it needs administrative access";
            paragraphs.push("headscale's control socket is owned by root, and this session is not running with administrative " +
                "access, so users, nodes, pre-auth keys and routes cannot be listed. The service state shown above is accurate " +
                "and was read without privilege.");
            paragraphs.push("Turn on “Administrative access” in the Cockpit header, then press Refresh.");
        } else if (state.dataError && state.dataError.kind === "config") {
            kind = "err";
            title = "headscale rejected its configuration";
            paragraphs.push("The service is reachable but headscale reported a configuration problem. The exact message is below.");
        } else if (state.dataError) {
            kind = "err";
            title = "headscale could not be queried";
            paragraphs.push("The service appears to be running, but the command used to read it failed. The exact message is below.");
        } else {
            return null; // healthy: no diagnosis banner
        }

        var banner = el("div", { class: "hs-banner " + kind },
            el("h2", { text: title }),
            paragraphs.map(function (p) { return el("p", { text: p }); }),
            renderChecklist());

        // The privilege case is already fully explained in prose, and the
        // "missing" case is our own message, not headscale's -- attributing
        // either to headscale would be misleading.
        if (state.dataError && state.dataError.msg &&
            state.dataError.kind !== "privilege" &&
            state.dataError.kind !== "missing") {
            append(banner, el("div", null,
                el("div", { class: "hs-inline-note", text: "Reported by headscale:" }),
                el("pre", { class: "hs-pre", text: state.dataError.msg })));
        }

        if (state.journal) {
            append(banner, el("div", null,
                el("div", { class: "hs-inline-note", text: "Last log lines from " + state.unit + ":" }),
                el("pre", { class: "hs-pre", text: state.journal })));
        }

        return banner;
    }

    function renderPartialWarnings() {
        if (!state.partial.length)
            return null;
        var seen = {};
        var uniq = state.partial.filter(function (p) {
            var k = p.what + "|" + p.detail;
            if (seen[k]) return false;
            seen[k] = true;
            return true;
        });
        return el("div", { class: "hs-banner warn" },
            el("h2", { text: "Some information could not be read" }),
            el("p", { text: "The rest of this page is accurate; only these lookups failed." }),
            el("ul", null, uniq.map(function (p) {
                return el("li", null, el("strong", { text: p.what }), ": ", p.detail || "unknown error");
            })));
    }

    /* ------------------------------------------------------------------ *
     * Rendering: tables
     * ------------------------------------------------------------------ */

    function table(headers, rows, emptyMessage) {
        if (!rows || !rows.length)
            return el("div", { class: "hs-empty", text: emptyMessage });
        return el("div", { class: "hs-table-wrap" },
            el("table", { class: "hs-table" },
                el("thead", null, el("tr", null, headers.map(function (h) {
                    return el("th", { text: h });
                }))),
                el("tbody", null, rows)));
    }

    function card(title, subtitle, body, headExtra) {
        return el("div", { class: "hs-card" },
            el("div", { class: "hs-card-head" },
                el("div", null,
                    el("h2", { text: title }),
                    subtitle ? el("p", { class: "hs-sub", text: subtitle }) : null),
                el("div", { class: "hs-spacer" }),
                headExtra || null),
            el("div", { class: "hs-card-body hs-flush" }, body));
    }

    function renderUsers() {
        var users = state.users || [];
        var rows = users.map(function (u) {
            var keyCount = (state.preauth || []).filter(function (k) {
                return k.user && k.user.id === u.id;
            }).length;
            var nodeCount = (state.nodes || []).filter(function (n) {
                return n.user && n.user.id === u.id;
            }).length;
            return el("tr", null,
                el("td", { class: "hs-mono", text: String(u.id) }),
                el("td", null, el("strong", { text: u.name || "—" })),
                el("td", { text: u.display_name || "—" }),
                el("td", { text: u.email || "—" }),
                el("td", null, nodeCount + " " + plural(nodeCount, "node", "nodes")),
                el("td", null, keyCount + " " + plural(keyCount, "key", "keys")),
                el("td", null, timeCell(u.created_at)));
        });
        return card("Users", "Each user owns nodes and pre-auth keys. In headscale 0.26 the JSON field name is the login name; the display name and email are only populated for OIDC users.",
            table(["ID", "Name", "Display name", "Email", "Nodes", "Pre-auth keys", "Created"],
                rows, "No users exist yet. Create one with: headscale users create <name>"));
    }

    function nodeOnline(n) {
        // The proto omits `online` when false, so absence means offline.
        return n.online === true;
    }

    function renderNodes() {
        var nodes = state.nodes || [];
        var rows = nodes.map(function (n) {
            var online = nodeOnline(n);
            var expiry = pbDate(n.expiry);
            var expired = expiry && expiry.getTime() < Date.now();

            var statusCell = el("td", null,
                online ? pill("ok", "online") : pill("", "offline"),
                expired ? el("div", null, pill("err", "expired")) : null);

            var ips = (n.ip_addresses || []);
            var ipCell = el("td", null, el("div", { class: "hs-iplist" },
                ips.length
                    ? ips.map(function (ip) { return el("span", { class: "hs-mono", text: ip }); })
                    : el("span", { class: "hs-muted", text: "—" })));

            var routes = n.available_routes || [];
            var approved = n.approved_routes || [];
            var routeCell = el("td", null,
                routes.length
                    ? el("span", null, approved.length + " / " + routes.length + " approved")
                    : el("span", { class: "hs-muted", text: "—" }));

            var actions = el("td", { class: "hs-actions" },
                el("button", {
                    class: "hs-btn sm", onclick: function () { expireNode(n); },
                    text: "Expire"
                }), " ",
                el("button", {
                    class: "hs-btn sm danger", onclick: function () { deleteNode(n); },
                    text: "Delete"
                }));

            return el("tr", null,
                el("td", { class: "hs-mono", text: String(n.id) }),
                statusCell,
                el("td", null,
                    el("strong", { text: n.given_name || n.name || "—" }),
                    (n.name && n.given_name && n.name !== n.given_name)
                        ? el("div", { class: "hs-inline-note", text: n.name })
                        : null),
                el("td", null, (n.user && n.user.name)
                    ? el("span", { text: n.user.name })
                    : el("span", { class: "hs-muted", text: "—" })),
                ipCell,
                el("td", null, timeCell(n.last_seen, "never")),
                el("td", null, timeCell(n.expiry, "no expiry")),
                routeCell,
                actions);
        });

        return card("Nodes",
            "Devices registered with this control server. \"Online\" reflects an active connection to the control plane at the moment the list was read.",
            table(["ID", "Status", "Name", "User", "Tailnet IPs", "Last seen", "Expiry", "Routes", "Actions"],
                rows, "No nodes are registered. Nodes appear here after joining with a pre-auth key or an interactive login."));
    }

    function renderPreauth() {
        var keys = state.preauth || [];
        var rows = keys.map(function (k) {
            var expiry = pbDate(k.expiration);
            var expired = expiry && expiry.getTime() < Date.now();
            var used = k.used === true;
            var reusable = k.reusable === true;
            var ephemeral = k.ephemeral === true;

            var status;
            if (expired)
                status = pill("", "expired");
            else if (used && !reusable)
                status = pill("", "used");
            else
                status = pill("ok", "usable");

            var flags = el("td", null,
                reusable ? pill("info", "reusable", true) : pill("", "single use", true),
                ephemeral ? el("span", null, " ", pill("warn", "ephemeral", true)) : null,
                used ? el("span", null, " ", pill("", "has been used", true)) : null);

            return el("tr", null,
                el("td", { class: "hs-mono", text: String(k.id) }),
                el("td", null, status),
                el("td", null, k._user || "—"),
                el("td", null, maskSecret(k.key)),
                flags,
                el("td", null, timeCell(k.expiration, "no expiry")),
                el("td", null, timeCell(k.created_at)),
                el("td", { class: "hs-actions" },
                    expired ? null : el("button", {
                        class: "hs-btn sm danger",
                        onclick: function () { expirePreauthKey(k); },
                        text: "Expire"
                    })));
        });

        return card("Pre-auth keys",
            "Keys that let a device join the tailnet without an interactive login. Only a short prefix is shown — these are credentials, and headscale returns them in full over the CLI.",
            table(["ID", "Status", "User", "Key", "Flags", "Expires", "Created", "Actions"],
                rows, "No pre-auth keys exist. Create one with: headscale preauthkeys create --user <id> --expiration 24h"));
    }

    function renderApiKeys() {
        var keys = state.apikeys || [];
        var rows = keys.map(function (k) {
            var expiry = pbDate(k.expiration);
            var expired = expiry && expiry.getTime() < Date.now();
            var lastSeen = pbDate(k.last_seen);
            return el("tr", null,
                el("td", { class: "hs-mono", text: String(k.id) }),
                el("td", null, expired ? pill("", "expired") : pill("ok", "active")),
                el("td", null, el("span", { class: "hs-mono", text: k.prefix || "—" }),
                    el("span", { class: "hs-muted", text: " (prefix only)" })),
                el("td", null, timeCell(k.expiration, "no expiry")),
                el("td", null, lastSeen ? timeCell(k.last_seen) : el("span", { class: "hs-muted", text: "never used" })),
                el("td", null, timeCell(k.created_at)),
                el("td", { class: "hs-actions" },
                    expired ? null : el("button", {
                        class: "hs-btn sm danger",
                        onclick: function () { expireApiKey(k); },
                        text: "Expire"
                    })));
        });

        return card("API keys",
            "Keys for headscale's HTTP API. headscale only ever returns the prefix after creation — the secret itself is shown once, at creation time, and is not recoverable.",
            table(["ID", "Status", "Prefix", "Expires", "Last seen", "Created", "Actions"],
                rows, "No API keys exist. Create one with: headscale apikeys create --expiration 90d"));
    }

    /*
     * There is no `headscale routes` command in 0.26 -- the subcommand was
     * removed and routes now live on the node object. This view reconstructs
     * the advertised-vs-approved picture from nodes list.
     */
    function renderRoutes() {
        var nodes = state.nodes || [];
        var rows = [];

        nodes.forEach(function (n) {
            var available = n.available_routes || [];
            var approved = n.approved_routes || [];
            var serving = n.subnet_routes || [];

            // Union: a route can be approved but no longer advertised, which is
            // worth showing rather than hiding.
            var all = available.slice();
            approved.forEach(function (r) {
                if (all.indexOf(r) === -1)
                    all.push(r);
            });

            all.forEach(function (cidr) {
                var isAdvertised = available.indexOf(cidr) !== -1;
                var isApproved = approved.indexOf(cidr) !== -1;
                var isServing = serving.indexOf(cidr) !== -1;

                var next;
                var btn;
                if (isApproved) {
                    next = approved.filter(function (r) { return r !== cidr; });
                    btn = el("button", {
                        class: "hs-btn sm danger",
                        onclick: function () {
                            approveRoutes(n, next, "Revoke route approval",
                                "Stop routing " + cidr + " through " +
                                (n.given_name || n.name) + "?", true);
                        },
                        text: "Revoke"
                    });
                } else {
                    next = approved.concat([cidr]);
                    btn = el("button", {
                        class: "hs-btn sm",
                        onclick: function () {
                            approveRoutes(n, next, "Approve route",
                                "Allow " + (n.given_name || n.name) +
                                " to route traffic for " + cidr + "?", false);
                        },
                        text: "Approve"
                    });
                }

                rows.push(el("tr", null,
                    el("td", { class: "hs-mono" }, el("strong", { text: cidr })),
                    el("td", null,
                        el("span", { text: n.given_name || n.name || "—" }),
                        el("div", { class: "hs-inline-note", text: "node " + n.id })),
                    el("td", null, (n.user && n.user.name) || "—"),
                    el("td", null, isAdvertised
                        ? pill("info", "advertised")
                        : pill("warn", "no longer advertised")),
                    el("td", null, isApproved
                        ? pill("ok", "approved")
                        : pill("", "not approved")),
                    el("td", null, isServing
                        ? pill("ok", "serving")
                        : el("span", { class: "hs-muted", text: "—" })),
                    el("td", { class: "hs-actions" }, btn)));
            });
        });

        var note = el("div", { class: "hs-banner" },
            el("h2", { text: "About this view" }),
            el("p", { text: "headscale 0.26 removed the standalone routes command. Routes are now properties of a node: " +
                "available_routes is what the client advertises, approved_routes is what an administrator has allowed, and " +
                "subnet_routes is what the node is actually serving. This table joins those three lists." }),
            el("p", { text: "Approving or revoking rewrites the node's entire approved set, because that is how " +
                "headscale nodes approve-routes works — the confirmation dialog shows the exact resulting command." }));

        return el("div", null,
            note,
            card("Routes",
                "Subnet routes and exit nodes advertised by registered nodes.",
                table(["Prefix", "Node", "User", "Advertised", "Approved", "Serving", "Actions"],
                    rows, "No node is advertising any route. A client advertises routes with: tailscale up --advertise-routes=10.0.0.0/24")));
    }

    function renderOverview() {
        var svc = serviceState();
        var counts = el("div", { class: "hs-card-body" },
            el("dl", { class: "hs-dl" },
                el("dt", { text: "Users" }),
                el("dd", { text: state.users ? String(state.users.length) : "unknown" }),
                el("dt", { text: "Nodes" }),
                el("dd", null, state.nodes
                    ? (state.nodes.length + " (" +
                       state.nodes.filter(nodeOnline).length + " online)")
                    : "unknown"),
                el("dt", { text: "Pre-auth keys" }),
                el("dd", { text: state.preauth ? String(state.preauth.length) : "unknown" }),
                el("dt", { text: "API keys" }),
                el("dd", { text: state.apikeys ? String(state.apikeys.length) : "unknown" }),
                el("dt", { text: "Advertised routes" }),
                el("dd", { text: state.nodes
                    ? String(state.nodes.reduce(function (acc, n) {
                        return acc + ((n.available_routes || []).length);
                    }, 0))
                    : "unknown" })));

        return el("div", null,
            el("div", { class: "hs-card" },
                el("div", { class: "hs-card-head" },
                    el("div", null,
                        el("h2", { text: "Server" }),
                        el("p", { class: "hs-sub", text: "What this page verified about the headscale installation on this host." })),
                    el("div", { class: "hs-spacer" }),
                    pill(svc.kind === "idle" ? "" : svc.kind, svc.label)),
                el("div", { class: "hs-card-body" }, renderChecklist())),
            card("Tailnet", null, counts));
    }

    /* ------------------------------------------------------------------ *
     * Rendering: shell
     * ------------------------------------------------------------------ */

    function renderTabs() {
        var haveData = !state.dataError;
        var counts = {
            users: state.users ? state.users.length : null,
            nodes: state.nodes ? state.nodes.length : null,
            preauth: state.preauth ? state.preauth.length : null,
            apikeys: state.apikeys ? state.apikeys.length : null,
            routes: state.nodes
                ? state.nodes.reduce(function (acc, n) {
                    var a = (n.available_routes || []).slice();
                    (n.approved_routes || []).forEach(function (r) {
                        if (a.indexOf(r) === -1) a.push(r);
                    });
                    return acc + a.length;
                }, 0)
                : null
        };

        return el("div", { class: "hs-tabs", role: "tablist" },
            TABS.map(function (t) {
                var disabled = t.id !== "overview" && !haveData;
                var count = counts[t.id];
                return el("button", {
                    class: "hs-tab",
                    role: "tab",
                    "aria-selected": state.tab === t.id ? "true" : "false",
                    disabled: disabled,
                    title: disabled ? "Not available until headscale can be queried" : null,
                    onclick: function () {
                        state.tab = t.id;
                        render();
                    }
                }, t.label,
                    (!disabled && count !== null && count !== undefined)
                        ? el("span", { class: "hs-count", text: String(count) })
                        : null);
            }));
    }

    function renderBody() {
        if (state.dataError)
            return null; // the diagnosis banner is the whole story
        switch (state.tab) {
        case "users":    return renderUsers();
        case "nodes":    return renderNodes();
        case "preauth":  return renderPreauth();
        case "apikeys":  return renderApiKeys();
        case "routes":   return renderRoutes();
        default:         return renderOverview();
        }
    }

    function render() {
        var app = document.getElementById("app");
        clear(app);

        if (!state.booted) {
            append(app, el("div", { class: "hs-app" },
                el("div", { class: "hs-boot" },
                    el("span", { class: "hs-spin" }), " ",
                    "Checking the headscale installation on this host…")));
            return;
        }

        append(app, [
            renderHeader(),
            renderDiagnosis(),
            renderPartialWarnings(),
            renderTabs(),
            renderBody()
        ]);
    }

    /* ------------------------------------------------------------------ *
     * Boot
     * ------------------------------------------------------------------ */

    function init() {
        var app = document.getElementById("app");
        app.className = "hs-app";

        try {
            var perm = cockpit.permission({ admin: true });
            var onPermChange = function () {
                var was = state.adminAllowed;
                state.adminAllowed = perm.allowed;
                // Gaining admin access mid-session is the common fix for the
                // privilege path, so re-read automatically when it happens.
                if (state.booted && was === false && perm.allowed === true)
                    refresh();
                else if (state.booted)
                    render();
            };
            perm.addEventListener("changed", onPermChange);
            state.adminAllowed = perm.allowed;
        } catch (e) {
            state.adminAllowed = null;
        }

        render();
        refresh().then(function () {
            cockpit.transport.wait(function () { /* size the frame */ });
        });
    }

    if (document.readyState === "loading")
        document.addEventListener("DOMContentLoaded", init);
    else
        init();
}());
