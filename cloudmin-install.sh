#!/bin/sh
# Copyright 2005-2026 Cloudmin
# Copyright 2005-2026 The Webmin Developers
# Install Cloudmin on a supported Linux host.
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2059,SC2016

# Single-quoted run_ok commands expand their variables when executed.

# Default to GPL unless the script or environment supplies Pro credentials.
SERIAL="${SERIAL:-GPL}"
KEY="${KEY:-GPL}"
VER=10.0.0-RC1

# Share saved credentials with the repository helper and License Manager.
cloudmin_license_file="/etc/cloudmin-license"

# Hide branch help and warnings during development; set to 0 to show them.
# Removing this declaration also restores the normal branch help and warning.
CLOUDMIN_DEVELOPMENT="${CLOUDMIN_DEVELOPMENT:-1}"

# Download servers can be overridden through the environment.
# Cloudmin currently publishes only the unstable channel.
download_cloudmin_host="${download_cloudmin_host:-download.cloudmin.dev}"
download_cloudmin_host_lib="$download_cloudmin_host"
download_cloudmin_host_dev="${download_cloudmin_host_dev:-$download_cloudmin_host}"
download_webmin_host="${download_webmin_host:-download.webmin.com}"
download_webmin_host_dev="${download_webmin_host_dev:-download.webmin.dev}"

# usage() Lists installation options and standalone operations.
usage() {
  # Show defaults before the grouped option reference.
  # shellcheck disable=SC2046
  echo
  printf "Usage: %s [options]\\n" "$(basename "$0")"
  echo
  echo "  Without options, installs Cloudmin with the default settings."
  echo
  printf "  --bundle|-b <KVM>                bundle to install (default: KVM)\\n"
  # Development builds use the unstable channel without advertising a switch.
  if [ "${CLOUDMIN_DEVELOPMENT:-0}" != 1 ]; then
    printf "  --branch|-B <unstable>           repository branch (default: unstable)\\n"
  fi
  echo
  # Packages and plugins extend or narrow the selected bundle.
  printf "  --extra|-E <name[,name..]>       install extra packages with the stack\\n"
  printf "  --exclude|-e <name[,name..]>     skip selected configuration plugins\\n"
  printf "  --include|-i <name[,name..]>     run additional configuration plugins\\n"
  printf "  --module|-o <name>               load local <name>.sh before configuration\\n"
  echo
  # Hostname and update controls apply to full installation.
  printf "  --hostname|-n <name>             set the host name during installation\\n"
  printf "  --no-package-updates|-x          skip package updates during install\\n"
  echo
  # Swap can run alone, accompany installation, or be left unchanged.
  printf "  --swap|-S <size>                 managed swap: MiB or K/M/G[B]; 0 to remove\\n"
  printf "  --swap-only                      configure swap without installing\\n"
  printf "  --no-swap|-ns                    leave system swap unchanged\\n"
  echo
  # Standalone operations do not run the full installation flow.
  printf "  --uninstall|-u                   remove Cloudmin packages and repositories\\n"
  printf "  --setup|-s                       configure repositories and prerequisites\\n"
  printf "  --connect|-C [ipv4|ipv6]         test connectivity (default: both)\\n"
  printf "  --insecure-downloads|-I          skip certificate checks for installer downloads\\n"
  echo
  printf "  --log-dir <directory>            directory for installer logs\\n"
  echo
  # Prompt, reinstall and display controls are independent choices.
  printf "  --force|-f|--yes|-y              assume \"yes\" to all prompts\\n"
  printf "  --force-reinstall|-fr            allow reinstallation (not recommended)\\n"
  printf "  --no-banner|-nb                  skip the installation banner and warnings\\n"
  printf "  --verbose|-V                     show debug output\\n"
  echo
  # Help and version requests exit before host checks.
  printf "  --version|-v                     show installer version\\n"
  printf "  --help|-h                        show this help\\n"
  echo
}

# log_error(message) Reports errors until slib replaces this logger.
log_error() {
  # Add color only when stderr is a terminal and terminal output is enabled.
  if [ -t 2 ] && [ "${INTERACTIVE_MODE:-}" != off ] && command -v tput >/dev/null 2>&1; then
    printf '%s[ERROR]%s %s\n' "$(tput setaf 1 2>/dev/null)" "$(tput sgr0 2>/dev/null)" "$1" >&2
  else
    # Keep redirected errors readable before the shared logger is available.
    printf '[ERROR] %s\n' "$1" >&2
  fi
}

# fatal(message, [words...]) Reports an error and exits with status 1.
fatal() {
  log_error "$*"
  exit 1
}

# bind_hook(name, [args...]) Calls an override, or pre/original/post hooks.
bind_hook() {
  hook="$1"
  shift
  # A full override replaces the original function and both surrounding hooks.
  if command -v "hook__$hook" >/dev/null 2>&1; then
    "hook__$hook" "$@"
  else
    # Expand all names before dispatch so nested hooks keep the outer post-hook.
    for hook in "pre_hook__$hook" "$hook" "post_hook__$hook"; do
      # Missing lifecycle hooks are optional; failures stop this dispatch.
      if command -v "$hook" >/dev/null 2>&1; then
        "$hook" "$@" || return $?
      fi
    done
    return 0
  fi
}

# swap_size(value) Sets swapsize in KiB, rounding up to whole MiB.
# Bare numbers mean MiB; K/M/G and optional B suffixes are case-insensitive.
swap_size() {
  # Separate the leading digits from the unit before doing arithmetic.
  swap_arg=$1
  swap_num=${swap_arg%%[!0-9]*}
  swap_suffix=${swap_arg#"$swap_num"}
  case "$swap_suffix" in
    [Kk]|[Kk][Bb]) swap_mult=1 ;;
    [Mm]|[Mm][Bb]|'') swap_mult=1024 ;;
    [Gg]|[Gg][Bb]) swap_mult=1048576 ;;
    *) fatal "Invalid swap size: $swap_arg" ;;
  esac
  # Remove leading zeros so shell arithmetic cannot interpret an octal value.
  swap_num=${swap_num#"${swap_num%%[!0]*}"}
  # Require digits and reject values too long for the bounded calculation.
  if [ -z "${swap_arg%%[!0-9]*}" ] || [ "${#swap_num}" -gt 10 ]; then
    fatal "Invalid swap size: $swap_arg"
  fi
  # Retain zero for removal, bound the size, then round up to whole MiB.
  swap_num=${swap_num:-0}
  [ "$swap_num" -le $((1073740800 / swap_mult)) ] || fatal "Invalid swap size: $swap_arg"
  swapsize=$(((swap_num * swap_mult + 1023) / 1024 * 1024))
}

# require_value(option, [value]) Rejects missing option values.
require_value() {
  [ -n "${2:-}" ] || fatal "$1 requires a value"
  case "$2" in -*) fatal "$1 requires a value" ;; esac
}

# add_extra_packages(names) Adds comma-separated package names as quoted tokens.
add_extra_packages() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9+_.-]*(,[a-zA-Z0-9][a-zA-Z0-9+_.-]*)*$' ||
    fatal 'Invalid extra package list'
  # Quote each validated name for the command string later evaluated by run_ok.
  old_ifs=$IFS
  IFS=,
  for p in $1; do
    extra_packages="${extra_packages}${extra_packages:+ }'$p'"
  done
  IFS=$old_ifs
}

# add_config_excludes(names) Adds comma-separated plugins to the exclude list.
add_config_excludes() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Za-z][A-Za-z0-9]*(,[A-Za-z][A-Za-z0-9]*)*$' ||
    fatal 'Invalid configuration plugin list'
  # Expand the validated list into separate options for cloudmin-config-system.
  old_ifs=$IFS
  IFS=,
  for x in $1; do
    config_excludes="${config_excludes} --exclude $x"
  done
  IFS=$old_ifs
}

# add_config_includes(names) Adds comma-separated plugins to the include list.
add_config_includes() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Za-z][A-Za-z0-9]*(,[A-Za-z][A-Za-z0-9]*)*$' ||
    fatal 'Invalid configuration plugin list'
  # Expand the validated list into separate options for cloudmin-config-system.
  old_ifs=$IFS
  IFS=,
  for x in $1; do
    config_includes="${config_includes} --include $x"
  done
  IFS=$old_ifs
}

# parse_args([args...]) Sets defaults and validates command-line options.
parse_args() {
  # Reset modes and option lists before parsing the arguments.
  branch=unstable; setup_only=; swap_only=; noswap=; swapsize=; skipyesno=0
  forcehostname=; noupdates=; extra_packages=; config_includes=; config_excludes=; VERBOSE=0
  forcereinstall=; skipbanner=; module_name=; insecure_downloads=; connect=; uninstall_mode=
  bundle=KVM; showversion=
  log_dir=/root
  # Consume each option once; value-taking options also consume the next word.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) bind_hook usage; exit 0 ;;
      --version|-v) showversion=1; shift ;;
      # Validate required values before assigning them or expanding lists.
      --branch|-B|--hostname|-n|--extra|-E|--include|-i|--exclude|-e|--log-dir|--swap|-S|--module|-o|--bundle|-b)
        require_value "$1" "${2:-}"
        case "$1" in
          --branch|-B) branch=$2 ;;
          --hostname|-n) forcehostname=$2 ;;
          --extra|-E) add_extra_packages "$2" ;;
          --include|-i) add_config_includes "$2" ;;
          --exclude|-e) add_config_excludes "$2" ;;
          --log-dir) log_dir=$2 ;;
          --swap|-S) swap_size "$2" ;;
          --module|-o) module_name=$2 ;;
          --bundle|-b) bundle=$2 ;;
        esac
        shift 2 ;;
      # Collect flags here; check for conflicting options below.
      --setup|-s) setup_only=1; shift ;;
      --swap-only) swap_only=1; shift ;;
      --no-swap|-ns) noswap=1; shift ;;
      --yes|-y|--force|-f) skipyesno=1; shift ;;
      --no-package-updates|-x) noupdates=1; shift ;;
      --verbose|-V) VERBOSE=1; shift ;;
      --force-reinstall|-fr) forcereinstall=1; shift ;;
      --no-banner|-nb) skipbanner=1; shift ;;
      --insecure-downloads|-I) insecure_downloads=1; shift ;;
      --uninstall|-u) uninstall_mode=1; shift ;;
      # Without an explicit family, test both IPv4 and IPv6.
      --connect|-C)
        connect='ipv4 ipv6'; shift
        case "${1:-}" in
          ipv4|ipv6) connect=$1; shift ;;
          ''|-*) ;;
          *) fatal "Invalid protocol: $1" ;;
        esac ;;
      *) fatal "Unknown option: $1" ;;
    esac
  done
  # Map development aliases to the only published branch.
  case "$branch" in testing|development|devel|dev|nightly|bleeding-edge|cutting-edge) branch=unstable ;; esac
  [ "$branch" = unstable ] || fatal 'Only the unstable repository is available'
  [ "$bundle" = KVM ] || fatal "Unknown bundle: $bundle"
  # Modules are local script names, not paths or shell expressions.
  case "$module_name" in *[!A-Za-z0-9_.-]*|.*) fatal 'Invalid module name' ;; esac
  # Standalone uninstall and connectivity checks cannot perform install actions.
  [ -z "$uninstall_mode" ] || [ -z "$setup_only$swap_only$swapsize$noswap$connect$forcehostname$extra_packages$config_includes$config_excludes$module_name" ] ||
    fatal '--uninstall cannot be combined with setup, swap or installation options'
  [ -z "$connect" ] || [ -z "$setup_only$swap_only$swapsize$noswap$uninstall_mode$forcehostname$extra_packages$config_includes$config_excludes$module_name" ] ||
    fatal '--connect cannot be combined with setup, swap or installation options'
  # Reject swap and installation options that conflict with the chosen mode.
  [ -z "$noswap" ] || [ -z "$swapsize" ] || fatal '--swap and --no-swap cannot be used together'
  [ -z "$setup_only" ] || [ -z "$swap_only$swapsize" ] || fatal '--setup cannot be combined with swap changes'
  [ -z "$setup_only" ] || [ -z "$forcehostname$extra_packages$config_includes$config_excludes$noupdates$module_name" ] ||
    fatal '--setup cannot be combined with installation options'
  [ -z "$swap_only" ] || [ -z "$forcehostname$extra_packages$config_includes$config_excludes$noupdates$module_name" ] ||
    fatal '--swap-only cannot be combined with installation options'
  # Absolute paths keep logs accessible after changing directories.
  case "$log_dir" in /*) ;; *) fatal '--log-dir must be an absolute path' ;; esac
  # Validate a requested host name before passing it to hostnamectl.
  if [ -n "$forcehostname" ]; then
    printf '%s\n' "$forcehostname" | LC_ALL=C grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$' ||
      fatal 'Provide a fully qualified host name'
  fi
  # Select the utility library from the same branch as the Cloudmin packages.
  if [ "$branch" = unstable ]; then
    download_cloudmin_host_lib="$download_cloudmin_host_dev"
  fi
}

# show_version() Prints the installer version.
show_version() {
  printf '%s\n' "$VER"
}

# supported_host(id, version, architecture) Tests the supported OS matrix.
# Use os-release ID and VERSION_ID, and the architecture reported by uname -m.
supported_host() {
  case "$1:$3" in
    rocky:x86_64|rocky:aarch64|almalinux:x86_64|almalinux:aarch64)
      printf '%s\n' "$2" | LC_ALL=C grep -Eq '^10([.][0-9]+)*$' ;;
    debian:x86_64|debian:aarch64)
      printf '%s\n' "$2" | LC_ALL=C grep -Eq '^13([.][0-9]+)*$' ;;
    ubuntu:x86_64|ubuntu:aarch64) [ "$2" = 26.04 ] ;;
    *) return 1 ;;
  esac
}

# pre_check_all() Checks host requirements for the selected operation.
pre_check_all() {
  # Every operation reaching preflight needs Linux and root privileges.
  [ "$(uname -s)" = Linux ] || fatal 'Run this installer on a Linux host'
  [ "$(id -u)" = 0 ] || fatal 'Run this installer as root'
  # Standalone swap management does not configure a Cloudmin host.
  [ -z "$swap_only" ] || return 0
  # Repository and package operations require a supported OS and systemd.
  [ -r /etc/os-release ] || fatal 'Cannot determine the operating system'
  . /etc/os-release
  supported_host "${ID:-}" "${VERSION_ID:-}" "$(uname -m)" ||
    fatal 'Supported hosts: AlmaLinux 10, Rocky Linux 10, Debian 13 or Ubuntu 26.04 on x86_64 or aarch64'
  [ -d /run/systemd/system ] || fatal 'A running systemd host is required'
  [ -n "$setup_only$uninstall_mode" ] || [ -c /dev/kvm ] || fatal 'KVM is unavailable; enable hardware or nested virtualization'
  # Require an explicit reinstall flag when the module is already configured.
  if [ -z "$setup_only$uninstall_mode$forcereinstall" ] && is_installed; then
    bind_hook already_installed_block
    return 1
  fi
  # Select the native package manager and suppress Debian package prompts.
  case "$ID" in
    debian|ubuntu) manager=apt-get; export DEBIAN_FRONTEND=noninteractive ;;
    *) manager=dnf ;;
  esac
  command -v "$manager" >/dev/null 2>&1 || fatal "$manager is required"
}

# finish() Restores the terminal and removes this run's workspace on exit.
# Preserve the exit status that triggered the trap.
finish() {
  result=$?
  trap - EXIT HUP INT TERM QUIT
  # Undo spinner and prompt terminal changes when slib enabled them.
  if [ "${INTERACTIVE_MODE:-off}" != off ]; then
    stty echo 2>/dev/null || :
    for pid in $allpids; do kill "$pid" 2>/dev/null || :; done
    tput cnorm 2>/dev/null || :
    tput sgr0 2>/dev/null || :
  fi
  # Remove the workspace if main() has not already cleaned it up.
  [ -z "${CLOUDMIN_INSTALL_TEMPDIR:-}" ] || rm -rf -- "$CLOUDMIN_INSTALL_TEMPDIR"
  exit "$result"
}

# download_content(url) Writes an HTTPS response to stdout.
download_content() {
  # Prefer curl and restrict both the request and redirects to HTTPS.
  if command -v curl >/dev/null 2>&1; then
    curl -q ${insecure_downloads:+--insecure} --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 20 --max-time 300 "$1" 2>>"$log"
  elif command -v wget >/dev/null 2>&1; then
    # Use wget when curl is absent, with bounded retries and HTTPS only.
    wget ${insecure_downloads:+--no-check-certificate} --https-only --timeout=30 --tries=2 -q -O - "$1" 2>>"$log"
  else
    # Standalone swap can use a local slib.sh without downloading anything.
    log_error 'Install curl or wget, or place slib.sh beside the installer for --swap-only'
    return 1
  fi
}

# goto_tmpdir() Keeps library probes and progress files in this run's workspace.
goto_tmpdir() {
  cd "$CLOUDMIN_INSTALL_TEMPDIR" || fatal 'Cannot enter temporary directory'
}

# download_slib() Loads logging, prompts, progress and swap helpers.
download_slib() {
  # Prefer a trusted library supplied beside the installer.
  if [ -f "$script_dir/slib.sh" ]; then
    library="$script_dir/slib.sh"
  else
    # Otherwise fetch the library from the selected download branch.
    library="$CLOUDMIN_INSTALL_TEMPDIR/slib.sh"
    download_content "https://$download_cloudmin_host_lib/slib.sh" > "$library" ||
      fatal 'Failed to download the utility library'
  fi
  # Provide a fallback TERM for the shared terminal capability checks.
  TERM=${TERM:-dumb}; export TERM
  # slib writes terminal probes and spinner state in the current directory.
  goto_tmpdir
  . "$library"
  # Send logger and command output to one log; callers handle command failures.
  LOG_PATH=$log; RUN_LOG=$log; LOG_LEVEL_LOG=DEBUG
  RUN_ERRORS_FATAL=
  SPINNER_DONEFILE="$CLOUDMIN_INSTALL_TEMPDIR/stopspinning"
  LOG_LEVEL_STDOUT=INFO
  [ "$VERBOSE" != 1 ] || LOG_LEVEL_STDOUT=DEBUG
  # Replace slib traps to clean up both the terminal and our workspace.
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  trap 'exit 131' QUIT
  # Require the managed-swap API only when this run may change swap.
  if [ -z "$noswap$setup_only$uninstall_mode" ] && [ "${SLIB_SWAP_API:-0}" != 2 ]; then
    fatal 'This version of slib.sh does not support swap management. Update slib.sh.'
  fi
}

# swap_abort() Stops installation after swap planning or setup fails.
swap_abort() {
  # Full installations can be retried with swap changes explicitly disabled.
  if [ -z "$swap_only" ]; then
    log_error "Re-run the installer with --no-swap${swapsize:+ instead of --swap} to skip swap setup."
  fi
  exit 1
}

# confirm(prompt) Returns success for --yes or an accepted yes/no prompt.
confirm() {
  # Unattended callers must opt into confirmation instead of waiting on stdin.
  [ "$skipyesno" = 1 ] && return 0
  [ -t 0 ] || fatal 'Use --yes for unattended installation'
  printf '%s' "$1"
  yesno
  # The prompt may disable echo; restore it without losing the answer status.
  confirm_result=$?
  stty echo 2>/dev/null || :
  return "$confirm_result"
}

# preconfigure_cloudmin_release() Prepares the distribution's package manager.
preconfigure_cloudmin_release() {
  # APT keeps existing configuration and installs only required dependencies.
  if [ "$manager" = apt-get ]; then
    package_type=deb
    install="apt-get --quiet --assume-yes --no-install-recommends -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' install"
    upgrade="${install% install} upgrade"
    run_ok 'apt-get update' 'Refreshing distribution metadata' || return $?
    run_ok "$install ca-certificates curl gnupg" 'Installing repository prerequisites' || return $?
    # Ubuntu provides required virtualization bindings through universe.
    if [ "$ID" = ubuntu ]; then
      run_ok "$install software-properties-common" 'Installing repository tools' || return $?
      run_ok 'add-apt-repository -y universe' 'Enabling Ubuntu universe' || return $?
    fi
  else
    # DNF must fail on missing packages and omit optional weak dependencies.
    package_type=rpm
    install_cmd=dnf
    install="$install_cmd -y --setopt=strict=1 --setopt=install_weak_deps=False --setopt=optional_metadata_types=filelists install"
    upgrade="$install_cmd -y upgrade"
    # Existing curl-minimal is sufficient; do not force replacement with curl.
    if ! command -v curl >/dev/null 2>&1; then
      run_ok "$install curl" 'Installing the repository HTTP client' || return $?
    fi
    # CRB and EPEL supply additional host and Perl dependencies on EL systems.
    run_ok "$install ca-certificates dnf-plugins-core" 'Installing repository prerequisites' || return $?
    run_ok "$install_cmd config-manager --set-enabled crb" 'Enabling CRB' || return $?
    run_ok "$install epel-release" 'Installing EPEL configuration' || return $?
  fi
}

# manage_cloudmin_branch_repos() Configures the selected branch and edition.
manage_cloudmin_branch_repos() {
  bootstrap="$CLOUDMIN_INSTALL_TEMPDIR/install"
  download_content "https://$download_cloudmin_host_lib/install" > "$bootstrap" || return $?
  # Preserve download host overrides when the helper starts a new shell.
  export download_cloudmin_host_dev download_webmin_host download_webmin_host_dev
  run_ok 'sh "$bootstrap" webmin "$branch"' 'Configuring Webmin repository' || return $?
  run_ok 'sh "$bootstrap" cloudmin "$branch"' 'Configuring Cloudmin repository' || return $?
  # Refresh APT indexes after configuring both repositories.
  if [ "$package_type" = deb ]; then
    run_ok 'apt-get update' 'Refreshing package metadata' || return $?
  else
    # Force DNF to load metadata from the newly configured repositories.
    run_ok "$install_cmd -y makecache --refresh" 'Refreshing package metadata' || return $?
  fi
}

# phase(description, number) Shows progress within phases_total (default: 4).
phase() {
    phases_total="${phases_total:-4}"
    phase_description="$1"
    phase_number="$2"
    # Show completed phases before the current phase marker.
    printf "${GREEN}"
    for i in $(seq 1 $(( phase_number - 1 ))); do
        printf "▣"
    done
    # Distinguish the active phase from completed and pending work.
    printf "${YELLOW}▣"
    # Keep pending phases visible until the final phase is reached.
    for i in $(seq $(( phase_number + 1 )) "$phases_total"); do
        printf "${CYAN}◻"
    done
    log_debug "Phase ${phase_number} of ${phases_total}: ${phase_description}"
    printf "${NORMAL} Phase ${YELLOW}${phase_number}${NORMAL} of ${GREEN}${phases_total}${NORMAL}: ${phase_description}\\n"
}

# install_logo() Draws an inline logo beside the welcome text.
# Return 1 without output when the text banner should be used alone.
install_logo() (
  # Keep images out of logs, unattended runs, and plain-output sessions.
  [ -t 1 ] && [ "${INTERACTIVE_MODE:-}" != off ] &&
    [ "${NONINTERACTIVE:-0}" != 1 ] && [ -z "${NO_COLOR:-}" ] || return 1
  [ -z "${TMUX:-}${STY:-}${ZELLIJ:-}" ] || return 1
  case "${TERM:-}:${OLDTERM:-}" in
    :*|dumb:*|linux:*|screen*|tmux*|*:screen*|*:tmux*) return 1 ;;
  esac

  # slib may replace TERM when the server lacks the client's terminfo entry.
  # Use known protocols without probing or consuming answers to later prompts.
  case "${TERM_PROGRAM:-}:${OLDTERM:-${TERM:-}}" in
    kitty:*|ghostty:*|*:xterm-kitty|*:xterm-ghostty) logo_protocol=kitty ;;
    iTerm.app:*) logo_protocol=iterm ;;
    *) return 1 ;;
  esac

  # Reserve two columns for a round, line-height icon and one for the gap.
  # Preserve stdout's terminal, even when it is open only for writing.
  # stty queries the device through fd 0 without reading input bytes.
  { logo_size=$(stty size 0>&3 2>/dev/null); } 3>&1 || return 1
  logo_rows=${logo_size% *}
  logo_cols=${logo_size#* }
  case "$logo_cols:$logo_rows" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  logo_heading="     Welcome to the Cloudmin $PRODUCT installer, version $VER"
  [ "$logo_cols" -ge "${#logo_heading}" ] && [ "$logo_rows" -ge 16 ] || return 1

  # Reserve a row for iTerm2's cursor movement, then draw at the text margin.
  printf '\n\033[1A\033[3G\0337'
  # Transparent 64x64 PNG from authentic-theme-src/.art/Logos/svgs/cloudmin.svg,
  # rendered in Cloudmin orange with smooth edges and embedded locally.
  awk -v protocol="$logo_protocol" '
    { data = data $0 }
    END {
      if (protocol == "kitty") {
        # Set one row of height and let the width follow the image proportions.
        # The PNG fits in one 4096-byte chunk. Suppress replies and leave the
        # cursor in place for the welcome text.
        printf "\033_Ga=T,f=100,r=1,C=1,q=2;%s\033\\", data
      } else {
        # Use the same line-height sizing and proportions in iTerm2.
        printf "\033]1337;File=inline=1;width=auto;height=1;preserveAspectRatio=1:%s\007", data
      }
    }
  ' <<'CLOUDMIN_LOGO_PNG'
iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAABmJLR0QA/wD/AP+gvaeTAAAIMklE
QVR4nO2ae3BcVRnAf9+5u0m6ffNKsklaRRyhrThO2m4SWgba+qjTsTgKjjAMf1BQQAeKlVdNuCQo
IEjrMEABRawMjrQOD0eUqrQWms3WiVM6BBnQCjTdJA0lQEjTPPZ8/pFsmqa5d3ezm8IM+/tvz/ne
u/eec76zkCdPnjx5PrlILo113lJZ2u8ETzciYVVbKEjAOrQy6Oy3Pfbtig3R3lz6ywVZFSC+vmau
OIlvKeZ80GrgpBQqHQK7Qf+BkT+Uuk1vZuM/F2RcAHUxbbZ6NdjrQJZOxEbSlMALYDeU1O9+TkAn
aCcrMgr+gFu1QqxsBJ2f4zheQe3V4YbdL2aqqFdWBtvCgQjWLEV1IUI5MBvoQnhdlL8NdsuTXo9f
WgV498bKmUcKg/cDl2QaYAaoCr8RsfeXEtoj7o7B8YQOuZEZ/ZZKMAut6rkinAdMS2G7U1TWlTZE
N4+dSFmA1trFXzBingY+lUYSuSIBHAB5C/QIiiDMBOYCp2Vh98HS+qZrRj9uvgWI11V/BXQLMD0N
468J/FWR7dbI/yDxzgBT3pl2eCB4JGSLDZyGtZ8TZDmwmtTf2qQgcFdpfdNNoz6PT1td1UqFp4EC
H3sDoI9izMawG30t3SAOuudNS9i+qxR7C8isdPVyhIKsDNdHnwePAsRrFy9FzDagyMdQI0YuzyTx
sbS6kXJj5fdATXoa8iKqfYgWgFQhbFXlDQNzFL4NhIDXFX0GMSKqNR623+gy3Qvmuy39xxVg//rq
MsfRZqDYOw7uLX214gbZsiWRXuDe7F9bPcWZps8irEgla41WlLux1tabF59sCuWssBt7KTnX7kaq
bEJ+1OV0f2e+29KfHI/fWvVzlOuPS0HlstKG6GYzelBBHKOP45e86s3h25p+mIvkASo2RHtx9O5M
dMrv2H0o7MZeOuRGZiTHStxYU+lrFRfNa5mXGD3eJ0UNwOGxNlRYA3BMAdrqqtYwtKyMj3BvuCF2
ZybBpiJeV3UFVp6dgN49fVbej9dVb0yOtZ/RflLbWfvf7LPybtytORfg0+6O94B9x1vQmndvrJwZ
GFFed/ZUC7d7OVRoCkvRjb5BuZUhscHLFF0NMg90OsgHquwVeKbL6d6c/Hm2uPMLZuuM+1C9MtPk
h/nucGRfA64DsMGBZQLlAJqwVcBOAIEOhQVj9J3eguCCkQJoaMr38F5jE2rMVV6bExheMq0+olBx
9N0qALNEmAOsmm2n39BWu+gbA05BV9AObtWh80PGvPGDlYXQlVxGp4xMqExFNOn5aG5gxzUkekpg
WEDakKs8Pao8Ve427vGajtdWXwz6GBBMEftnVZydAWv7FClNIetJ4ORe8UgpIxxjEgGANjdyDpbP
eAmK2Ae85uLu4oVYfZTUySc56SM69xzHINI69BK08lUfuY6Sf8/ZOd6Egog1vwIKJyG+yaa3LN7X
knxOzvMRfMlryWt3IyvVcnbOQ/NArFwSr410ie0N6tE93NR4bWToRWrsOWhyXBeNjA+/GI9B9Xl5
uHkgWYDPezlVeMVzzsoFGeaQFQJ3IjL2AZqNyENDAY0WlgsAz/jE4REAc9BdVALM8BI0aKdPTEtS
Rv3xZFepG3sOwFiCp/iKqvgUQCf8Jv/o0Pccay5LfjIk7FRfcUffG3ccBMTzl/MxpR1lRfHtjf9N
Dhg/aQBJjH9cHW4qdOcwuMnkQxUesAN2Qbgh1jx6IoBjerA+uwrRU30MtwEzcxPjhBlUlZ1idI+i
HxqVQoUCBFVLh4i8HDCFu05zd3w4nnJA+hOdBLwbQ1Z8W1C7gDOzTGDiqGzFyrqynzS+NVETpvin
sQ7gfS8BUfFcIo2RpyfqOFsUbgo3RC8MZ5E8HH0HeK71wBK98EJnvIliN/onkJZsApgIKjxWVt90
Vy5sJQuww0fm1PhZby8bb0JAjerlwECGfj/IUH40rf1StDYL/WMwAKr82VdI5ftecyUNTTFRWQN4
HpXHsL2ob2AODO3EMkWMrh1ucuQEgaE1vb2u6nWFMzzkrFFqShqaYl6G4m7ky1jzIOjpPt4eD/Y6
V5/6s13dMHyMFn2INFvkqvJCWUN0eTqy6WKG4kJBN/nJWdFNQ42I8Qm7sW09XbPmoXIJ6O+Af4Ls
AxpBH1JlSfi2pkuTyQOEG6JPqHUWCuxNI9ZBx5Fr000sXUbWv7hbGcIG9+HfDf5l+LamK3IdxP61
1VMC0/XXw61tL+e/CNdHr8u175GdYNhtPozyY19pZc2BW6vv1hz/ryDo9Bj130+095lCN5c+kxyT
iIK01VX9HTg/hdYTpufwlSX37O3JNoD2dWdPtaHQH318qhhdlTy95ZpjzgICmkjIpUC7r5ZysYZC
ew7URb6UjfO4W32mhkKN+Bd802QlD15XY25kCVa2Mbrj6s12kPsS3fwl3b/AxNfXzMWx1wLX4H/3
+DJmoCbsNh93sZErUl2OPkX6/b4+lKiIvqDIPpB3VDkoqkdEzDScxFxrZYHAcobu61KdRLscaxaN
PrpOBulcjz+JT8dokugH+XryBncy8f0WwvXR5xNGlw6v5yeKw4pedCKShzQaIhVubG+hsV8E+e0J
iOfVhNHqsvrYMyfAF5Dhet7uLl6m1mxQct4KPyTIXSXt/Rvl4eZMD1ZZMaG/ycWpWiWW64FzJ2Jj
lPsWVB8NOEUPe3VsJpusdnQH1i+qEBP4poguU6gG/DvMcBDlXwrb1THb/O4bTxQ53dJ23BIpHnCc
040kwiBFihY4xnSS0M7BQfuf8jt2H8qlvzx58uTJkydPnjx58uTJk2di/B/5xwL0CfI4bQAAAABJ
RU5ErkJggg==
CLOUDMIN_LOGO_PNG
  # Start the welcome text on the same row, one space after the icon.
  printf '\0338\033[3C'
)

# install_msg() Shows host requirements, the swap plan and install confirmation.
install_msg() {
  # Keep the displayed OS matrix consistent with supported_host().
  supported="    ${CYANBG}${BLACK}${BOLD}Enterprise Linux and derivatives${NORMAL}${CYAN}
      - AlmaLinux 10 on x86_64 and aarch64
      - Rocky Linux 10 on x86_64 and aarch64${NORMAL}
    ${CYANBG}${BLACK}${BOLD}Debian Linux and derivatives${NORMAL}${CYAN}
      - Debian 13 on amd64 and arm64
      - Ubuntu 26.04 LTS on amd64 and arm64${NORMAL}"

  # Display the logo when the terminal supports inline images.
  printf '\n  '
  bind_hook install_logo || :
  cat <<EOF
Welcome to the ${ORANGE}${BOLD}Cloudmin $PRODUCT${NORMAL} installer, version ${ORANGE}${BOLD}$VER${NORMAL}

  Run this installer on a fresh, supported operating system. To update
  an existing installation, use your package manager. To change licenses,
  use System → Settings → License Manager in Cloudmin.

EOF
  # Show supported releases before the disk, swap and bundle summary.
  cat <<EOF
  Supported operating systems:

EOF
  echo "$supported"
  swap_note=""
  # Add a swap estimate only when this installation will manage swap.
  if [ "${SLIB_SWAP_API:-0}" = 2 ] && [ -z "$setup_only$noswap" ] &&
     swap_plan "$disk_space_required"; then
    swap_note=$(swap_plan_message)
  fi
  # Link to the full compatibility requirements before asking to proceed.
  cat <<EOF
  Installation ${BOLD}${RED}will fail${NORMAL} if your OS version or architecture is not listed.
  See the full system requirements:

    ${UNDERLINE}https://www.cloudmin.com/docs/os-support/${NORMAL}

EOF
  # Wrap the complete paragraph to match the surrounding text. Count plain
  # characters before adding color, keeping each size and its unit together.
  # The first input line contains the disk estimate; later sizes describe swap.
  printf '%s\n' \
    "Installation requires up to $disk_space_required GiB of disk space." \
    "${swap_note:+$swap_note }The selected" \
    "package bundle is $bundle. See the" \
    "installation guide:" |
    awk -v cyan="$CYAN" -v yellow="$YELLOW" -v normal="$NORMAL" \
        -v bundle="$bundle" '
      {
        for (i = 1; i <= NF; i++) {
          word = $i
          display = word
          # Keep sizes and units together; do not count color codes as text.
          if (word ~ /^[0-9]+$/ && i < NF && $(i + 1) ~ /^[GM]iB[.]?$/) {
            unit = $(++i)
            suffix = (unit ~ /[.]$/ ? "." : "")
            sub(/[.]$/, "", unit)
            word = word " " unit
            display = (NR == 1 ? cyan : yellow) word normal suffix
            word = word suffix
          } else if (word == bundle ".") {
            # Highlight the bundle name without changing its printed width.
            display = cyan bundle normal "."
          }
          # Wrap on word boundaries while preserving the two-space left margin.
          if (column && column + 1 + length(word) > 70) {
            printf "\n"
            column = 0
          }
          printf "%s%s", (column ? " " : "  "), display
          column += (column ? 1 : 0) + length(word)
        }
      }
      END { printf "\n" }
    '
  cat <<EOF

    ${UNDERLINE}https://www.cloudmin.com/docs/installation/automated/${NORMAL}

EOF

  # Interactive users can leave now to review options before changes begin.
  if [ "$skipyesno" -ne 1 ]; then
  cat <<EOF
  To see all options, exit and run this script with ${CYAN}--help${NORMAL}.

EOF
  fi
  # --yes skips this confirmation along with the other installation prompts.
  if [ "$skipyesno" -ne 1 ]; then
    # Declining the summary exits before any package or swap changes.
    if ! confirm " Continue? (y/n) "; then
      exit
    fi
  fi
}

# unstable_repos_system_msg() Warns about unstable packages outside development.
unstable_repos_system_msg() {
  # Development builds skip the unstable warning and its extra confirmation.
  if [ "${CLOUDMIN_DEVELOPMENT:-0}" != 1 ] && [ "$branch" = "unstable" ]; then
    cat <<EOF

  ${REDBG}${WHITE}${BOLD} DANGER ${NORMAL}

  The unstable branch contains development builds. Use it only for
  testing, not on production systems.

EOF

    # Ask interactive users to accept the unstable branch explicitly.
    if [ "$skipyesno" -ne 1 ]; then
      # Declining stops installation before repository setup.
      if ! confirm " Continue with $branch branch? (y/n) "; then
        exit
      fi
    fi
  fi
}

# preconfigured_system_msg() Warns before changing existing host services.
preconfigured_system_msg() {
  # Check only services and firewall rules affected by Cloudmin setup.
  is_preconfigured_rs=$(is_preconfigured)
  # Explain the changes before asking to continue on a configured host.
  if [ -n "$is_preconfigured_rs" ]; then
    cat <<EOF

  ${WHITEBG}${RED}${BOLD} ATTENTION ${NORMAL}

  Existing host software detected: $is_preconfigured_rs

  The default setup configures libvirt, Webmin and Fail2ban. It removes
  conflicting firewall packages and disables other firewall managers
  before applying Cloudmin's nftables rules. SSH, Webmin and guest networking
  are allowed. Other incoming connections may be blocked. Review custom
  firewall rules before continuing.

EOF
    # --yes accepts the warning; interactive users choose whether to proceed.
    if [ "$skipyesno" -ne 1 ]; then
      # Declining preserves the existing software without starting setup.
      if ! confirm " Continue? (y/n) "; then
        exit
      fi
    fi
  fi
}

# is_preconfigured() Lists existing services and rules affected by setup.
is_preconfigured() {
  preconfigured=""
  # Include stopped and masked services without starting any daemons.
  preconfigured_units=$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null)
  # Both libvirt layouts share the network and storage configuration we use.
  if printf '%s\n' "$preconfigured_units" | grep -Eq '^(libvirtd|virtqemud|virtnetworkd|virtstoraged)\.service[[:space:]]'; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}libvirt${NORMAL} "
  fi
  # Webmin receives Cloudmin settings even when it is already installed.
  if printf '%s\n' "$preconfigured_units" | grep -q '^webmin\.service[[:space:]]'; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}Webmin${NORMAL} "
  fi
  # Rules may exist without an installed or enabled nftables service.
  if printf '%s\n' "$preconfigured_units" | grep -q '^nftables\.service[[:space:]]' ||
      nft list tables 2>/dev/null | grep -q '^table '; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}nftables${NORMAL} "
  fi
  # Cloudmin stops these firewall managers before applying its own profile.
  for preconfigured_service in firewalld ufw iptables ip6tables netfilter-persistent; do
    if printf '%s\n' "$preconfigured_units" | grep -q "^${preconfigured_service}\\.service[[:space:]]"; then
      preconfigured="${preconfigured}${YELLOW}${BOLD}${preconfigured_service}${NORMAL} "
    fi
  done
  # Existing Fail2ban jails are validated when Cloudmin adds its host jails.
  if printf '%s\n' "$preconfigured_units" | grep -q '^fail2ban\.service[[:space:]]'; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}Fail2ban${NORMAL} "
  fi
  # Return a comma-separated display list to the warning caller.
  preconfigured=$(echo "$preconfigured" | sed 's/ /, /g' | sed 's/, $/ /')
  echo "$preconfigured"
}

# is_installed() Tests whether the Cloudmin module configuration exists.
is_installed() {
  [ -f /etc/webmin/server-manager/config ]
}

# already_installed_block() Rejects an unrequested reinstall with exit code 100.
already_installed_block() {
  log_error "Cloudmin is already installed on this system."
  log_error "This installer is intended for a fresh, supported operating system."
  log_error "Use your package manager for updates."
  log_error "Change licenses in System → Settings → License Manager."
  log_error "Use --force-reinstall only if you intend to rerun installation."
  exit 100
}

# already_installed_msg() Warns before an explicitly requested reinstall.
already_installed_msg() {
  # Explain the limits of the requested reinstall before making changes.
  if is_installed; then
    cat <<EOF

  ${WHITEBG}${RED}${BOLD} WARNING ${NORMAL}

  Cloudmin is already installed. ${BOLD}${RED}Do not reinstall${NORMAL} to fix problems,
  apply updates or change licenses.

  Use your package manager for updates.
  Change licenses in System → Settings → License Manager.

EOF
    confirm ' Continue? (y/n) ' || exit 0
  fi
}

# install_with_apt() Installs the DEB stack and checks required tool versions.
install_with_apt() {
  # Apply distribution updates unless the caller explicitly skipped them.
  if [ -z "$noupdates" ]; then
    run_ok "$upgrade" 'Checking and installing system package updates' || return $?
  fi
  # Purge competing firewall packages before installing the stack.
  apt-get --quiet --assume-yes purge ufw firewalld >> "$RUN_LOG" 2>&1

  extra_packages_cmd=''
  # Check extras before installing Webmin so unavailable names fail early.
  if [ -n "$extra_packages" ]; then
    sim_install="${install% install} --simulate install"
    run_ok "$sim_install webmin && $sim_install $extra_packages" \
      'Checking availability of selected extra packages' || return $?
    extra_packages_cmd=" && $install $extra_packages"
  fi

  # Configure Webmin before its modules run their pre-install checks, then
  # install the core and KVM packages together.
  run_ok "$install webmin$extra_packages_cmd && $install cloudmin-core cloudmin-kvm-stack" \
    'Installing Cloudmin and the KVM stack' || return $?
  # Check minimum package versions before running host configuration.
  config_version=$(dpkg-query -W -f='${Version}' cloudmin-config) || return $?
  webmin_version=$(dpkg-query -W -f='${Version}' webmin) || return $?
  run_ok 'dpkg --compare-versions "$config_version" ge 10.0.0' \
    'Checking the configuration package version' || return $?
  run_ok 'dpkg --compare-versions "$webmin_version" ge 2.670' \
    'Checking the Webmin version' || return $?
}

# install_with_yum() Installs the RPM groups and checks required tool versions.
install_with_yum() {
  # Apply distribution updates unless the caller explicitly skipped them.
  if [ -z "$noupdates" ]; then
    run_ok "$upgrade" 'Checking and installing system package updates' || return $?
  fi
  # Remove firewalld before installing the nftables-based stack.
  $install_cmd -y remove firewalld >> "$RUN_LOG" 2>&1

  # Resolve both groups and optional packages in one dependency transaction.
  run_ok "$install @cloudmincore @cloudmin-kvm 'cloudmin-config >= 10.0.0' 'webmin >= 2.670' $extra_packages" \
    'Installing Cloudmin and the KVM stack' || return $?
  # Confirm the installed packages meet the requested minimum versions.
  run_ok "rpm -q --whatprovides 'cloudmin-config >= 10.0.0'" \
    'Checking the configuration package version' || return $?
  run_ok "rpm -q --whatprovides 'webmin >= 2.670'" \
    'Checking the Webmin version' || return $?
}

# install_cloudmin() Selects the installation routine for the package format.
install_cloudmin() {
  case "$package_type" in
    rpm) bind_hook install_with_yum ;;
    deb) bind_hook install_with_apt ;;
    *) fatal "Unsupported package format: $package_type" ;;
  esac
}

# post_install_message() Shows the login URL after installation succeeds.
post_install_message() {
  log_success "Installation Complete!"
  log_success "Cloudmin is ready at https://${forcehostname:-$(hostname -f)}:10000."
  log_warning "Your browser may show a certificate warning on the first visit."
}

# load_module() Sources the selected local module before configuration.
# Modules and their hooks run as trusted shell code with installer privileges.
load_module() {
  [ -n "$module_name" ] || return 0
  bind_hook modules_pre || return $?
  . "$script_dir/$module_name.sh" || return $?
  bind_hook modules_post
}

# extra_phases() Runs hooks__phases after the normal configuration phase.
# Rows contain a phase number, name, command and description, separated
# by tabs.
extra_phases() {
  [ -n "$hooks__phases" ] || return 0
  bind_hook phases_pre || return $?
  printf '%s\n' "$hooks__phases" > "$CLOUDMIN_INSTALL_TEMPDIR/phases"
  current_phase=
  # Read in this shell so phase hooks can update installer state.
  while IFS="$(printf '\t')" read -r phase_number phase_name command description; do
    [ -n "$phase_number" ] || continue
    # Print one heading per phase, even when it contains several commands.
    if [ "$phase_number" != "$current_phase" ]; then
      printf '\n'
      bind_hook phase "$phase_name" "$phase_number" || return $?
      current_phase=$phase_number
    fi
    run_ok "$command" "$description" || return $?
  done < "$CLOUDMIN_INSTALL_TEMPDIR/phases"
  bind_hook phases_post
}

# uninstall() Removes Cloudmin packages without deleting virtual machine data.
uninstall() {
  # Require confirmation unless unattended removal was explicitly requested.
  if [ "$skipyesno" -ne 1 ]; then
    cat <<EOF

  ${REDBG}${BLACK}${BOLD} WARNING ${NORMAL}

  This operation removes Cloudmin packages and repository configuration.
  Virtual machine disks and the shared Webmin installation are kept.
  Do not run this on a production host.

EOF
    confirm " ${RED}Uninstall?${NORMAL} (y/N) " || return 0
  fi
  phases_total=1
  bind_hook phase Uninstall 1 || return $?
  # Keep package configuration and shared dependencies during removal.
  if [ "$manager" = apt-get ]; then
    run_ok 'apt-get -y remove cloudmin-core cloudmin-kvm-stack cloudmin-config webmin-server-manager' \
      'Uninstalling Cloudmin packages' || return $?
    # Remove the GPL preference created by the repository setup helper.
    rm -f "/etc/apt/preferences.d/$ID-cloudmin-package-priority" || return $?
  else
    # Keep hypervisor packages and other dependencies that DNF might remove.
    run_ok 'dnf -y --setopt=clean_requirements_on_remove=False remove cloudmin-config webmin-server-manager' \
      'Uninstalling Cloudmin packages' || return $?
  fi
  # Remove repository and authentication files, including old channel names.
  for repo in cloudmin cloudmin-stable cloudmin-unstable; do
    rm -f "/etc/apt/sources.list.d/$repo.list" "/etc/apt/sources.list.d/$repo.sources" \
      "/etc/apt/auth.conf.d/$repo.conf" "/etc/yum.repos.d/$repo.repo" || return $?
  done
  log_success 'Cloudmin uninstallation complete.'
}

# test_connection(host_or_url, ip_version) Checks DNS, ICMP and HTTP access.
# ip_version must be ipv4 or ipv6; HTTP client timeouts are set to 5 seconds.
test_connection() {
  input="$1"
  ip_version="$2"
  ip_version_nice=$(echo "$ip_version" | sed 's/ip/IP/')
  timeout=5
  http_protocol="http"
  http_protocol_nice=$(echo "$http_protocol" | tr '[:lower:]' '[:upper:]')

  # This standalone diagnostic runs before slib initializes terminal colors.
  GREEN="" BLACK="" RED="" RESET="" BOLD="" GRBG="" REDBG=""
  # Use terminal capabilities when available; otherwise retain plain labels.
  if command -pv 'tput' > /dev/null; then
    GREEN=$(tput setaf 2)
    BLACK=$(tput setaf 0)
    RED=$(tput setaf 1)
    RESET=$(tput sgr0)
    BOLD=$(tput bold)
    GRBG=$(tput setab 22; tput setaf 10)
    REDBG=$(tput setab 52; tput setaf 9)
  fi

  # Extract the host name from a URL, or use a bare host name.
  domain=$(echo "$input" | awk -F[/:] '{print $4}')
  [ -z "$domain" ] && domain="$input"

  # Both the host and IP version are required for the checks.
  if [ -z "$domain" ] || [ -z "$ip_version" ]; then
    echo "${RED}[ERROR]  ${RESET} Domain and IP version are required" >&2
    return 1
  fi

  # Check DNS resolution before testing connectivity over IPv4 or IPv6.
  case "$ip_version" in
    ipv4)
      # Stop IPv4 checks if the resolver cannot supply an address.
      if ! getent ahostsv4 "$domain" >/dev/null 2>&1; then
        echo "${RED}[ERROR]  ${RESET} ${BOLD}$domain${RESET} — cannot find IPv4 address" >&2
        return 1
      fi
      ping_cmd="ping -c 1 -W $timeout $domain"
      http_cmd="curl -sS --ipv4 --max-time $timeout --head $http_protocol://$domain \
        || wget --spider -4 -T $timeout $http_protocol://$domain"
      ;;
    ipv6)
      # Stop IPv6 checks if the resolver cannot supply an address.
      if ! getent ahostsv6 "$domain" >/dev/null 2>&1; then
        echo "${RED}[ERROR]  ${RESET} ${BOLD}$domain${RESET} — cannot find IPv6 address" >&2
        return 1
      fi
      ping_cmd="ping6 -c 1 -W $timeout $domain"
      http_cmd="curl -sS --ipv6 --max-time $timeout --head $http_protocol://$domain \
        || wget --spider -6 -T $timeout $http_protocol://$domain"
      ;;
  esac

  # Report ICMP reachability separately from HTTP access.
  if eval "$ping_cmd" >/dev/null 2>&1; then
    echo "${GREEN}[SUCCESS]${RESET} ${GRBG}[$ip_version_nice]${RESET} ${GRBG}[ICMP]${RESET} ${BOLD}$domain${RESET}"
  else
    # A failed ping does not prevent checking HTTP, which may still be allowed.
    echo "${RED}[ERROR]  ${RESET} ${REDBG}[$ip_version_nice]${RESET} ${REDBG}[ICMP]${RESET} ${BOLD}$domain${RESET}"
  fi

  # Check plain HTTP when a client is available; TLS and login are not tested.
  if command -v 'curl' > /dev/null || command -v 'wget' > /dev/null; then
    # Report success when curl or its wget fallback completes the HTTP probe.
    if eval "$http_cmd" >/dev/null 2>&1; then
      echo "${GREEN}[SUCCESS]${RESET} ${GRBG}[$ip_version_nice]${RESET} ${GRBG}[$http_protocol_nice]${RESET} ${BOLD}$domain${RESET}"
      return 0
    else
      # Return failure so the caller can aggregate failures across hosts.
      echo "${RED}[ERROR]  ${RESET} ${REDBG}[$ip_version_nice]${RESET} ${REDBG}[$http_protocol_nice]${RESET} ${BOLD}$domain${RESET}"
      return 1
    fi
  fi
}

# check_connections() Tests repository connectivity without installing anything.
check_connections() {
  connection_result=0
  for connection_host in "$download_webmin_host_dev" "$download_cloudmin_host_dev"; do
    for connection_protocol in $connect; do
      test_connection "$connection_host" "$connection_protocol" || connection_result=1
    done
  done
  return "$connection_result"
}

# main([args...]) Runs installation or the requested standalone operation.
main() {
  # Parse options and honor version requests before creating logs or task files.
  bind_hook parse_args "$@" || fatal 'Cannot parse installation options'
  [ -z "$showversion" ] || { bind_hook show_version; return $?; }
  # Allow repository setup callers to select setup-only mode through an
  # environment variable.
  if [ "${CLOUDMIN_SETUP_ONLY:-0}" = 1 ]; then
    setup_only=1; swap_only=; noswap=1; swapsize=; uninstall_mode=; connect=
  fi
  # Exit early for connectivity checks or --swap-only with --no-swap.
  [ -z "$connect" ] || { bind_hook check_connections; return $?; }
  [ -z "$swap_only" ] || [ -z "$noswap" ] || { printf 'System swap left unchanged.\n'; return 0; }
  # Check the host and locate any requested local module before setup starts.
  bind_hook pre_check_all || fatal 'System checks failed'
  script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || fatal 'Cannot find installer directory'
  [ -z "$module_name" ] || [ -f "$script_dir/$module_name.sh" ] || fatal "Module not found: $module_name.sh"
  # Keep new credentials and logs private and select a log for this operation.
  umask 077
  mkdir -p -- "$log_dir" || fatal 'Cannot create the log directory'
  log="$log_dir/cloudmin-install.log"
  [ -z "$setup_only" ] || log="$log_dir/cloudmin-repos-setup.log"
  [ -z "$uninstall_mode" ] || log="$log_dir/cloudmin-uninstall.log"
  [ -z "$swap_only" ] || log="$log_dir/cloudmin-swap.log"
  # Preserve logs from previous runs.
  if [ -e "$log" ]; then
    logcnt=1
    while [ -e "$log.$logcnt" ]; do logcnt=$((logcnt+1)); done
    mv "$log" "$log.$logcnt" || fatal 'Cannot rotate the log file'
  fi
  touch "$log" || fatal 'Cannot open the log file'
  # Give downloads and progress files a private workspace with exit cleanup.
  CLOUDMIN_INSTALL_TEMPDIR=$(mktemp -d /var/tmp/cloudmin-install.XXXXXX) || fatal 'Cannot create temporary directory'
  export CLOUDMIN_INSTALL_TEMPDIR
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  # Load shared helpers before planning swap or showing installation prompts.
  bind_hook download_slib || fatal 'Cannot load the utility library'
  disk_space_required=4
  # Standalone swap exits before license, repository and package operations.
  if [ -n "$swap_only" ]; then
    log_info "Swap setup log is written to $LOG_PATH"
    log_info 'Started swap setup'
    swap_plan 0 || { log_error "$swap_error"; swap_abort; }
    # An empty plan needs neither confirmation nor a swap operation.
    if [ "$swap_action" = none ]; then
      log_success 'System swap left unchanged.'
      return 0
    fi
    # Show the planned size and require approval before modifying managed swap.
    log_info "$(swap_plan_message)" |
      sed "s/[0-9][0-9]* [GM]iB/${YELLOW}&${NORMAL}/g"
    # Cancellation leaves swap untouched and exits successfully.
    if ! confirm 'Apply these swap changes? (y/n) '; then
      log_info 'Swap setup cancelled; system swap left unchanged.'
      return 0
    fi
    swap_setup 0 || swap_abort
    log_success 'Swap setup complete.'
    return 0
  fi
  # Removal has its own confirmation and must not configure new repositories.
  if [ -n "$uninstall_mode" ]; then
    log_info "Uninstallation log is written to $LOG_PATH"
    bind_hook uninstall || fatal "Uninstallation failed; see $log"
    return 0
  fi
  # Reuse saved credentials when no license was supplied.
  if [ "$SERIAL" = GPL ] && [ "$KEY" = GPL ] && [ -f "$cloudmin_license_file" ]; then
    cloudmin_license_existing_serial="$(grep 'SerialNumber=' "$cloudmin_license_file" | sed 's/SerialNumber=//')"
    cloudmin_license_existing_key="$(grep 'LicenseKey=' "$cloudmin_license_file" | sed 's/LicenseKey=//')"
    # Use saved credentials only when both the serial number and key exist.
    if [ -n "$cloudmin_license_existing_serial" ] && [ -n "$cloudmin_license_existing_key" ]; then
      SERIAL="$cloudmin_license_existing_serial"
      KEY="$cloudmin_license_existing_key"
    fi
  fi
  # Check the credential format without contacting the license server.
  serial_ok "$SERIAL" "$KEY" || fatal 'Invalid license credentials'
  # The selected edition controls the banner and repository authentication.
  if [ "$SERIAL" = GPL ]; then
    PRODUCT=GPL
  else
    # A non-GPL serial selects authenticated Professional package downloads.
    PRODUCT=Professional
  fi
  # Repository-only setup skips the installation banner and swap plan.
  if [ -n "$setup_only" ]; then
    log_info "Setup log is written to $LOG_PATH"
    log_info "Started repository setup for Cloudmin 10 $PRODUCT"
  else
    # Full installation includes its swap estimate in the confirmation summary.
    log_info "Installation log is written to $LOG_PATH"
    [ -n "$noswap" ] || swap_plan "$disk_space_required" || { log_error "$swap_error"; swap_abort; }
    # --no-banner suppresses the summary and warning prompts together.
    if [ -z "$skipbanner" ]; then
      bind_hook install_msg || fatal 'Cannot display installation summary'
      bind_hook unstable_repos_system_msg || fatal 'Cannot display repository warning'
      bind_hook preconfigured_system_msg || fatal 'Cannot check existing host services'
      bind_hook already_installed_msg || fatal 'Cannot check existing installation'
    fi
  fi
  bind_hook phases_all_pre || fatal 'Installation hook failed'
  # Only full installs show the host-check phase and apply the planned swap.
  if [ -z "$setup_only" ]; then
    printf '\n'
    bind_hook phase Check 1 || fatal 'Phase hook failed'
    bind_hook phase1_pre || fatal 'Check hook failed'
    run_ok 'bind_hook pre_check_all' 'Checking operating system and KVM support' || fatal 'System checks failed'
    bind_hook phase1_post || fatal 'Check hook failed'
    # Begin host setup after the repeated preflight check succeeds.
    printf '\n'
    bind_hook phase Setup 2 || fatal 'Phase hook failed'
    bind_hook phase2_pre || fatal 'Setup hook failed'
    [ -n "$noswap" ] || swap_setup "$disk_space_required" || swap_abort
  fi
  # Save the selected license before configuring repository authentication.
  log_debug "Saving serial number and license key to '$cloudmin_license_file'"
  echo "SerialNumber=$SERIAL" > "$cloudmin_license_file" || fatal 'Cannot save the license'
  echo "LicenseKey=$KEY" >> "$cloudmin_license_file" || fatal 'Cannot save the license'
  chmod 700 "$cloudmin_license_file" || fatal 'Cannot protect the license file'
  # Install repository prerequisites before writing and refreshing repositories.
  bind_hook preconfigure_cloudmin_release || fatal "Package manager setup failed; see $log"
  bind_hook manage_cloudmin_branch_repos || fatal "Repository setup failed; see $log"
  # Repository setup completes here without installing or configuring the stack.
  if [ -n "$setup_only" ]; then
    bind_hook phases_all_post || fatal 'Setup hook failed'
    log_success 'Cloudmin repositories configured.'
    return 0
  fi
  # Enter package installation after all setup work and its hooks complete.
  bind_hook phase2_post || fatal 'Setup hook failed'
  printf '\n'
  bind_hook phase Installation 3 || fatal 'Phase hook failed'
  bind_hook phase3_pre || fatal 'Installation hook failed'
  # Apply an explicit hostname before configuration uses it for host settings.
  if [ -n "$forcehostname" ]; then
    run_ok 'hostnamectl set-hostname "$forcehostname"' 'Setting the host name' || fatal 'Cannot set the host name'
  fi
  # Install the native stack, then load any trusted post-install module.
  bind_hook install_cloudmin || fatal "Package installation failed; see $log"
  bind_hook phase3_post || fatal 'Installation hook failed'
  bind_hook load_module || fatal 'Post-install module failed'
  # Configuration and readiness must finish before cleanup or a success message.
  printf '\n'
  bind_hook phase Configuration 4 || fatal 'Phase hook failed'
  bind_hook phase4_pre || fatal 'Configuration hook failed'
  # Keep the timeout detail in the log while Config renders the progress row.
  log_info 'Checking KVM appliance boot (3-minute timeout)' >/dev/null
  # On failure, show recent diagnostics and stop before reporting success.
  # The option helpers accept only literal plugin names.
  # shellcheck disable=SC2086
  if ! cloudmin-config-system --bundle "$bundle" $config_excludes $config_includes --log "$log"; then
    tail -n 30 "$log" >&2
    fatal "Cloudmin configuration or readiness failed; see $log"
  fi
  # Run extension phases only after the required configuration succeeds.
  bind_hook phase4_post || fatal 'Configuration hook failed'
  bind_hook extra_phases || fatal 'Additional installation phase failed'
  bind_hook phases_all_post || fatal 'Installation hook failed'
  # Leave the workspace before removing it and clear its path for the exit trap.
  bind_hook clean_pre || fatal 'Cleanup hook failed'
  printf '%s▣▣▣%s Cleaning up\n' "$GREEN" "$NORMAL"
  cd "$script_dir" || fatal 'Cannot leave temporary directory'
  rm -rf -- "$CLOUDMIN_INSTALL_TEMPDIR" || fatal 'Cannot remove temporary directory'
  CLOUDMIN_INSTALL_TEMPDIR=
  bind_hook clean_post || fatal 'Cleanup hook failed'
  # Announce the login URL only after all phases and cleanup hooks succeed.
  printf '\n'
  bind_hook post_install_message || fatal 'Post-install message hook failed'
}

main "$@"
