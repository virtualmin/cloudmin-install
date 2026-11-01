#!/bin/sh
# Copyright 2005-2026 Cloudmin
# Copyright 2005-2026 The Webmin Developers
# Install Cloudmin on a supported Linux host.
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC3043,SC2059

VER=10.0.0-RC1

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

# usage() Documents the supported installation and standalone swap controls.
usage() {
  # shellcheck disable=SC2046
  echo
  printf "Usage: %s [options]\\n" "$(basename "$0")"
  echo
  echo "  If called without arguments, installs Cloudmin with default options."
  echo
  printf "  --bundle|-b <KVM>                bundle to install (default: KVM)\\n"
  # Development builds use the unstable channel without advertising a switch.
  if [ "${CLOUDMIN_DEVELOPMENT:-0}" != 1 ]; then
    printf "  --branch|-B <unstable>            install branch (default: unstable)\\n"
  fi
  echo
  printf "  --extra|-E <name[,name..]>       install extra packages with the stack\\n"
  printf "  --exclude|-e <name[,name..]>     exclude plugin from configuration phase\\n"
  printf "  --include|-i <name[,name..]>     include plugin in configuration phase\\n"
  printf "  --module|-o <name>               load custom module in post-install phase\\n"
  echo
  printf "  --hostname|-n <name>             force hostname during install\\n"
  printf "  --no-package-updates|-x          skip package updates during install\\n"
  echo
  printf "  --swap|-S <size>                 managed swap: MiB or K/M/G[B]; 0 to remove\\n"
  printf "  --swap-only                      configure swap without installing\\n"
  printf "  --no-swap|-ns                    leave system swap unchanged\\n"
  echo
  printf "  --uninstall|-u                   remove Cloudmin packages and repositories\\n"
  printf "  --setup|-s                       reconfigure repos without installing\\n"
  printf "  --connect|-C <ipv4|ipv6>         test connectivity without installing\\n"
  printf "  --insecure-downloads|-I          skip SSL certificate check for downloads\\n"
  echo
  printf "  --log-dir <directory>            directory for installer logs\\n"
  echo
  printf "  --force|-f|--yes|-y              assume \"yes\" to all prompts\\n"
  printf "  --force-reinstall|-fr            force complete reinstall (not recommended)\\n"
  printf "  --no-banner|-nb                  suppress installation messages and warnings\\n"
  printf "  --verbose|-V                     enable verbose mode\\n"
  echo
  printf "  --version|-v                     show installer version\\n"
  printf "  --help|-h                        show this help\\n"
  echo
}

# Report argument errors before the shared logger is loaded.
log_error() {
  if [ -t 2 ] && [ "${INTERACTIVE_MODE:-}" != off ] && command -v tput >/dev/null 2>&1; then
    printf '%s[ERROR]%s %s\n' "$(tput setaf 1 2>/dev/null)" "$(tput sgr0 2>/dev/null)" "$1" >&2
  else
    printf '[ERROR] %s\n' "$1" >&2
  fi
}

# fail(message) Reports errors before and after the shared logger is available.
fail() {
  log_error "$*"
  exit 1
}

# bind_hook(name, [args...]) Calls an override, or pre/original/post hooks.
bind_hook() {
  local hook="$1"
  shift
  if command -v "hook__$hook" >/dev/null 2>&1; then
    "hook__$hook" "$@"
  else
    if command -v "pre_hook__$hook" >/dev/null 2>&1; then
      "pre_hook__$hook" "$@" || return $?
    fi
    if command -v "$hook" >/dev/null 2>&1; then
      "$hook" "$@" || return $?
    fi
    if command -v "post_hook__$hook" >/dev/null 2>&1; then
      "post_hook__$hook" "$@" || return $?
    fi
    return 0
  fi
}

# swap_size(value) Validates a size and converts it to KiB, rounded up to MiB.
swap_size() {
  swap_arg=$1
  swap_num=${swap_arg%%[!0-9]*}
  swap_suffix=${swap_arg#"$swap_num"}
  case "$swap_suffix" in
    [Kk]|[Kk][Bb]) swap_mult=1 ;;
    [Mm]|[Mm][Bb]|'') swap_mult=1024 ;;
    [Gg]|[Gg][Bb]) swap_mult=1048576 ;;
    *) fail "Invalid swap size: $swap_arg" ;;
  esac
  swap_num=${swap_num#"${swap_num%%[!0]*}"}
  if [ -z "${swap_arg%%[!0-9]*}" ] || [ "${#swap_num}" -gt 10 ]; then
    fail "Invalid swap size: $swap_arg"
  fi
  swap_num=${swap_num:-0}
  [ "$swap_num" -le $((1073740800 / swap_mult)) ] || fail "Invalid swap size: $swap_arg"
  swapsize=$(((swap_num * swap_mult + 1023) / 1024 * 1024))
}

# require_value(option, [value]) Rejects missing option values before side effects.
require_value() {
  [ -n "${2:-}" ] || fail "$1 requires a value"
  case "$2" in -*) fail "$1 requires a value" ;; esac
}

# parse_options(args) Validates all options before inspecting or changing the host.
parse_options() {
  branch=unstable; setup=; swap_only=; noswap=; swapsize=; skipyesno=0
  hostname_arg=; no_updates=; extra=; includes=; excludes=; VERBOSE=0
  forcereinstall=; skipbanner=; module_name=; insecure_downloads=; connect=; uninstall_mode=
  bundle=KVM; showversion=
  log_dir=/root
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) bind_hook usage; exit 0 ;;
      --version|-v) showversion=1; shift ;;
      --branch|-B|--hostname|-n|--extra|-E|--include|-i|--exclude|-e|--log-dir|--swap|-S|--module|-o|--bundle|-b)
        require_value "$1" "${2:-}"
        case "$1" in
          --branch|-B) branch=$2 ;;
          --hostname|-n) hostname_arg=$2 ;;
          --extra|-E) extra="${extra:+$extra,}$2" ;;
          --include|-i) includes="${includes:+$includes,}$2" ;;
          --exclude|-e) excludes="${excludes:+$excludes,}$2" ;;
          --log-dir) log_dir=$2 ;;
          --swap|-S) swap_size "$2" ;;
          --module|-o) module_name=$2 ;;
          --bundle|-b) bundle=$2 ;;
        esac
        shift 2 ;;
      --setup|-s) setup=1; shift ;;
      --swap-only) swap_only=1; shift ;;
      --no-swap|-ns) noswap=1; shift ;;
      --yes|-y|--force|-f) skipyesno=1; shift ;;
      --no-package-updates|-x) no_updates=1; shift ;;
      --verbose|-V) VERBOSE=1; shift ;;
      --force-reinstall|-fr) forcereinstall=1; shift ;;
      --no-banner|-nb) skipbanner=1; shift ;;
      --insecure-downloads|-I) insecure_downloads=1; shift ;;
      --uninstall|-u) uninstall_mode=1; shift ;;
      --connect|-C)
        connect='ipv4 ipv6'; shift
        case "${1:-}" in
          ipv4|ipv6) connect=$1; shift ;;
          ''|-*) ;;
          *) fail "Invalid protocol: $1" ;;
        esac ;;
      *) fail "Unknown option: $1" ;;
    esac
  done
  case "$branch" in testing|development|devel|dev|nightly|bleeding-edge|cutting-edge) branch=unstable ;; esac
  [ "$branch" = unstable ] || fail 'Only the unstable repository is available'
  [ "$bundle" = KVM ] || fail "Unknown bundle: $bundle"
  case "$module_name" in *[!A-Za-z0-9_.-]*|.*) fail 'Invalid module name' ;; esac
  [ -z "$uninstall_mode" ] || [ -z "$setup$swap_only$swapsize$noswap$connect$hostname_arg$extra$includes$excludes$module_name" ] ||
    fail '--uninstall cannot be combined with setup, swap or installation options'
  [ -z "$connect" ] || [ -z "$setup$swap_only$swapsize$noswap$uninstall_mode$hostname_arg$extra$includes$excludes$module_name" ] ||
    fail '--connect cannot be combined with setup, swap or installation options'
  [ -z "$noswap" ] || [ -z "$swapsize" ] || fail 'Options --swap and --no-swap are mutually exclusive'
  [ -z "$setup" ] || [ -z "$swap_only$swapsize" ] || fail '--setup cannot be combined with swap changes'
  [ -z "$setup" ] || [ -z "$hostname_arg$extra$includes$excludes$no_updates$module_name" ] ||
    fail '--setup cannot be combined with installation options'
  [ -z "$swap_only" ] || [ -z "$hostname_arg$extra$includes$excludes$no_updates$module_name" ] ||
    fail '--swap-only cannot be combined with installation options'
  case "$log_dir" in /*) ;; *) fail '--log-dir must be an absolute path' ;; esac
  if [ -n "$hostname_arg" ]; then
    printf '%s\n' "$hostname_arg" | LC_ALL=C grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$' ||
      fail 'Provide a fully qualified host name'
  fi
  # Only literal package and plugin names reach the package manager or the configuration tool.
  if [ -n "$extra" ]; then
    printf '%s\n' "$extra" | LC_ALL=C grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9+_.-]*(,[a-zA-Z0-9][a-zA-Z0-9+_.-]*)*$' ||
      fail 'Invalid extra package list'
  fi
  for names in "$includes" "$excludes"; do
    [ -z "$names" ] || printf '%s\n' "$names" | LC_ALL=C grep -Eq '^[A-Za-z][A-Za-z0-9]*(,[A-Za-z][A-Za-z0-9]*)*$' ||
      fail 'Invalid configuration plugin list'
  done
}

# parse_args(args...) Parses options and selects the utility library host.
parse_args() {
  parse_options "$@"
  # Select the utility library from the same branch as the Cloudmin packages.
  if [ "$branch" = unstable ]; then
    download_cloudmin_host_lib="$download_cloudmin_host_dev"
  fi
}

# show_version() Prints the installer version.
show_version() {
  printf '%s\n' "$VER"
}

# supported_host(id, version, architecture) Keeps package selection explicit.
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

# preflight() Rejects unsupported systems before downloads, swap or package changes.
preflight() {
  [ "$(uname -s)" = Linux ] || fail 'Run this installer on a Linux host'
  [ "$(id -u)" = 0 ] || fail 'Run this installer as root'
  # Standalone swap management does not configure a Cloudmin host.
  [ -z "$swap_only" ] || return 0
  [ -r /etc/os-release ] || fail 'Cannot determine the operating system'
  . /etc/os-release
  supported_host "${ID:-}" "${VERSION_ID:-}" "$(uname -m)" ||
    fail 'Supported hosts: Rocky/AlmaLinux 10, Debian 13 and Ubuntu 26.04, x86_64 or aarch64'
  [ -d /run/systemd/system ] || fail 'A running systemd host is required'
  [ -n "$setup$uninstall_mode" ] || [ -c /dev/kvm ] || fail 'KVM is unavailable; enable hardware or nested virtualization'
  if [ -z "$setup$uninstall_mode$forcereinstall" ] && is_installed; then
    bind_hook already_installed_block
    return 1
  fi
  case "$ID" in
    debian|ubuntu) manager=apt-get; export DEBIAN_FRONTEND=noninteractive ;;
    *) manager=dnf ;;
  esac
  command -v "$manager" >/dev/null 2>&1 || fail "$manager is required"
}

# finish() Removes only this invocation's private workspace and keeps its exit status.
finish() {
  result=$?
  trap - EXIT HUP INT TERM QUIT
  if [ "${INTERACTIVE_MODE:-off}" != off ]; then
    stty echo 2>/dev/null || :
    for pid in $allpids; do kill "$pid" 2>/dev/null || :; done
    tput cnorm 2>/dev/null || :
    tput sgr0 2>/dev/null || :
  fi
  [ -z "${CLOUDMIN_INSTALL_TEMPDIR:-}" ] || rm -rf -- "$CLOUDMIN_INSTALL_TEMPDIR"
  exit "$result"
}

# fetch(url, path) Requires HTTPS and stops on HTTP or download failure.
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -q ${insecure_downloads:+--insecure} --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 20 --max-time 300 --output "$2" "$1" >>"$log" 2>&1 || fail "Download failed: $1"
  elif command -v wget >/dev/null 2>&1; then
    wget ${insecure_downloads:+--no-check-certificate} --https-only --timeout=30 --tries=2 -q -O "$2" "$1" >>"$log" 2>&1 || fail "Download failed: $1"
  else
    fail 'Install curl or wget, or place slib.sh beside the installer for --swap-only'
  fi
}

# run(message, command...) Preserves the command's failure and keeps detailed output.
run() {
  local message="$1" command_text='' arg
  shift
  # run_ok accepts shell text; quote each argument before passing it through.
  for arg do
    arg=$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")
    command_text="$command_text '$arg'"
  done
  # slib's command log path must have no spaces; merge it into the main log.
  local RUN_LOG result
  RUN_LOG=$(mktemp "$CLOUDMIN_INSTALL_TEMPDIR/command.XXXXXX") || fail 'Cannot create command log'
  run_ok "$command_text" "$message"
  result=$?
  cat "$RUN_LOG" >>"$log"
  rm -f "$RUN_LOG"
  [ "$result" -eq 0 ] || fail "$message failed; see $log"
}

# load_slib() Loads logging, prompts, progress and swap helpers.
load_slib() {
  if [ -f "$script_dir/slib.sh" ]; then
    library="$script_dir/slib.sh"
  else
    library="$CLOUDMIN_INSTALL_TEMPDIR/slib.sh"
    fetch "https://$download_cloudmin_host_lib/slib.sh" "$library"
  fi
  # The shared logger initializes terminal colors even for unattended runs.
  TERM=${TERM:-dumb}; export TERM
  # slib writes terminal probes and spinner state in the current directory.
  cd "$CLOUDMIN_INSTALL_TEMPDIR" || fail 'Cannot enter temporary directory'
  . "$library"
  LOG_PATH=$log; RUN_LOG=$log; LOG_LEVEL_LOG=DEBUG
  RUN_ERRORS_FATAL=
  SPINNER_DONEFILE="$CLOUDMIN_INSTALL_TEMPDIR/stopspinning"
  LOG_LEVEL_STDOUT=INFO
  [ "$VERBOSE" != 1 ] || LOG_LEVEL_STDOUT=DEBUG
  # The shared library has terminal cleanup traps; own our task directory here.
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  trap 'exit 131' QUIT
  if [ -z "$noswap$setup$uninstall_mode" ] && [ "${SLIB_SWAP_API:-0}" != 2 ]; then
    fail 'The loaded utility library does not support swap management. Update slib.sh.'
  fi
}

# swap_abort() Is called by the shared library if its safety checks fail.
swap_abort() {
  if [ -z "$swap_only" ]; then
    log_error "Re-run the installer with --no-swap${swapsize:+ instead of --swap} to skip swap setup."
  fi
  exit 1
}

# confirm(prompt) Uses the shared yes/no prompt and restores terminal echo.
confirm() {
  [ "$skipyesno" = 1 ] && return 0
  [ -t 0 ] || fail 'Use --yes for unattended installation'
  printf '%s' "$1"
  yesno
  local result=$?
  stty echo 2>/dev/null || :
  return "$result"
}

# repositories() Uses the current shared Webmin repository bootstrap and group IDs.
repositories() {
  if [ "$manager" = apt-get ]; then
    run 'Refreshing distribution metadata' apt-get update
    run 'Installing repository prerequisites' apt-get -y install ca-certificates curl gnupg
    if [ "$ID" = ubuntu ]; then
      run 'Installing repository tools' apt-get -y install software-properties-common
      run 'Enabling Ubuntu universe' add-apt-repository -y universe
    fi
  else
    # Existing curl-minimal is sufficient; do not force replacement with curl.
    if ! command -v curl >/dev/null 2>&1; then
      run 'Installing the repository HTTP client' dnf -y install curl
    fi
    run 'Installing repository prerequisites' dnf -y install ca-certificates dnf-plugins-core
    run 'Enabling CRB' dnf config-manager --set-enabled crb
    run 'Installing EPEL configuration' dnf -y install epel-release
  fi
  bootstrap="$CLOUDMIN_INSTALL_TEMPDIR/setup-repo.sh"
  fetch 'https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh' "$bootstrap"
  run 'Configuring Webmin repository' sh "$bootstrap" --force "--$branch" \
    "--host=$download_webmin_host" "--unstable-host=$download_webmin_host_dev"
  # Stable Webmin supplies the signing key; Cloudmin uses its own repository name.
  run 'Configuring Cloudmin repository' sh "$bootstrap" --force "--$branch" \
    --name=cloudmin --dist=cloudmin --description=Cloudmin --component=main \
    "--host=$download_cloudmin_host" "--unstable-host=$download_cloudmin_host_dev" \
    "--key-server=https://$download_webmin_host" \
    --check-binary=0 --install-packages=cloudmin-config
  if [ "$manager" = apt-get ]; then
    run 'Refreshing package metadata' apt-get update
  else
    run 'Refreshing package metadata' dnf -y makecache --refresh
  fi
}

# configure() Passes validated plugin lists as arguments, without evaluating shell text.
configure() {
  set -- --bundle KVM --log "$log"
  if [ -n "$includes" ]; then
    set -- "$@" --include
    for plugin in $(printf '%s' "$includes" | tr ',' ' '); do set -- "$@" "$plugin"; done
  fi
  if [ -n "$excludes" ]; then
    set -- "$@" --exclude
    for plugin in $(printf '%s' "$excludes" | tr ',' ' '); do set -- "$@" "$plugin"; done
  fi
  log_info 'Checking KVM appliance boot (3-minute timeout)'
  # Show the failed check and its advice as well as retaining the complete log.
  if ! cloudmin-config-system "$@"; then
    tail -n 30 "$log" >&2
    fail "Cloudmin configuration or readiness failed; see $log"
  fi
}

phase() {
    phases_total="${phases_total:-4}"
    phase_description="$1"
    phase_number="$2"
    # Print completed phases (green)
    printf "${GREEN}"
    for i in $(seq 1 $(( phase_number - 1 ))); do
        printf "▣"
    done
    # Print current phase (yellow)
    printf "${YELLOW}▣"
    # Print remaining phases (cyan)
    for i in $(seq $(( phase_number + 1 )) "$phases_total"); do
        printf "${CYAN}◻"
    done
    log_debug "Phase ${phase_number} of ${phases_total}: ${phase_description}"
    printf "${NORMAL} Phase ${YELLOW}${phase_number}${NORMAL} of ${GREEN}${phases_total}${NORMAL}: ${phase_description}\\n"
}

# install_logo() displays an inline logo and leaves room for the welcome text.
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
  logo_heading="     Welcome to the Cloudmin GPL installer, version $VER"
  [ "$logo_cols" -ge "${#logo_heading}" ] && [ "$logo_rows" -ge 16 ] || return 1

  # Reserve a row for iTerm2's cursor movement, then draw at the text margin.
  printf '\n\033[1A\033[3G\0337'
  # Transparent 64x64 PNG from authentic-theme-src/.art/Logos/svgs/cloudmin.svg,
  # rendered in Cloudmin orange and embedded to avoid a download.
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
iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAAElBMVEX////mfjjmfjfmfjnmfzjl
fjjCGAUrAAAAAXRSTlMAQObYZgAAAQRJREFUWMPtltsSwyAIRKFL//+X2ziTRAUR4lM7bjs+GPYE
vIZo6y/FlfLuF/dK2cGGoHPE9zfJfZiFkxu7Qvl75VkPeCIx/Zm8dJwesSrxY+xYyqsFdq5CWkZl
d3cXY0+uVxyaEPH9B0BKWxrcUF2/enZ28A1gFWTljAggPPsTQGhFWwBpAUgD0AJ4DuCrrUjnHHJO
eghyfqwCaBFAiwB6CBAR6yiJzsJ4t4VSsLZrfCENAN1Spqzf3Y0U8esDrTEEANaJVF1emPppEjEH
uKe6mib3Hd6dS/SMgBBgeGtfvSAKEy7GG25tHiG4BOOEiD/4ieMLa/ZDi595qpK8e2tr63f1ARDU
BfC/l29+AAAAAElFTkSuQmCC
CLOUDMIN_LOGO_PNG
  # Start the welcome text on the same row, one space after the icon.
  printf '\0338\033[3C'
)

install_msg() {
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
Welcome to the ${ORANGE}${BOLD}Cloudmin GPL${NORMAL} installer, version ${ORANGE}${BOLD}$VER${NORMAL}

  This script must be run on a freshly installed supported OS. It does not
  perform updates or upgrades (use your system package manager) or license
  changes (use System Settings / License Manager in Cloudmin).

EOF
  cat <<EOF
  The systems currently supported by the install script are:

EOF
  echo "$supported"
  # Include the optional swap plan in the installation summary below.
  swap_note=""
  if [ "${SLIB_SWAP_API:-0}" = 2 ] && [ -z "$setup$noswap" ] &&
     swap_plan "$disk_space_required"; then
    swap_note=$(swap_plan_message)
  fi
  cat <<EOF
  If your OS/version/arch is not listed, installation ${BOLD}${RED}will fail${NORMAL}. More
  details about the systems supported by the script can be found here:

    ${UNDERLINE}https://www.cloudmin.com/docs/os-support/${NORMAL}

EOF
  # Wrap the complete paragraph to match the surrounding text. Count plain
  # characters before adding color, keeping each size and its unit together.
  # The first input line contains the disk estimate; later sizes describe swap.
  printf '%s\n' \
    "The installation will require up to $disk_space_required GiB of disk space." \
    "${swap_note:+$swap_note }The selected" \
    "package bundle is $bundle. More details" \
    "about installation can be found here:" |
    awk -v cyan="$CYAN" -v yellow="$YELLOW" -v normal="$NORMAL" \
        -v bundle="$bundle" '
      {
        for (i = 1; i <= NF; i++) {
          word = $i
          display = word
          if (word ~ /^[0-9]+$/ && i < NF && $(i + 1) ~ /^[GM]iB[.]?$/) {
            unit = $(++i)
            suffix = (unit ~ /[.]$/ ? "." : "")
            sub(/[.]$/, "", unit)
            word = word " " unit
            display = (NR == 1 ? cyan : yellow) word normal suffix
            word = word suffix
          } else if (word == bundle ".") {
            display = cyan bundle normal "."
          }
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

  if [ "$skipyesno" -ne 1 ]; then
  cat <<EOF
  Exit and re-run this script with ${CYAN}--help${NORMAL} flag to see available options.

EOF
  fi
  if [ "$skipyesno" -ne 1 ]; then
    if ! confirm " Continue? (y/n) "; then
      exit
    fi
  fi
}

unstable_repos_system_msg() {
  # Development builds skip the unstable warning and its extra confirmation.
  if [ "${CLOUDMIN_DEVELOPMENT:-0}" != 1 ] && [ "$branch" = "unstable" ]; then
    cat <<EOF

  ${REDBG}${WHITE}${BOLD} DANGER ${NORMAL}

  You have enabled the unstable development branch, where packages are built
  automatically with every commit to the repositories of each product we
  offer. This branch is strictly for testing and development purposes
  and must not be used in a production environment!

EOF

    if [ "$skipyesno" -ne 1 ]; then
      if ! confirm " Continue with $branch branch? (y/n) "; then
        exit
      fi
    fi
  fi
}

preconfigured_system_msg() {
  # Double check if installed, just in case above error ignored.
  is_preconfigured_rs=$(is_preconfigured)
  if [ -n "$is_preconfigured_rs" ]; then
    cat <<EOF

  ${WHITEBG}${RED}${BOLD} ATTENTION ${NORMAL}

  Pre-installed software detected: $is_preconfigured_rs

  It is highly advised ${BOLD}${RED}not to pre-install${NORMAL} any additional packages on your
  OS. The installer expects a freshly installed OS, and anything you do
  differently might cause conflicts or configuration errors. If you need
  to enable third-party package repositories, do so after installation
  of Cloudmin, and only with extreme caution.

EOF
    if [ "$skipyesno" -ne 1 ]; then
      if ! confirm " Continue? (y/n) "; then
        exit
      fi
    fi
  fi
}

is_preconfigured() {
  preconfigured=""
  if named -v 1>/dev/null 2>&1; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}BIND${NORMAL} "
  fi
  if apachectl -v 1>/dev/null 2>&1; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}Apache${NORMAL} "
  fi
  if nginx -v 1>/dev/null 2>&1; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}Nginx${NORMAL} "
  fi
  if command -pv mariadb 1>/dev/null 2>&1; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}MariaDB${NORMAL} "
  fi
  if postconf mail_version 1>/dev/null 2>&1; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}Postfix${NORMAL} "
  fi
  if php -v 1>/dev/null 2>&1; then
    preconfigured="${preconfigured}${YELLOW}${BOLD}PHP${NORMAL} "
  fi
  preconfigured=$(echo "$preconfigured" | sed 's/ /, /g' | sed 's/, $/ /')
  echo "$preconfigured"
}

# is_installed() Detects an existing Cloudmin installation.
is_installed() {
  [ -f /etc/webmin/server-manager/config ]
}

already_installed_block() {
  log_error "Your system already has a successful Cloudmin installation deployed."
  log_error "Re-installation is neither possible nor necessary. This script must be"
  log_error "run on a freshly installed supported operating system. It is not meant"
  log_error "for package updates or license changes. For further assistance, please"
  log_error "visit the Cloudmin Community forum."
  exit 100
}

# already_installed_msg() Warns before an explicitly requested reinstall.
already_installed_msg() {
  if is_installed; then
    cat <<EOF

  ${WHITEBG}${RED}${BOLD} WARNING ${NORMAL}

  If Cloudmin is already installed successfully, ${BOLD}${RED}do not${NORMAL} run this
  script again to fix problems, upgrade, or change the license!

  Updates and upgrades must be performed from within Cloudmin or by
  using your system package manager on the command line.
  Change licenses in System Settings / License Manager.

EOF
    confirm ' Continue? (y/n) ' || exit 0
  fi
}

# install_cloudmin() Installs the KVM stack and checks configuration API versions.
install_cloudmin() {
  [ -n "$no_updates" ] || run 'Checking and installing system package updates' "$manager" -y upgrade
  [ -z "$hostname_arg" ] || run 'Setting the host name' hostnamectl set-hostname "$hostname_arg"
  # One transaction installs both the core and the architecture's KVM runtime.
  if [ "$manager" = apt-get ]; then
    set -- -y --no-install-recommends install cloudmin-core cloudmin-kvm-stack
  else
    set -- -y --setopt=strict=1 --setopt=install_weak_deps=False \
      --setopt=optional_metadata_types=filelists install @cloudmincore @cloudmin-kvm \
      'cloudmin-config >= 10.0.0' 'webmin >= 2.670'
  fi
  for package in $(printf '%s' "$extra" | tr ',' ' '); do set -- "$@" "$package"; done
  run 'Installing Cloudmin and the KVM stack' "$manager" "$@"
  if [ "$manager" = apt-get ]; then
    config_version=$(dpkg-query -W -f='${Version}' cloudmin-config) || fail 'cloudmin-config is missing'
    webmin_version=$(dpkg-query -W -f='${Version}' webmin) || fail 'Webmin is missing'
    run 'Checking the configuration package version' dpkg --compare-versions "$config_version" ge 10.0.0
    run 'Checking the Webmin version' dpkg --compare-versions "$webmin_version" ge 2.670
  else
    run 'Checking the configuration package version' rpm -q --whatprovides 'cloudmin-config >= 10.0.0'
    run 'Checking the Webmin version' rpm -q --whatprovides 'webmin >= 2.670'
  fi
}

# post_install_message() Shows the login URL after installation succeeds.
post_install_message() {
  log_success "Installation Complete!"
  log_success "Cloudmin is ready at https://${hostname_arg:-$(hostname -f)}:10000."
  log_warning "You will see a security warning in the browser on your first visit."
}

# load_module() Loads a local module before configuration starts.
load_module() {
  [ -n "$module_name" ] || return 0
  bind_hook modules_pre || return $?
  . "$script_dir/$module_name.sh" || return $?
  bind_hook modules_post
}

# extra_phases() Runs tab-separated number, name, command and description rows.
extra_phases() {
  [ -n "$hooks__phases" ] || return 0
  bind_hook phases_pre || return $?
  printf '%s\n' "$hooks__phases" > "$CLOUDMIN_INSTALL_TEMPDIR/phases"
  local number name command_text description previous=''
  while IFS="$(printf '\t')" read -r number name command_text description; do
    [ -n "$number" ] || continue
    if [ "$number" != "$previous" ]; then
      printf '\n'
      bind_hook phase "$name" "$number" || return $?
      previous=$number
    fi
    run "$description" eval "$command_text" || return $?
  done < "$CLOUDMIN_INSTALL_TEMPDIR/phases"
  bind_hook phases_post
}

# uninstall() Removes Cloudmin packages without deleting virtual machine data.
uninstall() {
  if [ "$skipyesno" -ne 1 ]; then
    cat <<EOF

  ${REDBG}${BLACK}${BOLD} WARNING ${NORMAL}

  This operation removes Cloudmin packages and repository configuration.
  Virtual machine disks and the shared Webmin installation are kept.
  It must never be executed on a live production system!

EOF
    confirm " ${RED}Uninstall?${NORMAL} (y/N) " || return 0
  fi
  phases_total=1
  bind_hook phase Uninstall 1 || return $?
  if [ "$manager" = apt-get ]; then
    run 'Uninstalling Cloudmin packages' apt-get -y remove cloudmin-core cloudmin-kvm-stack cloudmin-config webmin-server-manager
  else
    run 'Uninstalling Cloudmin packages' dnf -y --setopt=clean_requirements_on_remove=False remove cloudmin-config webmin-server-manager
  fi
  for repo in cloudmin cloudmin-stable cloudmin-unstable; do
    rm -f "/etc/apt/sources.list.d/$repo.list" "/etc/apt/sources.list.d/$repo.sources" \
      "/etc/apt/auth.conf.d/$repo.conf" "/etc/yum.repos.d/$repo.repo" || return $?
  done
  log_success 'Cloudmin uninstallation complete.'
}

test_connection() {
  input="$1"
  ip_version="$2"
  ip_version_nice=$(echo "$ip_version" | sed 's/ip/IP/')
  timeout=5
  http_protocol="http"
  http_protocol_nice=$(echo "$http_protocol" | tr '[:lower:]' '[:upper:]')

  # Setup colors for messages
  GREEN="" BLACK="" RED="" RESET="" BOLD="" GRBG="" REDBG=""
  if command -pv 'tput' > /dev/null; then
    GREEN=$(tput setaf 2)
    BLACK=$(tput setaf 0)
    RED=$(tput setaf 1)
    RESET=$(tput sgr0)
    BOLD=$(tput bold)
    GRBG=$(tput setab 22; tput setaf 10)
    REDBG=$(tput setab 52; tput setaf 9)
  fi

  # Extract the domain from the input
  domain=$(echo "$input" | awk -F[/:] '{print $4}')
  [ -z "$domain" ] && domain="$input"

  # Validate parameters
  if [ -z "$domain" ] || [ -z "$ip_version" ]; then
    echo "${RED}[ERROR]  ${RESET} Domain and IP version are required" >&2
    return 1
  fi

  # Setup protocol-specific flags
  case "$ip_version" in
    ipv4)
      if ! getent ahostsv4 "$domain" >/dev/null 2>&1; then
        echo "${RED}[ERROR]  ${RESET} ${BOLD}$domain${RESET} — cannot find IPv4 address" >&2
        return 1
      fi
      ping_cmd="ping -c 1 -W $timeout $domain"
      http_cmd="curl -sS --ipv4 --max-time $timeout --head $http_protocol://$domain \
        || wget --spider -4 -T $timeout $http_protocol://$domain"
      ;;
    ipv6)
      if ! getent ahostsv6 "$domain" >/dev/null 2>&1; then
        echo "${RED}[ERROR]  ${RESET} ${BOLD}$domain${RESET} — cannot find IPv6 address" >&2
        return 1
      fi
      ping_cmd="ping6 -c 1 -W $timeout $domain"
      http_cmd="curl -sS --ipv6 --max-time $timeout --head $http_protocol://$domain \
        || wget --spider -6 -T $timeout $http_protocol://$domain"
      ;;
  esac

  # Try ping first
  if eval "$ping_cmd" >/dev/null 2>&1; then
    echo "${GREEN}[SUCCESS]${RESET} ${GRBG}[$ip_version_nice]${RESET} ${GRBG}[ICMP]${RESET} ${BOLD}$domain${RESET}"
  else
    echo "${RED}[ERROR]  ${RESET} ${REDBG}[$ip_version_nice]${RESET} ${REDBG}[ICMP]${RESET} ${BOLD}$domain${RESET}"
  fi

  # HTTP test as well
  if command -v 'curl' > /dev/null || command -v 'wget' > /dev/null; then
    if eval "$http_cmd" >/dev/null 2>&1; then
      echo "${GREEN}[SUCCESS]${RESET} ${GRBG}[$ip_version_nice]${RESET} ${GRBG}[$http_protocol_nice]${RESET} ${BOLD}$domain${RESET}"
      return 0
    else
      echo "${RED}[ERROR]  ${RESET} ${REDBG}[$ip_version_nice]${RESET} ${REDBG}[$http_protocol_nice]${RESET} ${BOLD}$domain${RESET}"
      return 1
    fi
  fi
}

# check_connections() Tests repository connectivity without installing anything.
check_connections() {
  local host protocol result=0
  for host in "$download_webmin_host_dev" "$download_cloudmin_host_dev"; do
    for protocol in $connect; do test_connection "$host" "$protocol" || result=1; done
  done
  return "$result"
}

# main(args...) Runs installation or the requested standalone operation.
main() {
  bind_hook parse_args "$@" || fail 'Cannot parse installation options'
  [ -z "$showversion" ] || { bind_hook show_version; return $?; }
  if [ "${CLOUDMIN_SETUP_ONLY:-0}" = 1 ]; then
    setup=1; swap_only=; noswap=1; swapsize=; uninstall_mode=; connect=
  fi
  [ -z "$connect" ] || { bind_hook check_connections; return $?; }
  [ -z "$swap_only" ] || [ -z "$noswap" ] || { printf 'System swap left unchanged.\n'; return 0; }
  bind_hook preflight || fail 'System checks failed'
  script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || fail 'Cannot find installer directory'
  [ -z "$module_name" ] || [ -f "$script_dir/$module_name.sh" ] || fail "Module not found: $module_name.sh"
  umask 077
  mkdir -p -- "$log_dir" || fail 'Cannot create the log directory'
  log="$log_dir/cloudmin-install.log"
  [ -z "$setup" ] || log="$log_dir/cloudmin-repos-setup.log"
  [ -z "$uninstall_mode" ] || log="$log_dir/cloudmin-uninstall.log"
  [ -z "$swap_only" ] || log="$log_dir/cloudmin-swap.log"
  # Preserve logs from previous runs.
  if [ -e "$log" ]; then
    logcnt=1
    while [ -e "$log.$logcnt" ]; do logcnt=$((logcnt+1)); done
    mv "$log" "$log.$logcnt" || fail 'Cannot rotate the log file'
  fi
  touch "$log" || fail 'Cannot open the log file'
  CLOUDMIN_INSTALL_TEMPDIR=$(mktemp -d /var/tmp/cloudmin-install.XXXXXX) || fail 'Cannot create temporary directory'
  export CLOUDMIN_INSTALL_TEMPDIR
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  bind_hook load_slib || fail 'Cannot load the utility library'
  disk_space_required=4
  if [ -n "$swap_only" ]; then
    log_info "Swap setup log is written to $LOG_PATH"
    log_info 'Started swap setup'
    swap_plan 0 || { log_error "$swap_error"; swap_abort; }
    if [ "$swap_action" = none ]; then
      log_success 'System swap left unchanged.'
      return 0
    fi
    log_info "$(swap_plan_message)" |
      sed "s/[0-9][0-9]* [GM]iB/${YELLOW}&${NORMAL}/g"
    if ! confirm 'Apply these swap changes? (y/n) '; then
      log_info 'Swap setup cancelled; system swap left unchanged.'
      return 0
    fi
    swap_setup 0 || swap_abort
    log_success 'Swap setup completed successfully.'
    return 0
  fi
  if [ -n "$uninstall_mode" ]; then
    log_info "Uninstallation log is written to $LOG_PATH"
    bind_hook uninstall || fail "Uninstallation failed; see $log"
    return 0
  fi
  if [ -n "$setup" ]; then
    log_info "Setup log is written to $LOG_PATH"
    log_info 'Started Cloudmin 10 GPL software repositories setup'
  else
    log_info "Installation log is written to $LOG_PATH"
    [ -n "$noswap" ] || swap_plan "$disk_space_required" || { log_error "$swap_error"; swap_abort; }
    if [ -z "$skipbanner" ]; then
      bind_hook install_msg || fail 'Cannot display installation summary'
      bind_hook unstable_repos_system_msg || fail 'Cannot display repository warning'
      bind_hook preconfigured_system_msg || fail 'Cannot check pre-installed software'
      bind_hook already_installed_msg || fail 'Cannot check existing installation'
    fi
  fi
  bind_hook phases_all_pre || fail 'Installation hook failed'
  if [ -z "$setup" ]; then
    printf '\n'
    bind_hook phase Check 1 || fail 'Phase hook failed'
    bind_hook phase1_pre || fail 'Check hook failed'
    run 'Checking operating system and KVM support' bind_hook preflight
    bind_hook phase1_post || fail 'Check hook failed'
    printf '\n'
    bind_hook phase Setup 2 || fail 'Phase hook failed'
    bind_hook phase2_pre || fail 'Setup hook failed'
    [ -n "$noswap" ] || swap_setup "$disk_space_required" || swap_abort
  fi
  bind_hook repositories || fail "Repository setup failed; see $log"
  if [ -n "$setup" ]; then
    bind_hook phases_all_post || fail 'Setup hook failed'
    log_success 'Cloudmin repository is configured successfully.'
    return 0
  fi
  bind_hook phase2_post || fail 'Setup hook failed'
  printf '\n'
  bind_hook phase Installation 3 || fail 'Phase hook failed'
  bind_hook phase3_pre || fail 'Installation hook failed'
  bind_hook install_cloudmin || fail "Package installation failed; see $log"
  bind_hook phase3_post || fail 'Installation hook failed'
  bind_hook load_module || fail 'Post-install module failed'
  printf '\n'
  bind_hook phase Configuration 4 || fail 'Phase hook failed'
  bind_hook phase4_pre || fail 'Configuration hook failed'
  bind_hook configure || fail "Cloudmin configuration failed; see $log"
  bind_hook phase4_post || fail 'Configuration hook failed'
  bind_hook extra_phases || fail 'Additional installation phase failed'
  bind_hook phases_all_post || fail 'Installation hook failed'
  bind_hook clean_pre || fail 'Cleanup hook failed'
  printf '%s▣▣▣%s Cleaning up\n' "$GREEN" "$NORMAL"
  cd "$script_dir" || fail 'Cannot leave temporary directory'
  rm -rf -- "$CLOUDMIN_INSTALL_TEMPDIR" || fail 'Cannot remove temporary directory'
  CLOUDMIN_INSTALL_TEMPDIR=
  bind_hook clean_post || fail 'Cleanup hook failed'
  printf '\n'
  bind_hook post_install_message || fail 'Post-install message hook failed'
}

main "$@"
