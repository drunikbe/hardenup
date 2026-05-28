# CLAUDE.md

Maintainer notes for this repo. User-facing docs are in `README.md`.

This file focuses on non-obvious edges — contract, state lifecycle, load-bearing safety pauses, ordering constraints, and pitfalls that aren't visible from the file tree. Skim the relevant section before touching a module.

---

## Wizard model

`main.sh` is a linear yes/no wizard. It walks `modules/NN-*.sh` in filename-sort order, and for each module:

1. Checks `STEP_<name>_COMPLETED` in state. If set (and `--redo <name>` wasn't passed), prints `✓ <name> [done at <ts>]` and continues.
2. `applies_<name>` — re-evaluated inline. If false, the step is invisible this run. `applies_` gates on state set by EARLIER modules (e.g. `STEP_rke2_SELECTED=yes` makes the 61–65 modules apply).
3. `detect_<name>` — reads canonical config files to populate prompt defaults.
4. `configure_<name>` — asks the operator's top-level Y/N + sub-questions. If Y/N is no, the module calls `state_mark_skipped <name>` and `configure_` returns; main.sh sees the flag and moves on.
5. `run_<name>` — executes immediately. Per-step safety pauses live here.
6. `verify_<name>` (or `check_<name>` as fallback) — reads canonical state to confirm the action persisted. If it fails, main.sh prints a clear error and exits non-zero WITHOUT marking the step completed. The operator fixes and re-runs; the wizard resumes at the failed step.
7. `state_mark_completed <name>` — records completion with an ISO timestamp.

There is no "configure-all-then-run-all" batch. Each step asks, executes, verifies, and moves on. Per-step safety pauses (SSH secondary-terminal confirm, etcd quorum warning, Proxy Protocol ordering) replace the old batch-summary confirmation.

### Module contract

Every `modules/NN-*.sh` defines:

| Function | Required? | Side effects | When main.sh calls it |
|----------|-----------|--------------|-----------------------|
| `applies_<name>` | yes | none (pure read) | Every iteration; filters the step out when it shouldn't run. |
| `detect_<name>` | yes (can be no-op) | reads canonical config; writes state | Before `configure_` each time the step is active. |
| `configure_<name>` | yes (can be no-op) | prompts + writes state | After `detect_`. Must call `state_mark_skipped` if the operator declines. |
| `check_<name>` | optional | reads canonical state | Not called by main.sh directly unless `verify_` is absent; used as the short-circuit check inside standalone-run scripts. |
| `verify_<name>` | optional (falls back to `check_`) | reads canonical state | After `run_`. Must return 0 or the step is NOT marked completed. |
| `run_<name>` | yes | writes canonical config files | After a non-skip `configure_`. Must be idempotent (`cat >` truncating writes, never `>>`). |

Each module also has a trailing `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` block so it runs standalone: `./modules/25-firewall.sh` does its own `require_root → state_init → detect → configure → run → verify` cycle independent of main.sh.

### Gotcha: function-name derivation

`mod_func_suffix` strips the numeric prefix and replaces `-` with `_`:

- `25-firewall` → `firewall`
- `22-ssh-keygen` → `ssh_keygen`
- `30-intrusion` → `intrusion`

If you rename a module, rename all five of its functions. Otherwise main.sh silently skips it — there's no "function not found" error because main.sh uses `declare -F` to check existence.

### Gotcha: `applies_` ordering

`applies_<name>` is evaluated inline every iteration, so it can consult state set by earlier modules (e.g. `STEP_rke2_SELECTED` set by 60-rke2-preflight's `configure_`). It CANNOT consult state set by the same module or any module with a HIGHER number — that state doesn't exist yet.

This is how the profile gating was eliminated: `40-runtime.sh` unconditionally applies and is the single fork in the road — the operator picks Podman / Docker / RKE2 (or none). Downstream modules gate on the resulting flags: `41-docker-firewall.sh` applies when `STEP_docker_SELECTED=yes`, `60-rke2-preflight` and `61-65` + `70-79` apply when `STEP_rke2_SELECTED=yes`. 40 flips both flags on the chosen path and unsets the other so a `--redo 40-runtime` that switches platforms doesn't leak stale state to modules on the abandoned path.

---

## State model

`/run/hardenup/state.env` (0600, tmpfs) holds everything for the duration of the run:

- Operator answers (hostname, user name, SSH key, ports, CIDRs).
- Generated secrets (RKE2 token, Grafana admin password, CrowdSec bouncer key, Rancher bootstrap password, SSH Ed25519 pubkey).
- Step flags: `STEP_<name>_SELECTED`, `STEP_<name>_COMPLETED`, `STEP_<name>_COMPLETED_AT`, `STEP_<name>_SKIPPED`, `STEP_<name>_SKIPPED_AT`.

### Gotcha: the state file is NOT trap-cleaned

The previous iteration of this repo had `trap state_cleanup EXIT` in main.sh. That's gone. The state file is deleted ONLY by the terminal `99-finalize.sh` step after a clean run — not by Ctrl+C, not by a failed step, not by `set -e` tripping. That's how resume works.

### Gotcha: secrets live in state.env during the run

State.env holds secrets while the wizard is running. The terminal `99-finalize.sh` prints them to stdout for the operator to copy, then wipes the file. There is no separate `/root/platform-credentials.txt` — this was intentionally removed. If the operator misses the stdout dump, the secrets are still retrievable from their canonical locations:

- RKE2 token: `/etc/rancher/rke2/config.yaml` (`token: "..."`)
- Grafana admin: `kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d`
- Rancher bootstrap: set in the Helm release; resettable via `kubectl -n cattle-system patch secret bootstrap-secret`.
- CrowdSec bouncer key: in the ingress-nginx ConfigMap / Lua init container env.
- SSH host key: `~/.ssh/id_ed25519.pub`.

Step 99's verify asserts that `/run/hardenup/` no longer exists. If deletion fails, the wizard exits non-zero with a loud message — secrets on tmpfs are still gone at reboot, but manual cleanup is safer.

### Gotcha: `/run` is tmpfs

`/run/hardenup/state.env` disappears on reboot. If the operator expects to interrupt the wizard and continue across a full machine reboot, they have to re-walk completed steps. Acceptable tradeoff — tmpfs is the right home for mid-run secrets.

---

## Load-bearing safety checks — DO NOT REMOVE

These pauses and rollbacks exist because specific real-world incidents would otherwise be unrecoverable without console access. Preserve them when editing.

### `24-ssh-harden`: secondary-terminal confirm

After writing `/etc/ssh/sshd_config.d/99-hardening.conf` and reloading sshd, the module pauses: *"Have you verified SSH access in another terminal?"* On `n`, it removes the drop-in file and reloads sshd before exiting. Removing this turns any sshd_config mistake (wrong port, broken PAM stack, typo'd key) into a permanent lockout on a remote box.

### `25-firewall`: UFW rule ordering

The run function: `ufw --force reset` → `default deny incoming` → **add SSH rule** → allow-all on private → `ufw --force enable`. Reordering to enable UFW before the SSH allow rule locks the operator out mid-script.

### `25-firewall`: SSH scope `vpn_only` is console-recovery-only

When `SSH_SCOPE=vpn_only`, the wizard blocks SSH on the public interface AND inserts a targeted deny for the SSH port on the private interface (the private allow-all still covers non-SSH traffic). The only path in is `VPN_IFACE` (tailscale0 or wg*). If the VPN daemon crashes, the Tailscale account is locked out, the WireGuard peer config is wrong, or the coordination server is unreachable, recovery requires console/serial access from the hosting provider. The configure-time info lines warn about this and name providers that do/don't offer console (Hetzner: yes; verify others). Do not default this scope — it must be an explicit opt-in.

### `18-vpn`: WireGuard one-way egress block

When an operator picks WireGuard and answers `y` to the one-way prompt (default), the module injects `PostUp`/`PreDown` iptables rules into the `[Interface]` section of the pasted config:

```
PostUp  = iptables -A OUTPUT -o <iface> -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp  = iptables -A OUTPUT -o <iface> -j DROP
```

Semantics: peer-initiated connections to the server work (inbound creates a conntrack entry; responses match ESTABLISHED); server-initiated connections to the peer are dropped. Matches the "home router NAT" model — the UniFi case the feature was designed for. Side effects: DNS-over-tunnel stops working in this mode (if the pasted config sets `DNS = 192.168.1.1`, the VPS can't reach it). If an operator later installs a monitoring agent or similar that needs outbound tunnel access, they must re-run `--redo 18-vpn` and answer `n` to the one-way prompt, OR whitelist the specific destination via a narrower PostUp rule.

### `40-runtime` / `41-docker-firewall`: Docker bypasses UFW

Docker's daemon inserts its own rules into `iptables FORWARD` that run BEFORE UFW's rules, so bound container ports become reachable from the public internet even when UFW default-deny is set. 41 fixes this by installing explicit rules in the `DOCKER-USER` chain: allow from `NET_PRIVATE_CIDR`, then default-drop. If 41 is skipped, any `docker run -p 80:80` exposes the container publicly regardless of UFW state. Do not let anyone "simplify" this module away.

### `63-rke2-service`: etcd quorum

Joining a second server while the first isn't `Ready` yet can split-brain the etcd Raft group. 61-rke2-config displays the quorum warning at configure time; the operator MUST wait between server joins. Workers are fine in parallel (no etcd membership change).

### `72-ingress-nginx`: Proxy Protocol ordering

The chart deploys nginx with `use-proxy-protocol: "true"`. After it's up, 72 pauses with: *"Enable Proxy Protocol on LB ports 80/443 — DO NOT enable it on port 6443."* If you enable PP on the LB before nginx is ready, clients get 400s. If you enable it on 6443, kubectl stops working (it doesn't speak PP).

### `65-rke2-post`: Calico WireGuard is post-install only

For Calico + WireGuard, 64-rke2-wireguard does NOT write a pre-install HelmChartConfig (Calico has no such manifest for WG). Instead, 65 drops `/usr/local/bin/rke2-enable-wireguard` and tells the operator to run it **after all nodes have joined**. Enabling Calico WG before all nodes have the WG kernel module breaks pod connectivity on the stragglers.

---

## Ordering and gating constraints

- **Execution order is filename-glob sort.** Don't rename existing modules; gaps in numbering (11–14, 16–17, 42–49, 54–58, 67–69, 80–98) are intentional reserve slots for insertions.
- **`10` is free since the PROFILE module was deleted.** Available for a future always-first module if needed.
- **`15-networks` runs before any network-aware module.** 25-firewall, 30-intrusion, 41-docker-firewall, 61-rke2-config, 72-ingress-nginx all consult `NET_PUBLIC_*` / `NET_PRIVATE_*`.
- **`18-vpn` runs before 24-ssh-harden and 25-firewall on purpose.** Installing a VPN early lets those modules offer VPN-aware options conditional on `VPN_ENABLED=yes` / `VPN_KIND`: 24 may enable Tailscale SSH (ONLY when `VPN_KIND=tailscale` — WireGuard has no equivalent since it's a protocol, not an identity system), and 25 exposes the SSH scope selector (anywhere / no_public / vpn_only). Operators who decline a VPN at 18 see neither sub-prompt. 25-firewall writes the `allow in on ${VPN_IFACE}` rule itself so the `ufw --force reset` doesn't clobber it — VPN trust is co-located with the rest of the UFW state. State schema: `VPN_KIND` ∈ {none, tailscale, wireguard}, `VPN_IFACE` ∈ {"", tailscale0, wg0 or operator-chosen}; `VPN_ENABLED` is a convenience flag. The old `TAILSCALE_ENABLED` key is auto-migrated at detect time for re-runs against existing state.
- **`30-intrusion` asks its y/n AND picks fail2ban vs crowdsec in a single step.** Replaces the former three-file split (30-security-choice + 31-fail2ban + 32-crowdsec-host) — one module = one wizard step.
- **`40-runtime` is where the "Install Kubernetes?" decision lives** (alongside Podman / Docker / none as mutually-exclusive siblings). Picking RKE2 sets `STEP_rke2_SELECTED=yes`; modules 60-65 and 70-79 all gate on that flag. `60-rke2-preflight` is the confirm+preflight step, not the decision point — its `applies_` returns false when RKE2 wasn't chosen, so an operator who picked Podman/Docker at 40 never sees any RKE2-related prompt. The audit-rule setup that used to live in 59-audit is now inlined into `run_rke2_config` (61) — kept with RKE2 because that's where it's meaningful.
- **`62-rke2-install` writes `/etc/sysctl.d/99-rke2.conf`.** This is where `ip_forward=1`, bridge-nf-call, inotify limits, and the `rp_filter=0` CNI carve-out happen. 26-sysctl is runtime-agnostic and writes only the baseline; 41-docker-firewall handles the Docker equivalent.
- **70–79 gate on `STEP_rke2_service_COMPLETED=yes`.** This means the wizard won't offer to install Helm/ingress-nginx/etc. until RKE2 is up and kubectl works. To deploy the platform stack after the initial run, re-invoke `sudo ./main.sh` — completed steps show as `✓ [done]` and the wizard resumes at the platform modules.

---

## Conventions

- **Idempotent by overwrite.** Every module that writes a config file uses `cat > file <<EOF` (truncating write), never `>>` (append). Re-running produces identical end state.
- **One responsibility per module.** If you're adding two unrelated things to a module, split it. Numbering has reserve slots specifically for insertion.
- **Shared helpers live in `lib.sh`.** Don't reinvent `ask_*`, `validate_*`, `detect_*`, `wait_for`, `require_root`, `ensure_tmux` in modules. Add to `lib.sh` if a pattern reappears.
- **Inline rationale, not WHAT.** Module headers explain WHY a config choice exists (load-bearing reasons, incident history, upstream-bug references). Don't repeat what the next five lines of bash obviously do.
- **Standalone-run scripts should also verify.** Each module's trailing `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` block should call `verify_<name>` (or `check_<name>`) after `run_` and exit non-zero if it fails. Copy the pattern from 25-firewall.
- **Prompt labels explain the input format.** New `ask_input` calls should include a format/example hint in parentheses when the expected input isn't obvious from the label alone (good: `"Server URL (e.g. https://host:6443)"`, bad: bare `"Hostname"`). A bare label is acceptable only when the `[default]` value itself communicates the type. Same rule applies to `ask_yesno` for module-level "install X?" prompts — name the tool or stack in parentheses when the label doesn't already (good: `"Enable host-level intrusion detection (fail2ban/crowdsec)?"`, bad: bare `"Enable host-level intrusion detection?"`). This is soft-enforced via review — no CI check yet.
- **Sub-prompts explain the concept when the label can't.** When a sub-prompt asks for something whose *purpose* isn't obvious from the label alone (e.g. `"Private CIDR (for allow-lists)"`, `"Load balancer private IP"`, `"Email address for Let's Encrypt"`), precede it with 1-4 `info` lines explaining what the value is used for downstream and any non-obvious gotchas (platform-specific defaults, rate limits, jargon unpacked). Skip when the label and default already answer "what do I type and why does it matter?" (e.g. `"Hostname (short name or FQDN) [dev-apps]"` is self-explanatory). Don't duplicate the top-of-module `info` lines — those explain the step; these explain the specific field.
- **Every module must ask permission.** `configure_<name>` is where this happens. The shape is non-negotiable, applied uniformly across all 39+ modules:

  1. One to two `info "..."` lines describing what the step does and how it relates to neighbouring steps.
  2. An `ask_yesno "<prompt with tool/stack named in parens>?" "<default>"` gate.
  3. On decline: `state_mark_skipped <name>` then `return 0`.
  4. On accept: the module's sub-questions and state writes follow.

  Reject the temptation to make any step "silent because the default is obviously correct". The principle is *visibility over brevity*: operators should never discover, mid-wizard, that a step has already committed a change they didn't see. Modules that represent "the operator already consented upstream" (e.g. `41-docker-firewall` after picking Docker at 40, `51/52/53-webserver-*` after picking at 50, `61-65` after RKE2 yes at 60) still get the same info + y/n, just with default=`y` — the prompt exists for visibility, not to add friction.

  Example (`25-firewall.sh:34-39`):
  ```bash
  configure_firewall() {
      info "Host packet filter: default-deny incoming, allow SSH + selected ports."
      info "Complements (not replaces) intrusion detection in the next step."
      if ! ask_yesno "Configure host firewall (ufw)?" "y"; then
          state_mark_skipped firewall
          return 0
      fi
      # sub-questions here
  }
  ```

  Audit command:
  ```bash
  for f in modules/*.sh; do
      name=$(basename "$f" .sh); sfx=${name#*-}; sfx=${sfx//-/_}
      body=$(awk "/^configure_${sfx}\(\) \{/,/^}/" "$f")
      info_n=$(echo "$body" | grep -c '^\s*info ')
      yn=$(echo "$body"   | grep -c 'ask_yesno')
      [[ "$info_n" -ge 1 && "$yn" -ge 1 ]] || echo "FAIL $name (info=$info_n yesno=$yn)"
  done
  ```

  A passing run prints nothing. A failing module is blocked from merge until the convention is applied.

## Validation commands

**Run these locally before committing any shell-file change.** `.github/workflows/lint.yml` runs the same two checks on every push and PR to `main`; a red CI run blocks the merge. Catching lint failures locally is cheaper than pushing and waiting for CI.

```bash
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 bash -n
shellcheck -x -S style main.sh lib.sh state.sh modules/*.sh
grep -rn 'PROFILE' main.sh lib.sh state.sh modules/ README.md CLAUDE.md   # should be zero hits
```

Notes on the flags:

- `bash -n` is a pure parse pass — catches unclosed quotes, missing `fi`/`done`, malformed heredocs. No side effects.
- `shellcheck -x` follows `source` directives, but each module uses `# shellcheck source=/dev/null` because they source `lib.sh` via a computed variable path (`${MODULE_DIR}/../lib.sh`) that shellcheck can't statically resolve. That's why all four files (`main.sh`, `lib.sh`, `state.sh`, `modules/*.sh`) are passed explicitly — each gets analyzed independently. Don't try to "fix" the `/dev/null` directive with `source-path=SCRIPTDIR`; it breaks when shellcheck is invoked with a changed CWD.
- `-S style` is the strictest default severity. The repo is clean at this level today and CI enforces it. Don't suppress warnings to manufacture a green run — fix the underlying issue.

If you introduced a change that cannot pass lint (e.g. an intentional style exception), add a scoped `# shellcheck disable=SC####` with a one-line comment explaining why. Wholesale suppression (`--exclude=...` in the workflow, wrapping in `|| true`) is not acceptable.

## Git

- **Only commit when asked.** If unclear, ask.
- **Conventional commits.** `feat:` / `fix:` / `chore:` / `refactor:` / `docs:` prefixes. Imperative mood, one blank line after the subject.
- **Never `--amend` after a pre-commit hook fails.** The commit didn't happen; fix the issue, re-stage, make a new commit.
- **Never force-push main.** Warn the user if they ask.
- **Don't stage unrelated files.** Check `git status` before `git add -A`.

## Verification discipline

Report outcomes faithfully. If shellcheck fails, say so with the output — do not suppress warnings to manufacture a green run. If you didn't run a target VM and can't confirm runtime behavior, say that — don't imply it "worked" based on static checks alone. Static checks validate code correctness, not feature correctness.

## File & function size

- Files: aim under 500 LOC. Split anything over 800.
- Functions: aim under 100 LOC. Refactor before modifying anything over 200.
- Optimize for cohesion (one responsibility per file) and readability over compactness.

## Large-file reads

When reading files over 500 lines, use `offset` and `limit` with the `Read` tool. A single read of a 1000-line file may truncate.

## Search completeness

When renaming a function / variable / type, search for: direct calls, string literals, re-exports, barrel files, test mocks. A single grep is insufficient.
