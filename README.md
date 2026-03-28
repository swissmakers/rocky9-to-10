# Rocky Linux 9 to Rocky Linux 10 Upgrade Tool

[Swissmakers GmbH](https://swissmakers.ch) maintains **rocky10-upgrade.sh**, a shell tool that automates a best-effort major-version upgrade from Rocky Linux 9 to Rocky Linux 10. Major releases of the Rocky Linux family are normally addressed with clean installs. Use this miragtion path only when you understands how our tool works, by reading the source and have verified backups.

This document describes prerequisites, the two-phase workflow, optional environment variables, and post-upgrade checks. Command-line options are authoritative; run `./rocky10-upgrade.sh --help` on the target system for the embedded help text.

## Prerequisites

Before you begin, ensure the following:

* You have a **full system backup**, **VM snapshot**, or equivalent recovery path.
* The host runs **Rocky Linux 9** for phase 1 and you have **root** access via the local console or out-of-band management (SSH works too, but when loosing the connection while upgrade is bad. Alternatively use tmux/screen).
* **Disk space** meets the tools’s minimum checks for `/`, `/boot`, and `/boot/efi` when applicable (defaults are documented in `--help`).
* On **x86_64**, the CPU meets **x86-64-v3** requirements for Rocky Linux 10 (the tools automatically probes this).
* You have reviewed your **third-party and custom DNF repositories**; broken `.repo` files can block `dnf` or cause errors during the upgrade.

**Important:** Read the **License** section at the end of this document. Commercial use requires a separate agreement with the copyright holder.

## Overview of the upgrade phases

The tool is split into **phase 1** (on Rocky Linux 9) and **phase 2** (on Rocky Linux 10 after reboot).

| Phase | When | Purpose |
| ------- | ------ | --------- |
| 1 | Rocky Linux 9, with `--do-upgrade` | Does all preparations, checks and Bootstrap Rocky Linux 10 repositories and packages, executes `distro-sync`, and does the controlled reboots as required by the tool. (On reboot this step also fixes all old SELinux labels systemwide.) |
| 2 | Rocky Linux 10 | Runs a post-upgrade cleanup, enables CRB / EPEL repo if they were enabled before, runs `dnf upgrade` with `--allowerasing` to also migrade software from additional repos, optional removal of old EL9 kernels. |

State is recorded in files under `/var/lib` and logs under `/var/log` (see **Reference: paths and files**).

## Start the migration with phase 1 (on Rocky Linux 9)

1. Make sure you are root, then clone this repo to the server you like to migrate and make it executable:

   ```bash
   sudo -i
   git clone https://github.com/swissmakers/rocky9-to-10.git && cd rocky9-to-10
   chmod +x rocky10-upgrade.sh
   ```

2. Inspect the tool options:

   ```bash
   ./rocky10-upgrade.sh --help
   ./rocky10-upgrade.sh --version
   ```

3. If legacy **ifcfg** network configuration files are present and the tool refuses to continue, either remediate them or pass **`--accept-network-risk`** only after you understand the migration to NetworkManager keyfiles.

4. Start migration phase 1:

   ```bash
   ./rocky10-upgrade.sh --do-upgrade
   ```

5. Follow on-screen and log output. If the tool requests a additional **reboot** (e.g. when your system was not uptodate before), please do that and re-execute it again as above.

**Note:** Optional environment variables (for example `ROCKY10_PARK_REPOS`) are described under **Reference: environment variables**.

## Run phase 2 (on Rocky Linux 10)

After the system boots up into Rocky Linux 10:

1. Run post-upgrade cleanup explicitly:

   ```bash
   ./rocky10-upgrade.sh --phase2
   ```

2. Like prompted by the tool (at the end of phase2), verify your custom **`/etc/yum.repos.d`** against the backup directory recorded in the preflight state file. Ensure third-party URLs use **`$releasever`** or **10** as appropriate.

## Audit and optional removal of EL9-tagged packages and old kernels

Use these commands for troubleshooting leftovers that still show **`el9`** in the RPM tag:

1. List old packages:

   ```bash
   ./rocky10-upgrade.sh --audit packages
   ```

2. Preview what **`dnf remove`** would do for all EL9-tagged packages (simulation only):

   ```bash
   ./rocky10-upgrade.sh --audit deps
   ```

3. To **actually remove** those packages after reviewing the preview, run:

   ```bash
   ./rocky10-upgrade.sh --audit deps --remove-el9-rpms
   ```

   **Warning:** This is destructive. Review the transaction preview carefully; removing wrong shared libraries or tools can break custom applications you deployed before.

4. Inspect your logs and the SELinux audit-log as needed:

   ```bash
   ./rocky10-upgrade.sh --audit errors
   ./rocky10-upgrade.sh --audit selinux
   ```

## Reference: paths and files

| Path | Role |
| ------ | ------ |
| `/var/log/rocky10-upgrade.log` | Main log file when the script tees output to the log. |
| `/var/lib/rocky10-upgrade.need-post` | Marker that phase 2 uses to detect pending cleanup. |
| `/var/lib/rocky10-upgrade.bootstrap-resume` | Resume hint after bootstrap when a additional reboot was required. |
| `/var/lib/rocky10-upgrade.preflight` | Preflight state (EPEL flag, parked repos, backup path for `yum.repos.d`). |

## Reference: environment variables

| Variable | Purpose |
| ---------- | --------- |
| `ROCKY10_PARK_REPOS` | Space-separated `.repo` basenames under `/etc/yum.repos.d/` to park (rename) during phase 1 when they break `dnf`. |
| `ROCKY10_BASEOS_PACKAGES_G_URL` | Override URL for BaseOS `Packages/g/` when fetching bootstrap RPMs (when there are only offline inhouse mirrors available). |
| `ROCKY10_PHASE2_REMOVE_EL9_KERNELS` | Set to `1` to remove EL9 kernel packages during phase 2 (same effect as additionally use `--remove-el9-kernels`). |
| `ROCKY10_AUDIT_REMOVE_EL9_RPMS` | Set to `1` with `--audit deps` to perform removal (same effect as `--remove-el9-rpms`). |

## Additional resources

* [Rocky Linux documentation](https://docs.rockylinux.org/)
* [Red Hat Enterprise Linux documentation](https://docs.redhat.com/) (conceptual background for `dnf`, boot loaders, and major upgrades)
* PolyForm Noncommercial License: see the `LICENSE` file in this repository and [PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/)

## Feedback

Report feedback or ask about commercial licensing: **info@swissmakers.ch**

## License

Copyright (C) 2026 Swissmakers GmbH (<https://swissmakers.ch>)

This project is licensed under the **PolyForm Noncommercial License 1.0.0**. See the `LICENSE` file for the full text.

**Required notice (per license):**

```text
Required Notice: Copyright (C) 2026 Swissmakers GmbH (https://swissmakers.ch)
```

Commercial use, redistribution in commercial products, or other uses outside the noncommercial terms require a **separate license** from Swissmakers GmbH. Contact **info@swissmakers.ch**.
