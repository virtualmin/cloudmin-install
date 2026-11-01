# Cloudmin installer

Installs Cloudmin 10 on a fresh **Rocky Linux 10**, **AlmaLinux 10**,
**Debian 13** or **Ubuntu 26.04** host, on x86-64 or ARM64. A working `/dev/kvm`
and systemd are required. Enable nested KVM when installing inside UTM or
another hypervisor. Only stock hypervisor packages are used.

```sh
sh cloudmin-install.sh --yes
sh cloudmin-install.sh --yes --swap 4G
sh cloudmin-install.sh --swap-only --swap 2G
sh cloudmin-install.sh --swap-only --swap 0
sh cloudmin-install.sh --setup --yes
```

Cloudmin 10 currently uses only the `unstable` repository channel (`devel` is
an alias). HTTPS download errors, missing packages and failed configuration
steps stop installation.

`CLOUDMIN_DEVELOPMENT` is enabled at the top of the script. It hides `--branch`
from help and skips the unstable repository warning and its confirmation.
Set `CLOUDMIN_DEVELOPMENT=0` in the environment, or remove its declaration, to
restore the normal help and warning. The default branch remains `unstable`.

```sh
CLOUDMIN_DEVELOPMENT=0 sh cloudmin-install.sh --help
```

Override download hosts with these environment variables:
`download_cloudmin_host` (currently `download.cloudmin.dev`),
`download_cloudmin_host_dev` (defaults to `download_cloudmin_host`),
`download_webmin_host` (`download.webmin.com`) and
`download_webmin_host_dev` (`download.webmin.dev`). The unstable branch sets
`download_cloudmin_host_lib` to `download_cloudmin_host_dev`, using that host for
both packages and `slib.sh`. Webmin packages use `download_webmin_host_dev`; the signing key comes
from `download_webmin_host`. `--connect` checks the selected repository hosts.

```sh
download_cloudmin_host_dev=mirror.example.com sh cloudmin-install.sh --setup --yes
```

The script uses Webmin's current repository setup helper. On RPM hosts it
enables CRB and EPEL, then installs `cloudmincore` and `cloudmin-kvm`. On Debian
and Ubuntu it installs `cloudmin-core` and the native `cloudmin-kvm-stack` DEB;
Ubuntu universe is enabled for the Perl virtualization bindings. Dependencies
are installed in one transaction and failures stop the installer.
Etckeeper is installed for configuration history. BIND and Postfix are not
installed or configured; additional services can be managed through Webmin.

Cloudmin-Config prefers modular libvirt, using stock monolithic libvirtd when
modular binaries are absent. It configures NAT, storage, firmware, Webmin,
nftables and Fail2ban through Webmin APIs, then checks readiness. SELinux stays
enforcing. The installer requires configuration package **10.0.0 or newer**,
Webmin with the systemd `get_unit_state` API, and the matching Cloudmin module,
DEB meta packages and RPM groups. Publish these together before installing
from the public repository.

Before reporting success, Cloudmin-Config boots a temporary, isolated KVM
inspection appliance on the target host. The worker has a three-minute timeout
and a 2 GiB memory limit. A failed boot stops installation and shows the end of
the configuration log; already installed packages are not rolled back.

Ubuntu 26.04 remains supported when this check passes. A boot failure has been
reproduced with Ubuntu kernel 7.0.0-34 under ARM64 Apple/UTM nested virtualization;
a physical AMD x86-64 host running Ubuntu 26.04.1 with that kernel passes the
appliance and guest boot tests without workarounds. Physical ARM64 remains
untested. For the affected UTM environment, use a tested Rocky Linux 10 or Debian
13 host, or retry after kernel or hypervisor updates. The installer does not
disable guest interrupt features or reject a kernel version. Passing the check
verifies appliance boot, not all VM workloads.

Swap controls require `slib.sh` API version 2.
The library is fetched from `https://download.cloudmin.dev/slib.sh`, or read
from a trusted `slib.sh` beside the installer. Sizes accept MiB or K/M/G suffixes,
with optional B. Without a size, the library chooses swap from available RAM,
existing swap and disk space. `--no-swap` leaves it alone. `--swap 0` removes
only installer-managed swap. The shared managed paths remain `/swap.vm` and,
on Btrfs, `/swap.virtualmin/swapfile`; unrelated swap is never removed.

`--swap-only` does not install packages or configure repositories or services.
It can run on an already installed Linux host. `--setup` only configures repos
and their prerequisites; it does not change swap. `CLOUDMIN_SETUP_ONLY=1` forces
that mode.

Use `--help` for all options. Logs are private and retained in `/root` by default;
`--log-dir` selects another absolute directory. These are fresh installations,
not Cloudmin 9 migrations. Use the package manager for subsequent updates.

## Interface and options

The installer shows progress through four installation phases and logs each
step. `--swap-only` shows a swap plan for confirmation and exits before any
repository, package or service changes.

Available controls:

- `--force-reinstall|-fr` allows an explicit rerun on an installed host. It does
  not answer prompts or change what `--swap-only` does.
- `--force|-f|--yes|-y` answers yes to prompts; `--no-banner|-nb` suppresses the
  installation banner and warnings.
- `--verbose|-V` enables debug output; `--version|-v` prints the version.
- `--extra|-E`, `--include|-i` and `--exclude|-e` select packages and plugins.
- `--module|-o <name>` loads `<name>.sh` beside the installer after package
  installation, before configuration.
- `--connect|-C [ipv4|ipv6]` tests download connectivity without installing.
- `--insecure-downloads|-I` skips certificate checks for installer downloads.
- `--uninstall|-u` removes Cloudmin packages and repositories. It keeps VM disks,
  shared Webmin and hypervisor packages; it does not remove their dependencies.

The only installation bundle is `KVM`. The installer accepts only the supported
operating systems listed above.

The welcome banner includes an embedded Cloudmin logo. Kitty, Ghostty and
iTerm2 display it when there is room. Other terminals, multiplexers, redirected output, unattended sessions
and `NO_COLOR` use the text banner. No image download is needed.

## Hooks

Wrappers can define `hook__name` to replace a function, or `pre_hook__name` and
`post_hook__name` to run before and after it. Arguments are passed unchanged.
An override replaces all three calls. A failed hook stops that operation;
post-hooks do not hide failures.

For example, place this wrapper beside the installer:

```sh
#!/bin/sh
post_hook__install_msg() {
  printf '%s\n' 'Installing this host for the lab'
}
hook__phase4_post() {
  printf '%s\n' 'Cloudmin configuration finished'
}
. ./cloudmin-install.sh
```

Available lifecycle hooks include `parse_args`, `usage`,
`show_version`, `install_msg`, `already_installed_block`, `already_installed_msg`,
`unstable_repos_system_msg`, `preconfigured_system_msg`, `phases_all_pre`,
`phase1_pre` through `phase4_post`, `modules_pre`, `modules_post`, `phases_pre`,
`phases_post`, `phases_all_post`, `clean_pre`, `clean_post` and
`post_install_message`. Cloudmin also dispatches `preflight`, `repositories`,
`install_cloudmin` and `configure` through `bind_hook`.

A module can set `hooks__phases` to tab-separated rows containing a phase number,
phase name, shell command and description, and set `phases_total` for the phase
display. These phases run after configuration. Modules and wrappers are trusted
shell code running as root. Standalone swap does not run installation hooks.

## Tests

```sh
sh -n cloudmin-install.sh
shellcheck cloudmin-install.sh
python3 t/installer.py
```

The tests model host-changing commands and check option validation, the OS
matrix, swap-only/setup paths, and failure propagation. Real installation and
swap tests belong on disposable Linux VMs.

On a disposable Linux VM with no installer-managed swap, the terminal test
checks graphics protocols, text fallbacks, hooks, successful and failed install
steps, swap cancellation and an optional 64 MiB create/remove cycle. Package
commands use fixtures; it does not perform a full installation.

```sh
python3 t/live-ui.py --installer ./cloudmin-install.sh --slib ./slib.sh --live-swap
```

Add `--config-lib /path/to/cloudmin-config/lib` to test configuration progress
and cursor cleanup after a failed plugin too.
