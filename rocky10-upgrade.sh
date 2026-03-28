#!/usr/bin/env bash
#
# rocky10-upgrade.sh — A tool for migrating Rocky Linux 9 to Rocky Linux 10.
# Copyright (C) 2026 Swissmakers GmbH (https://swissmakers.ch)
#
# Licensed under the PolyForm Noncommercial License 1.0.0.
# See the LICENSE file in this distribution or:
#   https://polyformproject.org/licenses/noncommercial/1.0.0/
#
# Usage: ./rocky10-upgrade.sh --help

set -euo pipefail

readonly LOG_FILE="/var/log/rocky10-upgrade.log"
readonly MARKER_FILE="/var/lib/rocky10-upgrade.need-post"
readonly BOOTSTRAP_RESUME_FILE="/var/lib/rocky10-upgrade.bootstrap-resume"
readonly PREFLIGHT_FILE="/var/lib/rocky10-upgrade.preflight"
readonly SCRIPT_NAME="${0##*/}"

ACCEPT_NET_RISK=0
PHASE2=0
MIN_ROOT_GIB=5
MIN_BOOT_MIB=400
MIN_EFI_MIB=100
FORCE_BOOTSTRAP_REBOOT=0
PHASE2_REMOVE_EL9_KERNELS=0
REMOVE_EL9_RPMS=0
DO_UPGRADE=0
AUDIT_MODE=""
AUDIT_ARGS_INVALID=0
CLI_NEED_HELP=0
WANT_VERSION=0
ORIGINAL_ARGC=0
readonly TOOL_CLI_VERSION="1.4"
DNF_EXTRA_OPTS=(--disableplugin=generate_completion_cache)

log() { printf '%s %s\n' "$(date -Iseconds)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
warn() { log "WARN: $*"; }

cli_detect_os_summary() {
	if [[ ! -f /etc/os-release ]]; then
		echo "unknown (no /etc/os-release)"
		return
	fi
	local pretty ver arch
	pretty=$(os_get PRETTY_NAME)
	ver=$(os_get VERSION_ID)
	arch=$(uname -m 2>/dev/null || echo "?")
	if [[ -n "$pretty" ]]; then
		echo "$pretty ($arch)"
	else
		echo "$(os_get ID) ${ver:-?} ($arch)"
	fi
}

print_cli_version() {
	printf '%s\n' "rocky10-upgrade (Swissmakers GmbH) ${TOOL_CLI_VERSION}"
	printf '%s\n' "Detected operating system: $(cli_detect_os_summary)"
}

print_cli_help() {
	local _os
	_os=$(cli_detect_os_summary)
	cat <<EOF
================================================================================
  Swissmakers GmbH - Rocky Linux 9 to Rocky Linux 10 in-place upgrade tool (v${TOOL_CLI_VERSION})
  Detected operating system: ${_os}
================================================================================

Usage: ${SCRIPT_NAME} [OPTION]...

Best-effort in-place upgrade from Rocky Linux 9 to 10 using dnf distro-sync.
Upstream documents fresh installs for major versions; create full backups or VM
snapshots before running this tool.

Infos:
  -h, --help                 display this help and exit
  -v, --version              show version and detected OS, then exit

Upgrade:
      --do-upgrade           start phase 1 of the upgrade (required on Rocky Linux 9 to begin)
      --phase2               post-upgrade cleanup (only available on Rocky Linux 10)
      --remove-el9-kernels   only usable together with --phase2. Removes installed kernel packages matching *el9*

Safety:
      --accept-network-risk  continue upgrading and ignore legacy ifcfg files if found (default: exit with error)
      --force-reboot         if dnf stays broken after bootstrap repair, reboot anyway (default: exit with error)
      --min-root-size N      minimum required free GiB on / (default: ${MIN_ROOT_GIB})
      --min-boot-size N      minimum required free MiB on /boot (default: ${MIN_BOOT_MIB})
      --min-efi-size N       minimum required free MiB on /boot/efi if mounted (default: ${MIN_EFI_MIB})

Post-upgrade:
      --audit TOPIC          TOPIC is one of: packages | deps | errors | selinux
                               packages —> list still installed old el9-tagged RPMs
                               deps     —> dnf removal simulation; shows what else would be removed
                               errors   —> journalctl errors/alerts, current boot
                               selinux  —> SELinux / AVC-related output (e.g. sealert, ausearch)
      --remove-el9-rpms      Only usable together with "--audit deps". After dnf preview, this will run dnf remove -y on all el9-tagged RPMs.

Report feedback to: info@swissmakers.ch
EOF
}

parse_args() {
	CLI_NEED_HELP=0
	AUDIT_ARGS_INVALID=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h | --help)
				print_cli_help
				exit 0
				;;
			-v | --version)
				WANT_VERSION=1
				;;
			--do-upgrade) DO_UPGRADE=1 ;;
			--audit)
				if [[ -z "${2:-}" ]]; then
					warn "--audit requires a topic: packages | deps | errors | selinux"
					AUDIT_ARGS_INVALID=1
					shift
					continue
				fi
				case "$2" in
					packages | deps | errors | selinux) AUDIT_MODE="$2" ;;
					*)
						warn "Unknown --audit topic: $2 (expected: packages|deps|errors|selinux)"
						AUDIT_ARGS_INVALID=1
						;;
				esac
				shift 2
				continue
				;;
			--accept-network-risk) ACCEPT_NET_RISK=1 ;;
			--phase2) PHASE2=1 ;;
			--min-root-size)
				MIN_ROOT_GIB="${2:?}"
				shift
				;;
			--min-boot-size)
				MIN_BOOT_MIB="${2:?}"
				shift
				;;
			--min-efi-size)
				MIN_EFI_MIB="${2:?}"
				shift
				;;
			--force-reboot) FORCE_BOOTSTRAP_REBOOT=1 ;;
			--remove-el9-kernels) PHASE2_REMOVE_EL9_KERNELS=1 ;;
			--remove-el9-rpms) REMOVE_EL9_RPMS=1 ;;
			*)
				warn "Unknown option: $1"
				CLI_NEED_HELP=1
				;;
		esac
		shift
	done
}

# Post-upgrade audit / cleanup / troubleshooting
run_audit() {
	local mode="$1"
	local pkgs n

	case "$mode" in
		packages)
			echo "================================================================================"
			echo "Old el9-tagged packages still installed:"
			echo "================================================================================"
			pkgs=$(rpm -qa 2>/dev/null | grep -E 'el9|\.el9' | sort || true)
			if [[ -z "$pkgs" ]]; then
				echo "(no el9-tagged packages)"
			else
				echo "$pkgs"
			fi
			n=$(rpm -qa 2>/dev/null | grep -cE 'el9|\.el9' || true)
			echo "================================================================================"
			echo "Count: $n"
			;;
		deps)
			echo "================================================================================"
			if [[ "$REMOVE_EL9_RPMS" -eq 1 ]]; then
				echo "Removal of all installed el9-tagged packages with their dependencies:"
			else
				echo "Removal simulation (of all installed el9-tagged packages with their dependencies):"
				echo "  Shows what dnf would remove if you do a full cleanup of your system."
				echo "  Nothing is changed on disk, it's a transaction preview only!"
			fi
			echo "================================================================================"
			if [[ $EUID -ne 0 ]]; then
				warn "Run as root for an accurate dnf removal preview (required for --remove-el9-rpms)!"
			fi
			if ! command -v dnf &>/dev/null; then
				die "dnf not found; cannot simulate removal (install dnf or use --audit packages)"
			fi
			local -a pkg_arr=()
			readarray -t pkg_arr < <(rpm -qa 2>/dev/null | grep -E 'el9|\.el9' | sort -u || true)
			if ((${#pkg_arr[@]} == 0)); then
				echo "(no el9-tagged packages)"
				return 0
			fi
			n=${#pkg_arr[@]}
			echo "El9-tagged packages in scope: $n"
			echo "--------------------------------------------------------------------------------"
			echo "Transaction preview (dnf remove --assumeno):"
			printf '%s\0' "${pkg_arr[@]}" | xargs -0 -r dnf "${DNF_EXTRA_OPTS[@]}" remove --assumeno || true
			echo "--------------------------------------------------------------------------------"
			if [[ "$REMOVE_EL9_RPMS" -eq 1 ]]; then
				[[ $EUID -eq 0 ]] || die "root required for --remove-el9-rpms"
				warn "Running: dnf remove -y (all el9-tagged packages listed above)"
				if ! printf '%s\0' "${pkg_arr[@]}" | xargs -0 -r dnf "${DNF_EXTRA_OPTS[@]}" remove -y; then
					warn "dnf remove -y failed."
					return 1
				fi
				echo "dnf remove -y finished."
				return 0
			fi
			echo "To fully cleanup your system, you can use the command as before with adding --remove-el9-rpms"
			;;
		errors)
			echo "================================================================================"
			echo "journalctl: errors/alerts, current boot (-b):"
			echo "================================================================================"
			if [[ $EUID -ne 0 ]]; then
				warn "Not root; journal output may be incomplete"
			fi
			journalctl -p err..alert -b --no-pager 2>/dev/null || journalctl -p 3 -xb --no-pager 2>/dev/null || true
			;;
		selinux)
			echo "================================================================================"
			echo "SELinux / AVC-related errors/alerts:"
			echo "================================================================================"
			if [[ $EUID -ne 0 ]]; then
				warn "Not root; install/use sealert or ausearch as root for full detail"
			fi
			if command -v sealert &>/dev/null && [[ -r /var/log/audit/audit.log ]]; then
				sealert -a /var/log/audit/audit.log 2>/dev/null || warn "sealert failed"
			elif command -v ausearch &>/dev/null; then
				ausearch -m avc -ts boot 2>/dev/null || ausearch -m avc 2>/dev/null || true
			else
				journalctl -u setroubleshoot -b --no-pager 2>/dev/null | head -200 || journalctl -k -b --no-pager 2>/dev/null | grep -i avc | head -100 || true
				warn "Install setroubleshoot-server or use ausearch for AVC details"
			fi
			;;
		*)
			die "run_audit: invalid mode: $mode"
			;;
	esac
}

os_get() {
	local key="$1"
	awk -F= -v k="$key" '$1==k { gsub(/^"|"$/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || true
}

ensure_log() {
	if [[ ! -f "$LOG_FILE" ]]; then
		touch "$LOG_FILE" 2>/dev/null || true
	fi
}

# Requires x86-64-v3 (same flag probe as common EL community docs)
check_cpu_isa_x86_v3() {
	local arch
	arch="$(uname -m)"
	if [[ "$arch" != "x86_64" ]]; then
		log "CPU ISA check skipped (architecture: $arch). Verify Rocky 10 supports your CPU model."
		return 0
	fi
	if ! awk -f - /proc/cpuinfo <<'AWK'
BEGIN {
	while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
	if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
	if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
	if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
	if (level >= 3) exit 0
	exit 1
}
AWK
	then
		die "CPU does not meet x86-64-v3 (required for Rocky Linux 10 on x86_64). Use a fresh install or fix VM CPU flags."
	fi
	log "CPU ISA: x86-64-v3 (or newer) detected — OK"
}

get_free_kib() {
	local mp="$1"
	df -Pk "$mp" 2>/dev/null | awk 'NR==2 { print $4 }'
}

check_free_kib() {
	local mp="$1"
	local need_kib="$2"
	local avail
	avail=$(get_free_kib "$mp")
	if [[ -z "$avail" ]]; then
		die "Cannot read free space for $mp"
	fi
	if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
		die "Cannot parse free space for $mp"
	fi
	if (( avail < need_kib )); then
		die "Insufficient free space on $mp (need at least $need_kib KiB, have $avail KiB)"
	fi
	log "Disk OK: $mp has ${avail} KiB free (min ${need_kib} KiB)"
}

collect_old_kernel_rpms() {
	local running rline
	local -a cand=()
	running=$(uname -r)

	cand=()
	while IFS= read -r rline; do
		[[ -z "$rline" ]] && continue
		[[ "$rline" == *"$running"* ]] && continue
		cand+=("$rline")
	done < <(dnf repoquery --installonly --latest-limit=-2 -q 2>/dev/null)

	if ((${#cand[@]} == 0)); then
		while IFS= read -r rline; do
			[[ -z "$rline" ]] && continue
			[[ "$rline" == *"$running"* ]] && continue
			cand+=("$rline")
		done < <(dnf repoquery --installonly -q 2>/dev/null)
	fi

	((${#cand[@]} == 0)) && return 0
	printf '%s\n' "${cand[@]}" | sort -u
}

read_yes_from_user() {
	local line
	if [[ -r /dev/tty ]]; then
		read -r line </dev/tty
	else
		read -r line
	fi
	[[ "$line" == "yes" ]]
}

check_boot_space_with_cleanup() {
	local need_kib="$1"
	local avail
	local -a old_kernels

	while true; do
		avail=$(get_free_kib /boot)
		if [[ -z "$avail" ]]; then
			die "Cannot read free space for /boot"
		fi
		if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
			die "Cannot parse free space for /boot"
		fi
		if (( avail >= need_kib )); then
			log "Disk OK: /boot has ${avail} KiB free (min ${need_kib} KiB)"
			return 0
		fi

		log "Insufficient free space on /boot (need at least ${need_kib} KiB, have ${avail} KiB)"
		mapfile -t old_kernels < <(collect_old_kernel_rpms)
		if ((${#old_kernels[@]} == 0)); then
			die "No non-running kernel packages found to remove. Free /boot manually (e.g. enlarge partition, remove leftovers) and re-run this script."
		fi

		echo ""
		echo "================================================================"
		echo " Running kernel: $(uname -r)"
		echo " Proposed removal (dnf repoquery --installonly --latest-limit=-2, minus running kernel):"
		printf '   %s\n' "${old_kernels[@]}"
		echo "================================================================"
		echo " Type exactly: yes  to remove these packages with dnf"
		echo " Anything else aborts the upgrade."
		echo "================================================================"

		if ! read_yes_from_user; then
			die "Aborted: /boot still too small and cleanup not confirmed."
		fi

		log "Removing old kernel packages: ${old_kernels[*]}"
		dnf remove -y "${old_kernels[@]}" </dev/null || die "dnf remove failed for old kernel packages"
		log "Kernel cleanup finished; re-checking /boot free space..."
	done
}

check_disk_space() {
	local root_kib boot_kib efi_kib
	root_kib=$((MIN_ROOT_GIB * 1024 * 1024))
	boot_kib=$((MIN_BOOT_MIB * 1024))
	check_free_kib / "$root_kib"
	if [[ -d /boot ]]; then
		check_boot_space_with_cleanup "$boot_kib"
	fi
	if findmnt /boot/efi &>/dev/null; then
		efi_kib=$((MIN_EFI_MIB * 1024))
		check_free_kib /boot/efi "$efi_kib"
	fi
}

check_root_fs_type() {
	local fstype
	fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
	if [[ -z "$fstype" ]]; then
		warn "Could not detect root filesystem type"
		return 0
	fi
	case "$fstype" in
		xfs|ext4) log "Root filesystem type: $fstype — OK" ;;
		*) warn "Root filesystem is $fstype (not xfs/ext4). Proceed at your own risk." ;;
	esac
}

ssh_warning() {
	if [[ -n "${SSH_CONNECTION:-}" ]]; then
		warn "You appear to be on SSH. Network stack updates can drop this session. Prefer iLO/IPMI/console or tmux/screen."
		sleep 3
	fi
}

check_network_scripts() {
	local shopt_null
	shopt_null=0
	shopt -q nullglob && shopt_null=1
	shopt -s nullglob
	local ifcfgs=(/etc/sysconfig/network-scripts/ifcfg-*)
	[[ "$shopt_null" -eq 1 ]] || shopt -u nullglob
	if ((${#ifcfgs[@]} > 0)); then
		if [[ "$ACCEPT_NET_RISK" -eq 0 ]]; then
			die "Legacy ifcfg files found under /etc/sysconfig/network-scripts/. EL10 does not use network-scripts. Migrate to NetworkManager keyfiles or pass --accept-network-risk after reading https://docs.redhat.com/ documentation on NM."
		fi
		warn "Legacy ifcfg present; you accepted migration risk. Ensure NM profiles exist under /etc/NetworkManager/system-connections/ before reboot."
	fi
}

check_dracut_network_legacy() {
	local f
	shopt -s nullglob
	for f in /etc/dracut.conf.d/*network-legacy*; do
		warn "Dracut snippet may pull network-legacy: $f (can break initramfs after upgrade; consider removing if dracut fails)."
	done
	shopt -u nullglob
}

command_exists() { command -v "$1" &>/dev/null; }

check_minimal_commands() {
	command_exists dnf || die "dnf is required"
	command_exists rpm || die "rpm is required"
}

check_required_commands() {
	local missing=()
	for c in dnf rpm gawk df findmnt awk tee date; do
		command_exists "$c" || missing+=("$c")
	done
	if ! command_exists curl && ! command_exists wget; then
		missing+=("curl or wget")
	fi
	if [[ ${#missing[@]} -gt 0 ]]; then
		die "Missing required commands: ${missing[*]}"
	fi
}

install_packages_if_needed() {
	local to_install=()
	command_exists dnf || die "dnf is required"
	rpm -q dnf-plugins-core &>/dev/null || to_install+=(dnf-plugins-core)
	command_exists gawk || to_install+=(gawk)
	if ! command_exists curl && ! command_exists wget; then
		to_install+=(curl)
	fi
	if [[ ${#to_install[@]} -eq 0 ]]; then
		return 0
	fi
	log "Installing: ${to_install[*]}"
	# Avoid dnf reading closed pipe stdin in edge cases
	dnf install -y "${to_install[@]}" </dev/null || die "dnf install failed for: ${to_install[*]}"
	log "Dependency packages installed (or already present)."
}

prompt_backup() {
	local line
	echo ""
	echo "================================================================"
	echo " Have you created a FULL backup or VM snapshot of this system?"
	echo " Type exactly: yes"
	echo " Anything else aborts."
	echo "================================================================"
	read -r line
	if [[ "$line" != "yes" ]]; then
		die "Aborted: backup not confirmed (you must type exactly: yes)"
	fi
	log "User confirmed backup (typed yes)."
	if [[ -r /dev/tty ]]; then
		exec 0</dev/tty || exec 0</dev/null || true
	else
		exec 0</dev/null || true
	fi
}

run_full_upgrade_refresh() {
	log "Running: dnf upgrade --refresh -y"
	dnf upgrade --refresh -y
	if ! dnf needs-restarting -r &>/dev/null; then
		log "System reports a reboot is required before major upgrade."
		log "Rebooting now, then re-run the tool: $0"
		die "Reboot required after updates (kernel/systemd/glibc may have changed)."
		reboot
	fi
}

run_dnf_check() {
	log "Running: dnf check"
	set +e
	dnf check
	local ec=$?
	set -e
	if [[ $ec -ne 0 ]]; then
		die "dnf check failed (exit $ec). Fix RPM/database issues before upgrading."
	fi
}

backup_and_sanitize_repos() {
	local stamp dir epel_was=0
	local -a parked_pairs=()
	local -a custom_repos=()
	local f b _rp

	stamp=$(date +%Y%m%d-%H%M%S)
	dir="/root/yum.repos.d.backup-$stamp"

	rpm -q epel-release &>/dev/null && epel_was=1

	shopt -s nullglob
	for f in /etc/yum.repos.d/*.repo; do
		b=${f##*/}
		case "$b" in
			rocky*.repo | Rocky*.repo) continue ;;
			*) custom_repos+=("$b") ;;
		esac
	done
	shopt -u nullglob

	log "Backing up /etc/yum.repos.d to $dir"
	cp -a /etc/yum.repos.d "$dir"

	if [[ -n "${ROCKY10_PARK_REPOS:-}" ]]; then
		local -a _park_list=()
		read -r -a _park_list <<<"${ROCKY10_PARK_REPOS}"
		for _rp in "${_park_list[@]}"; do
			[[ -z "$_rp" ]] && continue
			case "$_rp" in
				*.repo) ;;
				*) _rp="${_rp}.repo" ;;
			esac
			if [[ -f "/etc/yum.repos.d/$_rp" ]]; then
				if mv "/etc/yum.repos.d/$_rp" "/etc/yum.repos.d/${_rp}.disabled-by-upgrade" 2>/dev/null; then
					log "Parked repo file as ${_rp}.disabled-by-upgrade (from ROCKY10_PARK_REPOS)"
					parked_pairs+=("${_rp}|${_rp}.disabled-by-upgrade")
				fi
			else
				warn "ROCKY10_PARK_REPOS lists $_rp but file is not present under /etc/yum.repos.d/"
			fi
		done
	fi

	# Remove epel-release if installed
	if rpm -q epel-release &>/dev/null; then
		log "Removing package: epel-release (reinstall after upgrade if needed)"
		dnf remove -y epel-release || true
	fi

	local id
	while read -r id; do
		[[ -z "$id" || "$id" == "repo" ]] && continue
		dnf config-manager --set-disabled "$id" 2>/dev/null || true
	done < <(dnf repolist --enabled -q 2>/dev/null | awk 'NR>1 {print $1}')

	local rocky_ids=(baseos appstream extras crb devel)
	local rid
	for rid in "${rocky_ids[@]}"; do
		if dnf repolist all -q 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$rid"; then
			dnf config-manager --set-enabled "$rid" 2>/dev/null && log "Enabled repo: $rid" || true
		fi
	done

	if [[ $(dnf repolist --enabled -q 2>/dev/null | awk 'NR>1' | wc -l) -lt 1 ]]; then
		for rid in rocky-baseos rocky-appstream rocky-extras rocky-crb; do
			dnf config-manager --set-enabled "$rid" 2>/dev/null && log "Enabled repo: $rid" || true
		done
	fi

	local en_count
	en_count=$(dnf repolist --enabled -q 2>/dev/null | awk 'NR>1' | wc -l)
	if [[ "$en_count" -lt 1 ]]; then
		die "No DNF repos enabled after sanitization. Restore from $dir and fix .repo files."
	fi
	log "Active repos after sanitization:"
	dnf repolist --enabled -v || true

	mkdir -p "$(dirname "$PREFLIGHT_FILE")"
	{
		echo "# Written by $SCRIPT_NAME — phase 2 restores EPEL/parked repos; safe to delete after phase 2."
		echo "EPEL_WAS_INSTALLED=$epel_was"
		echo "BACKUP_DIR=$dir"
		for b in "${custom_repos[@]}"; do
			echo "CUSTOM_REPO=$b"
		done
		for _rp in "${parked_pairs[@]}"; do
			echo "PARKED=$_rp"
		done
	} >"$PREFLIGHT_FILE"
	log "Wrote preflight state $PREFLIGHT_FILE"
}

install_el10_release_rpms() {
	local dl_dir="$1"
	local gk rel rep
	shopt -s nullglob
	gk=( "$dl_dir"/rocky-gpg-keys*.rpm )
	rel=( "$dl_dir"/rocky-release*.rpm )
	rep=( "$dl_dir"/rocky-repos*.rpm )
	shopt -u nullglob
	((${#gk[@]} == 1)) || die "Expected exactly one rocky-gpg-keys RPM in $dl_dir"
	((${#rel[@]} == 1)) || die "Expected exactly one rocky-release RPM in $dl_dir"
	((${#rep[@]} == 1)) || die "Expected exactly one rocky-repos RPM in $dl_dir"
	dnf "${DNF_EXTRA_OPTS[@]}" config-manager --set-disabled devel 2>/dev/null || true
	log "Installing Rocky 10 bootstrap RPMs via dnf --releasever=10 (gpg-keys, repos, release + deps)"
	if ! dnf "${DNF_EXTRA_OPTS[@]}" install -y --releasever=10 --allowerasing --nogpgcheck \
		"${gk[0]}" "${rep[0]}" "${rel[0]}" </dev/null
	then
		log "dnf install failed; trying single rpm -Uvh transaction (gpg-keys → repos → release)"
		rpm -Uvh "${gk[0]}" "${rep[0]}" "${rel[0]}" || die "Failed to install Rocky 10 release RPMs (dnf and rpm both failed)"
	fi
}

dnf_cli_works() {
	/usr/bin/dnf --version &>/dev/null
}

ensure_rpm_db_paths() {
	mkdir -p /var/lib/rpm /usr/lib/sysimage/rpm 2>/dev/null || true
	local dbp
	dbp=$(rpm -E '%{_dbpath}' 2>/dev/null) || true
	if [[ -n "$dbp" && "$dbp" != *'{'* && "$dbp" != *'%'* ]]; then
		mkdir -p "$dbp" || true
	fi
}

cleanup_stale_rpmold_dirs() {
	local f
	shopt -s nullglob
	for f in /usr/lib/sysimage/rpmold.[0-9]*; do
		rm -rf "$f" 2>/dev/null || warn "Could not remove stale RPM temp dir: $f"
	done
	shopt -u nullglob
}

rpm_rebuilddb_with_retry() {
	ensure_rpm_db_paths
	cleanup_stale_rpmold_dirs
	if rpm --rebuilddb; then
		return 0
	fi
	warn "rpm --rebuilddb failed; retrying after cleaning /usr/lib/sysimage/rpmold.*"
	cleanup_stale_rpmold_dirs
	rpm --rebuilddb
}

# True when glib2 is still el9 but libmodulemd is already el10
glib_modulemd_skew_detected() {
	rpm -q glib2 &>/dev/null && rpm -q libmodulemd &>/dev/null || return 1
	rpm -q glib2 2>/dev/null | grep -qE '\.el9' && rpm -q libmodulemd 2>/dev/null | grep -qE '\.el10'
}

# EL10 libmodulemd may load before glib2 is fully aligned
repair_dnf_glib_modulemd_stack() {
	local arch tmpdir html url pkg pkg_gi pkgm
	arch=$(uname -m)
	tmpdir=$(mktemp -d /tmp/rocky10-glib-fix.XXXXXX)
	log "Attempting dnf recovery: rpm --rebuilddb + EL10 glib2+gobject-introspection from BaseOS (libmodulemd/GLib mismatch)"
	rpm_rebuilddb_with_retry || warn "rpm --rebuilddb returned non-zero"
	command_exists ldconfig && ldconfig || true

	log "Current glib2 / libmodulemd RPMs:"
	rpm -qa 'glib2*' 'libmodulemd*' 2>/dev/null | sort || true
	local modso
	modso=$(rpm -ql libmodulemd 2>/dev/null | grep -E 'libmodulemd\.so\.[0-9]+$' | head -1 || true)
	if [[ -n "$modso" ]]; then
		log "ldd $modso:"
		ldd "$modso" 2>&1 | while read -r _ln; do log "  $_ln"; done || true
	fi

	url="${ROCKY10_BASEOS_PACKAGES_G_URL:-https://download.rockylinux.org/pub/rocky/10/BaseOS/${arch}/os/Packages/g/}"
	log "Fetching directory: $url"
	if ! html=$(curl -fsSL --connect-timeout 45 "$url" 2>/dev/null); then
		rm -rf "$tmpdir"
		warn "Could not fetch $url (set ROCKY10_BASEOS_PACKAGES_G_URL to your mirror's .../Packages/g/ if needed)"
		return 1
	fi

	pkg=$(echo "$html" | grep -oE "glib2-[0-9][^\"[:space:]]*\\.el10[^\"[:space:]]*\\.${arch}\\.rpm" | sort -V | tail -1)
	pkg_gi=$(echo "$html" | grep -oE "gobject-introspection-[0-9][^\"[:space:]]*\\.el10[^\"[:space:]]*\\.${arch}\\.rpm" | sort -V | tail -1)
	if [[ -z "$pkg" ]]; then
		rm -rf "$tmpdir"
		warn "No glib2 *el10*${arch}.rpm found in index"
		return 1
	fi
	if [[ -z "$pkg_gi" ]]; then
		rm -rf "$tmpdir"
		warn "No gobject-introspection *el10*${arch}.rpm in index (required with glib2: el9 gi conflicts with el10 glib2)"
		return 1
	fi
	log "Installing in one transaction: $pkg_gi $pkg"
	if ! curl -fsSL -o "$tmpdir/$pkg_gi" "${url}${pkg_gi}" || ! curl -fsSL -o "$tmpdir/$pkg" "${url}${pkg}"; then
		rm -rf "$tmpdir"
		warn "curl failed for BaseOS Packages/g/ RPMs"
		return 1
	fi
	rpm -Uvh --nosignature "$tmpdir/$pkg_gi" "$tmpdir/$pkg" || { rm -rf "$tmpdir"; warn "rpm -Uvh gobject-introspection+glib2 failed"; return 1; }
	command_exists ldconfig && ldconfig || true

	if dnf_cli_works; then
		log "dnf works after glib2 install"
		rm -rf "$tmpdir"
		return 0
	fi

	pkgm=$(echo "$html" | grep -oE "libmodulemd-[0-9][^\"[:space:]]*\\.el10[^\"[:space:]]*\\.${arch}\\.rpm" | sort -V | tail -1)
	if [[ -n "$pkgm" ]]; then
		log "Reinstalling libmodulemd RPM: $pkgm"
		if curl -fsSL -o "$tmpdir/$pkgm" "${url}${pkgm}"; then
			rpm -Uvh --nosignature --force "$tmpdir/$pkgm" || warn "rpm -Uvh libmodulemd failed"
		fi
	fi
	command_exists ldconfig && ldconfig || true
	rm -rf "$tmpdir"
	if dnf_cli_works; then
		log "dnf works after libmodulemd reinstall"
		return 0
	fi
	return 1
}

ensure_dnf_working_or_repair() {
	if dnf_cli_works; then
		return 0
	fi
	log "dnf CLI is not working (often: ImportError libmodulemd.so / undefined symbol g_once_init_leave_pointer)"
	if repair_dnf_glib_modulemd_stack; then
		:
	else
		warn "Automatic GLib/libmodulemd repair did not complete successfully"
	fi
	if dnf_cli_works; then
		log "dnf is usable after recovery"
		return 0
	fi
	die "dnf still broken after recovery. Inspect: rpm -qa 'glib2*' 'gobject-introspection*' 'libmodulemd*'; install matching EL10 glib2 + gobject-introspection from BaseOS Packages/g/ in one rpm -Uvh."
}

apply_rpmnew_repos() {
	local n
	shopt -s nullglob
	for n in /etc/yum.repos.d/*.rpmnew; do
		local base="${n%.rpmnew}"
		if [[ -f "$base" ]]; then
			cp -a "$base" "${base}.el9-save-$(date +%Y%m%d%H%M%S)"
		fi
		log "Applying rpmnew as new config: $n -> $base"
		mv "$n" "$base"
	done
	shopt -u nullglob
	if command_exists rpmconf; then
		log "rpmconf is installed; you may run 'rpmconf -a' later for other .rpmnew files."
	fi
}

ensure_rocky10_repos_enabled() {
	ensure_dnf_working_or_repair
	local rid
	for rid in baseos appstream extras crb; do
		dnf "${DNF_EXTRA_OPTS[@]}" config-manager --set-enabled "$rid" 2>/dev/null || true
	done
	log "Repos enabled for EL10 sync:"
	dnf "${DNF_EXTRA_OPTS[@]}" repolist --enabled -v || true
}

log_expected_major_upgrade_noise() {
	log "Note: Large RPM transactions often print benign noise: SELinux old fcontext / regex mismatch until reload; libsemanage \"not in password file\" for IPA/SSSD users; D-Bus \"Transport endpoint is not connected\"; missing sockets mid-upgrade; gdk-pixbuf/tiff/jpeg glitches until libraries align."
	log "After sync: script runs restorecon; reboot clears remaining SELinux; merge *.rpmsave/*.rpmnew (e.g. nsswitch.conf) if you had local edits."
}

run_distro_sync() {
	ensure_dnf_working_or_repair
	log_expected_major_upgrade_noise
	log "Running: dnf clean all"
	dnf "${DNF_EXTRA_OPTS[@]}" clean all
	log "Running: dnf distro-sync --releasever=10 --allowerasing --noautoremove --setopt=deltarpm=false"
	dnf "${DNF_EXTRA_OPTS[@]}" distro-sync --releasever=10 --allowerasing --noautoremove --setopt=deltarpm=false -y
}

post_sync_maintenance() {
	if command_exists restorecon; then
		log "Running quick SELinux relabel before rpm rebuilddb"
		restorecon -R / || warn "restorecon reported issues; check SELinux after reboot"
	fi
	log "Running: rpm --rebuilddb"
	rpm_rebuilddb_with_retry || warn "rpm --rebuilddb had issues; try manually after reboot"
}

write_marker_and_reboot() {
	mkdir -p "$(dirname "$MARKER_FILE")"
	date -Iseconds >"$MARKER_FILE"
	log "Wrote marker $MARKER_FILE for optional post-reboot phase."
	touch /.autorelabel
	log "Created /.autorelabel -> on next boot we will run a full SELinux filesystem relabel to apply Rocky Linux 10 default contexts."
	log "Rebooting into Rocky Linux 10..."
	echo ""
	echo "################################################################################"
	echo "-> Please restart the migration tool again after reboot to continue with phase 2"
	echo "################################################################################"
	sleep 5
	systemctl reboot || reboot
}

disclaimer() {
	cat <<'TXT'

================================================================================
 The Rocky Linux project does not document in-place major-version upgrades;
 a fresh installation is the officially described way to move between major
 releases. You must have working backups or snapshots.
 Test on non-production systems before relying on it in production.
================================================================================

TXT
}

warn_ipa_sssd_bootstrap_access() {
	cat <<'WTXT'

================================================================================
 FreeIPA / AD / SSSD
================================================================================
 If this host uses FreeIPA, Active Directory, or SSSD for logins, SSH with
 domain accounts may fail after the bootstrap step until distro-sync completes.
 Before continuing, ensure you have:
   - console / hypervisor access (in case something goes wrong) and
   - a local (non-SSSD) account with sudo permissions
================================================================================

WTXT
}

post_distro_sync_sssd_helpers() {
	log "Post-distro-sync: Executing SSSD restart (if installed)"
	if systemctl cat sssd.service &>/dev/null; then
		systemctl try-restart sssd.service 2>/dev/null || warn "systemctl try-restart sssd.service failed"
		log "Ran: systemctl try-restart sssd.service"
	else
		log "sssd.service not present; skipping try-restart"
	fi
}

run_phase1_upgrade() {
	disclaimer

	if [[ -f "$BOOTSTRAP_RESUME_FILE" ]] && grep -qx post-bootstrap "$BOOTSTRAP_RESUME_FILE" 2>/dev/null; then
		log "=== Resuming after bootstrap reboot (distro-sync) ==="
		rpm -q rocky-release &>/dev/null || die "Missing rocky-release; cannot resume"
		apply_rpmnew_repos
		ensure_rocky10_repos_enabled
		run_distro_sync
		post_distro_sync_sssd_helpers
		rm -f "$BOOTSTRAP_RESUME_FILE"
		post_sync_maintenance
		write_marker_and_reboot
		return 0
	fi

	log "=== Rocky Linux 9 -> Rocky Linux 10 upgrade started ==="

	check_minimal_commands
	prompt_backup
	install_packages_if_needed
	log "Verifying required commands are available"
	check_required_commands
	log "Required commands OK"

	ssh_warning
	check_cpu_isa_x86_v3
	check_disk_space
	check_root_fs_type
	check_network_scripts
	check_dracut_network_legacy

	run_full_upgrade_refresh
	run_dnf_check
	backup_and_sanitize_repos

	warn_ipa_sssd_bootstrap_access

	local dl_dir
	dl_dir=$(mktemp -d /tmp/rocky10-rpms.XXXXXX)
	log "Downloading Rocky Linux 10 release RPMs to $dl_dir"
	(
		cd "$dl_dir"
		dnf "${DNF_EXTRA_OPTS[@]}" download --releasever=10 -y rocky-release rocky-repos rocky-gpg-keys
	) || die "dnf download failed for Rocky 10 release RPMs"
	install_el10_release_rpms "$dl_dir"
	rm -rf "$dl_dir"

	if command_exists ldconfig; then
		log "Running ldconfig after release install"
		ldconfig || warn "ldconfig exited non-zero"
	fi

	if ! dnf_cli_works || glib_modulemd_skew_detected; then
		log "dnf not usable after release install and/or glib2/libmodulemd el9+el10 skew; attempting GLib/libmodulemd repair (rpm+curl from BaseOS Packages/g/)"
		repair_dnf_glib_modulemd_stack || true
	fi
	if ! dnf_cli_works; then
		log "dnf still not usable after repair; writing resume file."
		printf '%s\n' post-bootstrap >"$BOOTSTRAP_RESUME_FILE"
		log "Wrote $BOOTSTRAP_RESUME_FILE"
		if [[ "$FORCE_BOOTSTRAP_REBOOT" -eq 1 ]]; then
			log "Rebooting (--force-reboot); run this script again as root after boot."
			sleep 5
			systemctl reboot || reboot
			exit 0
		fi
		die "dnf still broken after bootstrap. From BaseOS Packages/g/, install EL10 gobject-introspection + glib2 in one: rpm -Uvh --nosignature *.rpm (see log). If sudo/SSH user lookup fails, use hardware/iLO console as root (broken nss/sssd)."
	fi

	log "dnf responds after bootstrap; continuing without intermediate reboot."
	apply_rpmnew_repos
	ensure_rocky10_repos_enabled
	run_distro_sync
	post_distro_sync_sssd_helpers
	post_sync_maintenance
	write_marker_and_reboot
}

apply_phase2_preflight_parked_repos() {
	local line pair orig parked
	[[ -f "$PREFLIGHT_FILE" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == \#* || -z "$line" ]] && continue
		case "$line" in
			PARKED=*)
				pair=${line#PARKED=}
				orig=${pair%%|*}
				parked=${pair#*|}
				if [[ -f "/etc/yum.repos.d/$parked" && ! -f "/etc/yum.repos.d/$orig" ]]; then
					mv "/etc/yum.repos.d/$parked" "/etc/yum.repos.d/$orig" && log "Un-parked repo file: /etc/yum.repos.d/$orig"
				elif [[ -f "/etc/yum.repos.d/$orig" ]]; then
					log "Repo already active: $orig"
				else
					warn "Could not un-park $orig (expected /etc/yum.repos.d/$parked)"
				fi
				;;
		esac
	done <"$PREFLIGHT_FILE"
}

install_epel_if_preflight() {
	local want
	[[ -f "$PREFLIGHT_FILE" ]] || return 0
	want=$(grep '^EPEL_WAS_INSTALLED=' "$PREFLIGHT_FILE" | head -1 | cut -d= -f2)
	if [[ "$want" != "1" ]]; then
		return 0
	fi
	if rpm -q epel-release &>/dev/null; then
		log "epel-release already installed."
		return 0
	fi
	log "Preflight: installing epel-release (was installed before upgrade)"
	dnf "${DNF_EXTRA_OPTS[@]}" install -y epel-release </dev/null || warn "dnf install epel-release failed"
}

run_phase2_cleanup() {
	log "=== Post-upgrade cleanup (Rocky 10) ==="

	if [[ "${ROCKY10_PHASE2_REMOVE_EL9_KERNELS:-}" == "1" ]]; then
		PHASE2_REMOVE_EL9_KERNELS=1
	fi

	local id ver
	id=$(os_get ID)
	ver=$(os_get VERSION_ID)
	[[ "$id" == "rocky" ]] || die "Not Rocky Linux (ID=$id)"
	[[ "${ver%%.*}" == "10" ]] || die "Phase 2 expects Rocky Linux 10 (VERSION_ID=$ver)"

	if [[ "$PHASE2" -eq 0 && ! -f "$MARKER_FILE" ]]; then
		log "No marker $MARKER_FILE and --phase2 not passed."
		log "If you finished a 9->10 upgrade, run: $0 --phase2"
		exit 0
	fi

	[[ -f "$MARKER_FILE" ]] && rm -f "$MARKER_FILE" && log "Removed marker $MARKER_FILE"

	if [[ -f "$PREFLIGHT_FILE" ]]; then
		log "Applying repo preflight from $PREFLIGHT_FILE"
		apply_phase2_preflight_parked_repos
	else
		log "No $PREFLIGHT_FILE (optional; skipping parked-repo restore)"
	fi

	dnf "${DNF_EXTRA_OPTS[@]}" config-manager --set-enabled crb 2>/dev/null || true
	log "Attempted to enable CRB (if present)."
	if command_exists crb; then
		crb enable 2>/dev/null || true
		log "Attempted: crb enable (if available)"
	fi

	install_epel_if_preflight
	if ! rpm -q epel-release &>/dev/null; then
		log "EPEL not installed. To add: dnf install -y epel-release"
	fi

	log "Running: dnf upgrade -y --allowerasing (resolves many Rocky 9 -> Rocky 10 leftovers)"
	dnf "${DNF_EXTRA_OPTS[@]}" upgrade -y --allowerasing || warn "dnf upgrade had issues"

	log "Checking unsatisfied dependencies:"
	dnf repoquery --unsatisfied 2>/dev/null || true

	log "Packages still showing Rocky 9 in name (review manually; some need third-party repos or dnf swap):"
	rpm -qa | grep -E 'el9|\.el9' || log "(none matched el9 pattern)"

	log "Old EL9 kernels (remove only after new Rocky 10 kernel boots successfully):"
	rpm -qa 'kernel*' | grep el9 || log "(no el9 kernels listed)"

	if [[ "$PHASE2_REMOVE_EL9_KERNELS" -eq 1 ]]; then
		echo "################################################################################"
		log "Removing Rocky 9 kernel packages (--remove-el9-kernels)"
		dnf "${DNF_EXTRA_OPTS[@]}" remove -y 'kernel-*el9*' </dev/null || warn "dnf remove kernel-*el9* had issues"
	else
		echo "################################################################################"
		log "To remove Rocky 9 kernels after verifying Rocky 10 boot: $0 --phase2 --remove-el9-kernels"
	fi
    log "Clearing SELinux log to avoid showing old Rocky 9 issues on new Rocky 10"
    truncate -s 0 /var/log/audit/audit.log

	local backup_hint
	backup_hint=$(grep '^BACKUP_DIR=' "$PREFLIGHT_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
	cat <<EOF

Final steps (after reboot):
  - Review old and new repo definitions from /etc/yum.repos.d. The original repo definitions were
    stored as a backup under: ${backup_hint:-not automatically detected; look under /root/yum.repos.d.backup-*}
  - Review / cleanup your system with --audit packages | deps | errors | selinux

EOF
	log "=== Migration to Rocky Linux 10 completed ==="
	reboot
}

# Main entry point
ORIGINAL_ARGC=$#
parse_args "$@"

if [[ "$AUDIT_ARGS_INVALID" -eq 1 ]]; then
	exit 1
fi

if [[ "$WANT_VERSION" -eq 1 ]]; then
	print_cli_version
	exit 0
fi

if [[ "${ROCKY10_AUDIT_REMOVE_EL9_RPMS:-}" == "1" ]]; then
	REMOVE_EL9_RPMS=1
fi

if [[ "$REMOVE_EL9_RPMS" -eq 1 ]]; then
	if [[ "$AUDIT_MODE" != "deps" ]]; then
		warn "--remove-el9-rpms (or ROCKY10_AUDIT_REMOVE_EL9_RPMS=1) requires --audit deps"
		exit 1
	fi
	if [[ ! -f /etc/os-release ]]; then
		die "Missing /etc/os-release; cannot verify Rocky Linux 10 for --remove-el9-rpms"
	fi
	_r10_id=$(os_get ID)
	_r10_ver=$(os_get VERSION_ID)
	if [[ "$_r10_id" != "rocky" ]] || [[ "${_r10_ver%%.*}" != "10" ]]; then
		die "--remove-el9-rpms is only supported on Rocky Linux 10 (post-upgrade). Detected: ${_r10_id:-?} ${_r10_ver:-?}"
	fi
fi

if [[ -n "$AUDIT_MODE" ]]; then
	if [[ "$AUDIT_MODE" == "deps" ]] && [[ "$REMOVE_EL9_RPMS" -eq 1 ]]; then
		[[ $EUID -eq 0 ]] || die "Run as root for --audit deps --remove-el9-rpms"
	fi
	run_audit "$AUDIT_MODE"
	exit $?
fi

if [[ "$PHASE2" -eq 1 ]]; then
	[[ $EUID -eq 0 ]] || die "Run as root (phase 2)"
	ensure_log
	exec >> >(tee -a "$LOG_FILE") 2>&1 || true
	run_phase2_cleanup
	exit 0
fi

if [[ -f "$BOOTSTRAP_RESUME_FILE" ]] && grep -qx post-bootstrap "$BOOTSTRAP_RESUME_FILE" 2>/dev/null; then
	[[ $EUID -eq 0 ]] || die "Run as root"
	ensure_log
	exec >> >(tee -a "$LOG_FILE") 2>&1 || true
	run_phase1_upgrade
	exit 0
fi

_id=""
_ver=""
if [[ -f /etc/os-release ]]; then
	_id=$(os_get ID)
	_ver=$(os_get VERSION_ID)
fi

if [[ "$_id" == "rocky" && "${_ver%%.*}" == "10" ]] && [[ -f "$MARKER_FILE" ]]; then
	[[ $EUID -eq 0 ]] || die "Run as root"
	ensure_log
	exec >> >(tee -a "$LOG_FILE") 2>&1 || true
	run_phase2_cleanup
	exit 0
fi

if [[ "$_id" == "rocky" && "${_ver%%.*}" == "10" ]]; then
	if [[ "$CLI_NEED_HELP" -eq 1 ]]; then
		print_cli_help
		exit 1
	fi
	if [[ "$DO_UPGRADE" -eq 1 ]]; then
		warn "This system is already Rocky Linux ${_ver:-10}. Phase 1 applies only to Rocky Linux 9. Use --phase2 or --audit."
		print_cli_help
		exit 1
	fi
	print_cli_help
	exit 0
fi

if [[ "$_id" == "rocky" && "${_ver%%.*}" == "9" ]]; then
	if [[ "$CLI_NEED_HELP" -eq 1 ]]; then
		print_cli_help
		exit 1
	fi
	if [[ "$DO_UPGRADE" -eq 0 ]]; then
		print_cli_help
		exit 0
	fi
fi

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -f /etc/os-release ]] || die "Missing /etc/os-release"

_id=$(os_get ID)
_ver=$(os_get VERSION_ID)
[[ "$_id" == "rocky" ]] || die "This script is for Rocky Linux only (ID=$_id)"
[[ "${_ver%%.*}" == "9" ]] || die "This phase requires Rocky Linux 9 (VERSION_ID=$_ver); see --help"

ensure_log
exec >> >(tee -a "$LOG_FILE") 2>&1

run_phase1_upgrade
