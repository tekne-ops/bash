# tekne/bash

Bash utilities for the [tekne](https://github.com/fiercebrake) home/lab stack on Arch Linux. This repo holds day-to-day commands (`bin/`), infrastructure maintenance scripts (`scripts/`), and shared libraries (`lib/`). It sits alongside the tekne Ansible playbooks and powers local package builds, desktop workflows, VM provisioning, and backups.

---

## What this repo does

| Area | Purpose |
|------|---------|
| **Pacman repository** | Build AUR and Frogging-Family packages (linux-tkg, nvidia-all, wine-tkg-git, browsers, firmware, etc.) and publish them to a local repo (`themis` / `tekne`) |
| **System maintenance** | One-shot system updates with fallback when the tekne repo is unavailable |
| **Desktop workflow** | XFCE session launcher, X11 window tiling layouts, and a dedicated game session |
| **Git automation** | Bulk status/pull/push across tekne git repos |
| **Lab infrastructure** | Scripts to provision Kubernetes VMs, customize arch-boxes images, run Arch build containers, and back up `/srv` with restic |

---

## Quick start

Install user-facing commands onto your PATH:

```bash
make install   # copies bin/* to /usr/local/bin
```

Or run directly from the repo:

```bash
./bin/update
./bin/code status
```

---

## User commands (`bin/`)

### `repo`

Builds a curated list of AUR and GitHub (Frogging-Family) packages and refreshes a local pacman repository database.

- Clones package sources, applies per-package `customization.cfg` where needed, runs `makepkg`, and runs `repo-add`
- Default repo directory: `/home/repo/bash` (override with `REPO_DIR`)
- Repository name: `themis`
- Supports `--only-newer` (skip packages whose upstream version is not ahead of the local build) and `--loop` (repeat every 6 hours)

```bash
repo                          # full build
ONLY_BUILD_IF_NEWER=1 repo    # incremental build (cron-friendly)
repo --loop                   # continuous 6-hour cycle
```

Requires root/pacman access, network, `jq`, and `vercmp`.

### `update`

Updates the host system in one pass:

1. `pacman -Syu` (falls back to official repos only if the `[tekne]` repo is unreachable)
2. `pikaur -Syu` for AUR packages
3. `fwupdmgr refresh && get-updates && update` for firmware

### `code`

Bulk git operations across tekne repositories. By default scans `../ansible` and the bash repo itself; override with `-d`.

```bash
export GH_PAT='github_pat_...'   # optional, for authenticated push/pull
code status
code pull
code push -m "Update haproxy config"
code -d /path/to/repos pull
```

### `work`

Starts an XFCE session (`startxfce4`).

### `game`

Launches a game in a dedicated X11 session on display `:1` using Openbox and a custom X config (`game.conf`).

```bash
game steam
```

### `grid12` and `grid23`

X11 window tilers for XFCE (xfwm4) using `wmctrl`, `xdotool`, and `xrandr`. They detect the primary monitor geometry and place windows in a fixed grid.

| Command | Layout |
|---------|--------|
| `grid12` | 1×2 — Microsoft Edge (Default profile) left, Cursor right |
| `grid23` | 2×3 — top row: three Edge profiles; bottom row: Thunar, xfce4-terminal, Cursor |

Optional environment variables:

- `EDGE_URL`, `EDGE_URL_1`, `EDGE_URL_2`, `EDGE_URL_3` — URLs to open in Edge windows
- `GAP` — pixel gap between cells

### `foo`

Scaffold example command used by the repo template and bats tests. Demonstrates `--help`, `--version`, and shared logging from `lib/log.sh`.

---

## Maintenance scripts (`scripts/`)

These are internal tools — not installed to PATH by default.

### Package repository builders

| Script | Description |
|--------|-------------|
| `repo-aur.sh` | Builds AUR packages when upstream version is newer than the local repo; outputs to `/var/local/repo/tekne` |
| `repo-tkg.sh` | Builds Frogging-Family packages: three `linux-tkg` variants (aster, themis, yugen), plus `nvidia-all` and `wine-tkg-git` |
| `repo.sh` | Monolithic builder (superseded by the split AUR/TKG scripts in most workflows) |
| `repo-build-lock.sh` | Shared locking helper sourced by the repo build scripts |

Customization configs live in `scripts/config/`:

- `repo-linux-tkg-aster.cfg`, `repo-linux-tkg-themis.cfg`, `repo-linux-tkg-yugen.cfg`
- `repo-nvidia-all.cfg`, `repo-wine-tkg-git.cfg`

### Infrastructure and images

| Script | Description |
|--------|-------------|
| `arch-boxes.sh` | Patches the upstream [arch-boxes](https://gitlab.archlinux.org/archlinux/arch-boxes) project with tekne kernel, packages, users, SSH keys, and a custom pacman repo |
| `docker-image-arch.sh` | One-time setup of an Arch Linux Docker container for isolated package builds |
| `docker_push.sh` | Tags and pushes the Arch build image to Docker Hub |
| `k8s-cloud.sh` | Creates Kubernetes lab VMs (master + nodes) from a Debian cloud image with cloud-init |
| `virt-install.sh` | Creates/deletes libvirt VMs for the k8s cluster from an ISO |
| `windows11_repack.sh` | Repacks a Windows 11 ISO with a retail `ei.cfg` |
| `backup-schema0.sh` | Restic backup of `/srv` with daily/weekly/monthly retention |
| `ansible-colletions.sh` | Installs Ansible collections from the tekne playbooks requirements |
| `bootstrap-dev.sh` | Installs developer tooling (`shellcheck`, `bats`, `shfmt`) on Debian/Ubuntu |

---

## Repository layout

```text
tekne/bash/
├─ bin/           # User-facing commands (no .sh suffix)
├─ lib/           # Shared libraries (e.g. log.sh)
├─ scripts/       # Maintenance and infrastructure scripts
│  └─ config/     # linux-tkg / nvidia / wine customization configs
├─ tests/         # bats-core tests
├─ completion/    # bash-completion snippets
├─ docs/          # Design notes
├─ examples/      # Sample configs
├─ ci/            # Jenkins pipeline
└─ .github/       # GitHub Actions CI
```

---

## Development

### Prerequisites

On Arch:

```bash
sudo pacman -S shellcheck bats
# shfmt: available as a package or download from GitHub releases
```

On Debian/Ubuntu, run `scripts/bootstrap-dev.sh`.

### Make targets

```bash
make format        # shfmt: rewrite files in place
make format-check  # shfmt: verify formatting (CI)
make lint          # shellcheck
make test          # bats
make check         # format + lint + test
make install       # install bin/* to /usr/local/bin
```

### CI

- **GitHub Actions** — `.github/workflows/ci.yml` runs `format-check`, `lint`, and `test` on push/PR
- **Jenkins** — `ci/Jenkinsfile` runs the same checks

Pre-commit hooks (`.pre-commit-config.yaml`) run `shfmt` and `shellcheck` locally.

---

## Related projects

This repo is one piece of the tekne stack:

- **tekne/ansible** — Ansible playbooks for host configuration
- **tekne/arch-boxes** — Custom Arch Linux VM/cloud images (customized via `scripts/arch-boxes.sh`)
- **repo.tekne.sv** — Custom pacman repository serving packages built by the scripts in this repo

---

## License

See [LICENSE](LICENSE).
