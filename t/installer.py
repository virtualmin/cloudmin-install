#!/usr/bin/env python3
"""Exercise argument handling and orchestration without administering the host."""
import os
import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'cloudmin-install.sh'
FUNCTIONS = SOURCE.read_text().rsplit('\nmain "$@"', 1)[0]

HARNESS = r'''
pre_check_all() { ID=${TEST_ID:-rocky}; PRETTY_NAME=fixture; manager=${TEST_MANAGER:-dnf}; }
is_installed() { return 1; }
manage_cloudmin_branch_repos() { echo REPOSITORIES; [ "$TEST_FAIL" != repository ]; }
install_msg() { echo "BANNER $PRODUCT"; }
unstable_repos_system_msg() { :; }
preconfigured_system_msg() { :; }
download_slib() {
  LOG_PATH=$log; RUN_LOG=$log
  log_debug() { :; }
  serial_ok() { printf '%s\n' "$1" "$2" > "$cloudmin_license_file.checked"; }
  log_info() { echo "[INFO] $1"; echo "[INFO] $1" >> "$LOG_PATH"; }
  log_success() { echo "[SUCCESS] $1"; }
  log_warning() { echo "[WARNING] $1"; }
  swap_plan() { swap_action=create; [ "$1" = 4 ] || [ "$1" = 0 ] || exit 91; }
  swap_plan_message() { echo PLAN; }
  swap_setup() { echo SWAP; [ "$TEST_FAIL" != swap ]; }
}
run_ok() {
  printf 'RUN: %s: %s\n' "$2" "$1"
  [ "$TEST_FAIL:$2" != 'package:Installing Cloudmin and the KVM stack' ]
}
hostname() { echo fixture.example.test; }
mktemp() { mkdir "$TEST_DIR/work"; echo "$TEST_DIR/work"; }
TEST_DIR=$1; TEST_FAIL=$2; TEST_MANAGER=$3; shift 3
export TEST_FAIL
cloudmin_license_file="$TEST_DIR/license"
mkdir "$TEST_DIR/bin"
printf '%s\n' '#!/bin/sh' 'echo 99.0.0' > "$TEST_DIR/bin/dpkg-query"
chmod +x "$TEST_DIR/bin/dpkg-query"
printf '%s\n' '#!/bin/sh' 'printf "CONFIGURE %s\n" "$*"' '[ "$TEST_FAIL" != config ]' > "$TEST_DIR/bin/cloudmin-config-system"
chmod +x "$TEST_DIR/bin/cloudmin-config-system"
PATH="$TEST_DIR/bin:$PATH"
'''

class InstallerTests(unittest.TestCase):
    def shell(self, code, *args, env=None):
        environment = dict(os.environ, SERIAL='GPL', KEY='GPL')
        environment.update(env or {})
        # Direct firewall removal commands must never reach the real package manager.
        with tempfile.TemporaryDirectory(dir='/tmp') as directory:
            root = pathlib.Path(directory)
            for manager in ['apt-get', 'dnf']:
                tool = root / manager
                tool.write_text(r'''#!/bin/sh
case "${0##*/}:$*" in
  'apt-get:--quiet --assume-yes purge ufw firewalld'|'dnf:-y remove firewalld') ;;
  *) echo 'Unexpected package-manager call' >&2; exit 93 ;;
esac
[ -z "$TEST_PACKAGE_EVENTS" ] || printf 'REMOVE %s %s\n' "${0##*/}" "$*" >> "$TEST_PACKAGE_EVENTS"
printf 'Firewall removal output\n'
printf 'Firewall removal diagnostic\n' >&2
exit "${TEST_REMOVE_STATUS:-0}"
''')
                tool.chmod(0o700)
            environment['PATH'] = str(root) + os.pathsep + environment['PATH']
            environment['RUN_LOG'] = (env or {}).get('RUN_LOG', str(root / 'install.log'))
            return subprocess.run(['sh', '-c', FUNCTIONS + '\n' + code, 'test', *args],
                                  env=environment,
                                  text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_sizes(self):
        for value, expected in [('0',0), ('0008',8192), ('1K',1024), ('2MB',2048), ('2G',2097152), ('1gb',1048576)]:
            with self.subTest(value=value):
                p = self.shell('parse_args --swap "$1"; echo "$swapsize"', value)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stdout.strip(), str(expected))
        for value in ['-1', 'G', '+2', '1.5G', '1T', '1024G', '99999999999', '1;touch x']:
            self.assertNotEqual(self.shell('parse_args --swap "$1"', value).returncode, 0)

    def test_flags(self):
        for args in [('--swap',), ('--swap','1G','--no-swap'), ('--swap-only','--setup'),
                     ('--swap','0','--setup'), ('--swap-only','--extra','bind'),
                     ('--extra','--allowerasing'), ('--extra','bind;id'), ('--include','../Etckeeper'),
                     ('--log-dir','relative'), ('--branch','stable'), ('--branch','prerelease'),
                     ('--branch','pre-release'), ('--branch','rc'), ('--branch','release-candidate'), ('--unknown',)]:
            with self.subTest(args=args):
                self.assertNotEqual(self.shell('parse_args "$@"', *args).returncode, 0)
        for args in [('--setup','--no-swap'), ('--swap-only','--no-swap'), ('--include','Etckeeper,Fail2ban'),
                     ('--extra','bind,bind-utils'), ('--branch','unstable'), ('--branch','devel')]:
            self.assertEqual(self.shell('parse_args "$@"', *args).returncode, 0)

    def test_development_mode(self):
        # Check the environment override and removal of the optional declaration.
        declaration = 'CLOUDMIN_DEVELOPMENT="${CLOUDMIN_DEVELOPMENT:-1}"\n'
        self.assertEqual(FUNCTIONS.count(declaration), 1)
        code = r"""
parse_args
printf 'BRANCH %s\n' "$branch"
usage
REDBG=; WHITE=; BOLD=; NORMAL=
skipyesno=0
confirm() { echo "CONFIRM $1"; }
unstable_repos_system_msg
"""
        for remove, setting, enabled in [(False, None, True), (False, '1', True),
                                         (False, '0', False), (True, None, False),
                                         (True, '1', True), (True, '0', False)]:
            with self.subTest(remove=remove, setting=setting):
                source = FUNCTIONS.replace(declaration, '') if remove else FUNCTIONS
                environment = dict(os.environ)
                environment.pop('CLOUDMIN_DEVELOPMENT', None)
                if setting is not None:
                    environment['CLOUDMIN_DEVELOPMENT'] = setting
                result = subprocess.run(['sh', '-u', '-c', source + '\n' + code],
                                        env=environment, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, '')
                self.assertIn('BRANCH unstable', result.stdout)
                self.assertEqual('--branch|-B' in result.stdout, not enabled)
                self.assertEqual('DANGER' in result.stdout, not enabled)
                self.assertEqual('Continue with unstable branch?' in result.stdout,
                                 not enabled)

    def test_platforms(self):
        for os in ['rocky', 'almalinux']:
            for arch in ['aarch64', 'x86_64']:
                self.assertEqual(self.shell('supported_host "$@"', os, '10.2', arch).returncode, 0)
        for os, version, arch in [('debian','12','aarch64'), ('ubuntu','24.04','x86_64'),
                                  ('rocky','9.6','x86_64'), ('rocky','11','x86_64'), ('rocky','10.bad','aarch64'), ('almalinux','10','ppc64le')]:
            self.assertNotEqual(self.shell('supported_host "$@"', os, version, arch).returncode, 0)

        for os, version in [('debian', '13'), ('ubuntu', '26.04')]:
            for arch in ['aarch64', 'x86_64']:
                self.assertEqual(self.shell('supported_host "$@"', os, version, arch).returncode, 0)

    def test_failed_commands(self):
        # Package errors must survive run_ok and the format dispatcher.
        for kind in ['rpm', 'deb']:
            result = self.shell(r'''
package_type=$1; noupdates=1; install=false; install_cmd=dnf; extra_packages=
run_ok() { eval "$1"; }
install_cloudmin || exit $?
echo FALSE_SUCCESS
''', kind)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('FALSE_SUCCESS', result.stdout)

    def test_firewall_package_removal(self):
        # Remove competing packages after updates and before the stack; log all
        # output and continue if removal fails, as with absent packages.
        for kind in ['deb', 'rpm']:
            for removal_status, skip_updates, upgrade_failure in [(0, '', False), (100, '', False),
                                                                  (0, '1', False), (0, '', True)]:
                with self.subTest(kind=kind, removal_status=removal_status,
                                  skip_updates=skip_updates, upgrade_failure=upgrade_failure), \
                        tempfile.TemporaryDirectory(dir='/tmp') as directory:
                    root = pathlib.Path(directory)
                    events = root / 'events'
                    log = root / 'install.log'
                    result = self.shell(HARNESS + r"""
package_type=$1; noupdates=$2; install_cmd=dnf; install='fixture install'; upgrade='fixture upgrade'
run_ok() {
  printf 'STEP %s\n' "$2" >> "$TEST_PACKAGE_EVENTS"
  [ "$TEST_FAIL:$2" != 'upgrade:Checking and installing system package updates' ]
}
install_cloudmin
""", directory, 'upgrade' if upgrade_failure else '', 'dnf', kind, skip_updates,
                        env=dict(TEST_PACKAGE_EVENTS=str(events), TEST_REMOVE_STATUS=str(removal_status),
                                 RUN_LOG=str(log)))
                    self.assertEqual(result.returncode == 0, not upgrade_failure, result.stderr)
                    self.assertEqual(result.stdout, '')
                    self.assertEqual(result.stderr, '')
                    steps = events.read_text().splitlines()
                    upgrade = 'STEP Checking and installing system package updates'
                    if upgrade_failure:
                        self.assertEqual(steps, [upgrade])
                        self.assertFalse(log.exists())
                    else:
                        removal = ('apt-get --quiet --assume-yes purge ufw firewalld' if kind == 'deb'
                                   else 'dnf -y remove firewalld')
                        expected = ([] if skip_updates else [upgrade]) + [
                            'REMOVE ' + removal,
                            'STEP Installing Cloudmin and the KVM stack']
                        if kind == 'deb':
                            expected += ['STEP Checking the configuration package version',
                                         'STEP Checking the Webmin version']
                        self.assertEqual(steps, expected)
                        self.assertIn('Firewall removal output', log.read_text())
                        self.assertIn('Firewall removal diagnostic', log.read_text())

    def test_webmin_configured_before_modules(self):
        # Model dpkg's unpack/configure boundary: the module preinst needs a
        # previous Webmin transaction, not Webmin earlier in the same command.
        for extras, failure in [('', ''), ('curl', ''), ('curl', 'simulate'),
                                ('curl', 'webmin'), ('curl', 'extra'), ('', 'stack')]:
            with self.subTest(extras=extras, failure=failure), tempfile.TemporaryDirectory(dir='/tmp') as d:
                code = HARNESS + r"""
apt_fixture() {
  printf '%s\n' "$*" >> "$TEST_DIR/transactions"
  case " $* " in
    *' --simulate '*) [ "$TEST_FAIL" != simulate ]; return $? ;;
  esac
  case " $* " in
    *' cloudmin-core '*)
      [ -f "$TEST_DIR/webmin-configured" ] || return 95
      [ "$TEST_FAIL" != stack ] || return 9 ;;
    *' curl '*) [ "$TEST_FAIL" != extra ] || return 9 ;;
  esac
  case " $* " in
    *' webmin '*)
      [ "$TEST_FAIL" != webmin ] || return 9
      touch "$TEST_DIR/webmin-configured" ;;
  esac
}
run_ok() { eval "$1"; }
dpkg() { [ "$1" = --compare-versions ] && [ "$2" = 99.0.0 ]; }
package_type=deb; noupdates=1; install='apt_fixture install'; extra_packages=
[ -z "$1" ] || add_extra_packages "$1"
install_cloudmin
"""
                result = self.shell(code, d, failure, 'apt-get', extras)
                self.assertEqual(result.returncode == 0, not failure, result.stderr)
                transactions = (pathlib.Path(d) / 'transactions').read_text().splitlines()
                actual = [line for line in transactions if '--simulate' not in line]
                stack = 'install cloudmin-core cloudmin-kvm-stack'
                if not failure:
                    self.assertEqual(actual, ['install webmin'] +
                                     (['install curl'] if extras else []) + [stack])
                elif failure == 'simulate':
                    self.assertEqual(actual, [])
                elif failure in ['webmin', 'extra']:
                    self.assertNotIn(stack, actual)

    def test_readiness_result(self):
        for status in [0, 1]:
            with self.subTest(status=status), tempfile.TemporaryDirectory(dir='/tmp') as d:
                tool = pathlib.Path(d) / 'cloudmin-config-system'
                detail = ('KVM image appliance could not boot; fixture worker error'
                          if status else 'Readiness passed')
                tool.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n'
                                f'echo "{detail}" >&2\nexit {status}\n')
                tool.chmod(0o700)
                code = HARNESS + r'''
PATH="$TEST_DIR:$PATH"
main --yes --no-swap --log-dir "$TEST_DIR" --include Etckeeper,Fail2ban --exclude Webmin
'''
                result = self.shell(code, d, '', 'apt-get')
                self.assertIn('--bundle KVM --exclude Webmin --include Etckeeper --include Fail2ban', result.stdout)
                self.assertIn(detail, result.stdout + result.stderr)
                self.assertNotIn('Checking KVM appliance boot', result.stdout)
                self.assertIn('[INFO] Checking KVM appliance boot (3-minute timeout)',
                              (pathlib.Path(d) / 'cloudmin-install.log').read_text())
                self.assertEqual(result.returncode == 0, status == 0, result.stderr)
                self.assertEqual('Installation Complete!' in result.stdout, status == 0)
                if status:
                    self.assertIn('configuration or readiness failed', result.stderr)

    def test_installer_paths(self):
        # Replace side-effect boundaries, keeping actual main/option logic intact.
        harness = HARNESS + 'main --yes --log-dir "$TEST_DIR" "$@"\n'
        for flags, expected in [(('--swap-only',), ['PLAN','SWAP']),
                                (('--setup',), ['REPOSITORIES']),
                                (('--no-swap',), ['REPOSITORIES','CONFIGURE'])]:
            with tempfile.TemporaryDirectory(dir='/tmp') as d:
                p = self.shell(harness, d, '', 'dnf', *flags)
                self.assertEqual(p.returncode, 0, p.stderr)
                for token in expected: self.assertIn(token, p.stdout)
                if '--swap-only' in flags:
                    self.assertFalse((pathlib.Path(d) / 'license').exists())
                    self.assertNotIn('REPOSITORIES', p.stdout)
                    self.assertNotIn('CONFIGURE', p.stdout)
                if '--setup' in flags or '--no-swap' in flags:
                    self.assertEqual((pathlib.Path(d) / 'license').read_text(),
                                     'SerialNumber=GPL\nLicenseKey=GPL\n')
                    self.assertNotIn('SWAP', p.stdout)
        for manager in ['dnf', 'apt-get']:
            with tempfile.TemporaryDirectory(dir='/tmp') as d:
                p = self.shell(harness, d, '', manager, '--no-swap', '--extra', 'curl')
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn('Installing Cloudmin and the KVM stack: ' + manager, p.stdout)
                self.assertIn('curl', p.stdout)
                if manager == 'apt-get':
                    self.assertIn('cloudmin-core cloudmin-kvm-stack', p.stdout)
                    self.assertIn('dpkg --compare-versions', p.stdout)
                    self.assertNotIn('dnf ', p.stdout)
                else:
                    self.assertIn('@cloudmincore @cloudmin-kvm', p.stdout)
                    self.assertIn("'cloudmin-config >= 10.0.0' 'webmin >= 2.670'", p.stdout)
                    self.assertNotIn('rpm -q --whatprovides', p.stdout)
        for stage in ['swap', 'package', 'config', 'repository']:
            with tempfile.TemporaryDirectory(dir='/tmp') as d:
                p = self.shell(harness, d, stage, 'dnf')
                self.assertNotEqual(p.returncode, 0, f'{stage}: {p.stdout}')
                self.assertNotIn('Installation Complete!', p.stdout)

    def test_license_selection(self):
        # Cover fresh GPL, saved Pro, explicit replacement, and incomplete files.
        cases = [
            (None, 'GPL', 'GPL', 'GPL', 'GPL', 'GPL'),
            ('SerialNumber=20000\nLicenseKey=FIXTURE200\n', 'GPL', 'GPL',
             '20000', 'FIXTURE200', 'Professional'),
            ('SerialNumber=20000\nLicenseKey=FIXTURE200\n', '30000', 'FIXTURE300',
             '30000', 'FIXTURE300', 'Professional'),
            ('SerialNumber=20000\nLicenseKey=\n', 'GPL', 'GPL', 'GPL', 'GPL', 'GPL'),
        ]
        for saved, serial, key, expected_serial, expected_key, product in cases:
            with self.subTest(product=product, serial=serial), tempfile.TemporaryDirectory(dir='/tmp') as d:
                path = pathlib.Path(d) / 'license'
                if saved is not None:
                    path.write_text(saved)
                result = self.shell(HARNESS + r'''
main --setup --yes --log-dir "$TEST_DIR"
echo "PRODUCT $PRODUCT"
''', d, '', 'dnf', env=dict(SERIAL=serial, KEY=key))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(path.read_text(),
                                 f'SerialNumber={expected_serial}\nLicenseKey={expected_key}\n')
                self.assertEqual(path.with_suffix('.checked').read_text(),
                                 f'{expected_serial}\n{expected_key}\n')
                self.assertEqual(path.stat().st_mode & 0o777, 0o700)
                self.assertIn(f'PRODUCT {product}', result.stdout)

    def test_repository_branches(self):
        code = r'''
log=/dev/null
run_ok() { printf '%s: %s\n' "$2" "$1"; }
download_content() { echo "FETCH $1" >&2; printf 'exit 0\n'; }
manager=$1; ID=$2; branch=unstable; CLOUDMIN_INSTALL_TEMPDIR=$3
preconfigure_cloudmin_release
manage_cloudmin_branch_repos
'''
        for manager, os in [('dnf', 'rocky'), ('apt-get', 'debian'), ('apt-get', 'ubuntu')]:
            with tempfile.TemporaryDirectory(dir='/tmp') as d:
                p = self.shell(code, manager, os, d)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('FETCH https://download.cloudmin.dev/install', p.stderr)
            self.assertIn('sh "$bootstrap" webmin "$branch"', p.stdout)
            self.assertIn('sh "$bootstrap" cloudmin "$branch"', p.stdout)
            if manager == 'apt-get':
                self.assertIn('apt-get update', p.stdout)
                self.assertNotIn('dnf ', p.stdout)
                self.assertEqual('add-apt-repository -y universe' in p.stdout, os == 'ubuntu')
            else:
                self.assertIn('epel-release', p.stdout)
                self.assertIn('--set-enabled crb', p.stdout)

    def test_download_hosts(self):
        # Trace downloads and bootstrap arguments without changing repositories.
        code = r"""
parse_args --branch devel
printf 'LIBRARY %s\n' "$download_cloudmin_host_lib"
log=/dev/null
run_ok() {
  printf '%s: %s\n' "$2" "$1"
  sh -c 'printf "HOSTS %s %s %s\n" "$download_cloudmin_host_dev" "$download_webmin_host" "$download_webmin_host_dev"'
}
download_content() { echo "FETCH $1" >&2; printf 'exit 0\n'; }
manager=$1; ID=$2; CLOUDMIN_INSTALL_TEMPDIR=$3
preconfigure_cloudmin_release
manage_cloudmin_branch_repos
connect='ipv4 ipv6'
test_connection() { echo "CONNECT $*"; }
check_connections
"""
        hosts = dict(download_cloudmin_host='cloudmin.example.test',
                     download_cloudmin_host_dev='cloudmin-dev.example.test',
                     download_webmin_host='webmin.example.test',
                     download_webmin_host_dev='webmin-dev.example.test')
        for manager, distro in [('dnf', 'rocky'), ('apt-get', 'debian')]:
            with tempfile.TemporaryDirectory(dir='/tmp') as d:
                p = self.shell(code, manager, distro, d, env=hosts)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('LIBRARY cloudmin-dev.example.test', p.stdout)
            self.assertIn('FETCH https://cloudmin-dev.example.test/install', p.stderr)
            self.assertIn('HOSTS cloudmin-dev.example.test webmin.example.test webmin-dev.example.test', p.stdout)
            for host in ['cloudmin-dev.example.test', 'webmin-dev.example.test']:
                for protocol in ['ipv4', 'ipv6']:
                    self.assertIn(f'CONNECT {host} {protocol}', p.stdout)
            self.assertNotIn('download.cloudmin.dev', p.stdout)
            self.assertNotIn('download.webmin.dev', p.stdout)

        # A single Cloudmin host override also supplies the default dev host.
        p = self.shell('parse_args; echo "$download_cloudmin_host_lib"',
                       env=dict(download_cloudmin_host='mirror.example.test',
                                download_cloudmin_host_dev=''))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), 'mirror.example.test')

        # Exercise the actual library download path with an inert library.
        with tempfile.TemporaryDirectory(dir='/tmp') as d:
            p = self.shell(r"""
parse_args
script_dir="$1/no-local-library"; CLOUDMIN_INSTALL_TEMPDIR=$1
log=/dev/null; noswap=1; VERBOSE=0
download_content() { echo "FETCH $1" >&2; printf ':\n'; }
finish() { :; }
download_slib
""", d, env=hosts)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stderr.strip(), 'FETCH https://cloudmin-dev.example.test/slib.sh')

    def test_installer_options(self):
        p = self.shell('parse_args "$@"; printf "%s\\n" "$forcereinstall|$skipbanner|$VERBOSE|$bundle|$config_includes|$config_excludes|$extra_packages|$module_name|$insecure_downloads"',
                       '-fr', '-nb', '-V', '-b', 'KVM', '-i', 'Webmin', '-e', 'Etckeeper', '-E', 'bind', '-o', 'custom', '-I')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), "1|1|1|KVM| --include Webmin| --exclude Etckeeper|'bind'|custom|1")
        for args in [('-fr','--swap-only'), ('-C','ipv4'), ('-C',), ('-u',), ('-v',)]:
            self.assertEqual(self.shell('parse_args "$@"', *args).returncode, 0)
        for args in [('-b','LAMP'), ('-o',), ('-o','../module'), ('-u','--swap-only'),
                     ('-C','ipv7'), ('-C','ipv4','--swap','1G')]:
            self.assertNotEqual(self.shell('parse_args "$@"', *args).returncode, 0)

    def test_hooks(self):
        p = self.shell(r'''
pre_hook__outer() { echo "pre:$1"; bind_hook inner "$1"; }
inner() { echo "inner:$1"; }
outer() { echo "outer:$1"; }
post_hook__outer() { echo "post:$1"; }
bind_hook outer "two words"
hook__outer() { echo "override:$1"; return 7; }
bind_hook outer value
''')
        self.assertEqual(p.returncode, 7)
        self.assertEqual(p.stdout.splitlines(), ['pre:two words','inner:two words',
                                               'outer:two words','post:two words','override:value'])
        for failure in ['pre_hook__task', 'task', 'post_hook__task']:
            p = self.shell('task() { echo TASK; }; post_hook__task() { echo POST; }; '
                           + failure + '() { return 9; }; bind_hook task')
            self.assertEqual(p.returncode, 9)
            if failure != 'post_hook__task': self.assertNotIn('POST', p.stdout)
        self.assertEqual(self.shell('bind_hook missing').returncode, 0)

    def test_command_arguments(self):
        result = self.shell(r'''
parse_args --extra 'bind,bind-utils' --extra curl --include Webmin --include Etckeeper,Fail2ban --exclude Network
run_ok() { eval "$1"; }
run_ok "printf '<%s>\n' $extra_packages" 'Arguments'
printf '<%s>\n' $config_includes $config_excludes
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['<bind>', '<bind-utils>', '<curl>',
                         '<--include>', '<Webmin>', '<--include>', '<Etckeeper>',
                         '<--include>', '<Fail2ban>', '<--exclude>', '<Network>'])
        for value in ["one'two", '; echo INJECTED', '$(echo INJECTED)', '`echo INJECTED`', '*', 'a b']:
            result = self.shell('parse_args --extra "$1"; echo ACCEPTED', value)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('ACCEPTED', result.stdout)

    def test_preconfigured_services(self):
        # CLI tools and unrelated servers alone must not trigger the warning.
        probe = r"""
systemctl() {
  [ "$*" = 'list-unit-files --type=service --no-legend --no-pager' ] || return 90
  printf '%s\n' "$TEST_UNITS"
}
nft() {
  [ "$*" = 'list tables' ] || return 91
  printf '%s\n' "$TEST_TABLES"
  return "$TEST_NFT_STATUS"
}
named() { return 0; }
apachectl() { return 0; }
nginx() { return 0; }
mariadb() { return 0; }
postconf() { return 0; }
php() { return 0; }
virsh() { echo UNEXPECTED_LIBVIRT_CONNECTION >&2; return 92; }
YELLOW=; BOLD=; NORMAL=
is_preconfigured
"""
        cases = [
            ('', '', 127, ''),
            ('apache2.service enabled\nnginx.service enabled\nnamed.service enabled\n'
             'mariadb.service enabled\npostfix.service enabled\nphp-fpm.service enabled', '', 0, ''),
            ('libvirtd.service disabled enabled', '', 0, 'libvirt'),
            ('virtqemud.service enabled enabled\nvirtnetworkd.service enabled enabled\n'
             'virtstoraged.service disabled enabled', '', 0, 'libvirt'),
            ('virtstoraged.service masked enabled', '', 0, 'libvirt'),
            ('webmin.service enabled enabled', '', 0, 'Webmin'),
            ('nftables.service disabled disabled', '', 0, 'nftables'),
            ('', 'table inet custom', 0, 'nftables'),
            ('nftables.service enabled enabled', 'table inet custom', 0, 'nftables'),
            ('fail2ban.service disabled enabled', '', 0, 'Fail2ban'),
            ('webmin-extra.service enabled\nmy-firewalld.service enabled', '', 0, ''),
            ('libvirtd.service enabled\nwebmin.service enabled\nfirewalld.service enabled\n'
             'fail2ban.service enabled', 'table inet custom', 0,
             'libvirt, Webmin, nftables, firewalld, Fail2ban'),
        ]
        for service in ['firewalld', 'ufw', 'iptables', 'ip6tables', 'netfilter-persistent']:
            cases.append((f'{service}.service disabled enabled', '', 0, service))
        for units, tables, status, expected in cases:
            with self.subTest(units=units, tables=tables):
                result = self.shell(probe, env=dict(TEST_UNITS=units, TEST_TABLES=tables,
                                                   TEST_NFT_STATUS=str(status)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, '')
                self.assertEqual(result.stdout.strip(), expected)

    def test_preconfigured_warning(self):
        # Keep normal prompting, cancellation and --yes behavior intact.
        for detected, skip, answer, continues in [('', 0, 1, True),
                                                  ('libvirt', 0, 0, True),
                                                  ('firewalld', 0, 1, False),
                                                  ('Webmin', 1, 1, True)]:
            with self.subTest(detected=detected, skip=skip, answer=answer):
                result = self.shell(r"""
is_preconfigured() { printf '%s\n' "$TEST_DETECTED"; }
confirm() { printf 'PROMPT %s\n' "$1"; return "$TEST_ANSWER"; }
skipyesno=$TEST_SKIP
preconfigured_system_msg
printf 'CONTINUED\n'
""", env=dict(TEST_DETECTED=detected, TEST_SKIP=str(skip), TEST_ANSWER=str(answer)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual('ATTENTION' in result.stdout, bool(detected))
                self.assertEqual('PROMPT' in result.stdout, bool(detected) and not skip)
                self.assertEqual('CONTINUED' in result.stdout, continues)
                if detected:
                    self.assertIn('Existing host software detected: ' + detected, result.stdout)
                    self.assertIn('other incoming connections', result.stdout.lower())
                    self.assertNotIn('third-party repositories', result.stdout)

    def test_banner(self):
        p = self.shell(r'''
PRODUCT=$1; skipyesno=1; noswap=; setup_only=; SLIB_SWAP_API=2; disk_space_required=4; bundle=KVM
swap_plan() { :; }
swap_plan_message() { echo 'The swap space will be created with a size of 1 GiB.'; }
install_msg
''', 'GPL')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('Welcome to the Cloudmin GPL installer', p.stdout)
        self.assertIn('1 GiB', p.stdout)
        self.assertNotIn('Continue?', p.stdout)
        self.assertNotIn('VIRTUALMIN_LOGO', p.stdout)
        self.assertNotIn('LAMP', p.stdout)

    def test_module_and_phases(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as d:
            (pathlib.Path(d) / 'example.sh').write_text('hook__phase4_pre() { echo MODULE_CONFIG; }\n')
            p = self.shell(r'''
script_dir=$1; module_name=example; CLOUDMIN_INSTALL_TEMPDIR=$1
bind_hook load_module
bind_hook phase4_pre
hooks__phases=$(printf '5\tExtra\tprintf MODULE_STEP\tCustom step')
run_ok() { eval "$1"; }
extra_phases
''', d)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('MODULE_CONFIG', p.stdout)
            self.assertIn('MODULE_STEP', p.stdout)

    def test_uninstall_commands(self):
        code = r'''
manager=$1; ID=ubuntu; skipyesno=1
run_ok() { printf '%s: %s\n' "$2" "$1"; }
rm() { echo "REMOVE: $*"; }
log_success() { echo "$1"; }
uninstall
'''
        for manager in ['apt-get', 'dnf']:
            p = self.shell(code, manager)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('Cloudmin uninstallation complete', p.stdout)
            self.assertIn('remove', p.stdout)
            self.assertIn('cloudmin-config webmin-server-manager', p.stdout)
            self.assertNotIn('autoremove', p.stdout)
            self.assertNotIn('groupremove', p.stdout)
            self.assertEqual('REMOVE: -f /etc/apt/preferences.d/ubuntu-cloudmin-package-priority'
                             in p.stdout, manager == 'apt-get')
            self.assertNotIn('REMOVE: /etc/webmin', p.stdout)
            self.assertNotIn('REMOVE: /var/lib/libvirt', p.stdout)

if __name__ == '__main__':
    unittest.main()
