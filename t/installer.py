#!/usr/bin/env python3
"""Exercise argument handling and orchestration without administering the host."""
import os
import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'cloudmin-install.sh'
FUNCTIONS = SOURCE.read_text().rsplit('\nmain "$@"', 1)[0]

class InstallerTests(unittest.TestCase):
    def shell(self, code, *args, env=None):
        return subprocess.run(['sh', '-c', FUNCTIONS + '\n' + code, 'test', *args],
                              env=None if env is None else dict(os.environ, **env),
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_sizes(self):
        for value, expected in [('0',0), ('0008',8192), ('1K',1024), ('2MB',2048), ('2G',2097152), ('1gb',1048576)]:
            with self.subTest(value=value):
                p = self.shell('parse_options --swap "$1"; echo "$swapsize"', value)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stdout.strip(), str(expected))
        for value in ['-1', 'G', '+2', '1.5G', '1T', '1024G', '99999999999', '1;touch x']:
            self.assertNotEqual(self.shell('parse_options --swap "$1"', value).returncode, 0)

    def test_flags(self):
        for args in [('--swap',), ('--swap','1G','--no-swap'), ('--swap-only','--setup'),
                     ('--swap','0','--setup'), ('--swap-only','--extra','bind'),
                     ('--extra','--allowerasing'), ('--extra','bind;id'), ('--include','../Etckeeper'),
                     ('--log-dir','relative'), ('--branch','stable'), ('--branch','prerelease'),
                     ('--branch','pre-release'), ('--branch','rc'), ('--branch','release-candidate'), ('--unknown',)]:
            with self.subTest(args=args):
                self.assertNotEqual(self.shell('parse_options "$@"', *args).returncode, 0)
        for args in [('--setup','--no-swap'), ('--swap-only','--no-swap'), ('--include','Etckeeper,Fail2ban'),
                     ('--extra','bind,bind-utils'), ('--branch','unstable'), ('--branch','devel')]:
            self.assertEqual(self.shell('parse_options "$@"', *args).returncode, 0)

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
        with tempfile.TemporaryDirectory(dir='/tmp') as d:
            p = self.shell('log="$1/log"; CLOUDMIN_INSTALL_TEMPDIR=$1; run_ok() { eval "$1"; }; run "Package install" sh -c "exit 9"; echo FALSE_SUCCESS', d)
            self.assertNotEqual(p.returncode, 0)
            self.assertNotIn('FALSE_SUCCESS', p.stdout)

    def test_readiness_result(self):
        # Exercise the real configure function; only the configuration tool is a fixture.
        for status in [0, 1]:
            with self.subTest(status=status), tempfile.TemporaryDirectory(dir='/tmp') as d:
                tool = pathlib.Path(d) / 'cloudmin-config-system'
                detail = ('KVM image appliance could not boot; fixture worker error'
                          if status else 'Readiness passed')
                tool.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n'
                                f'echo "{detail}" >&2\nexit {status}\n')
                tool.chmod(0o700)
                p = self.shell('log_info() { echo "$1"; }; log="$1/log"; PATH="$1:$PATH"; includes=; excludes=; '
                               ': >"$log"; configure; echo CONFIGURATION_PASSED', d)

                self.assertIn('--bundle KVM', p.stdout)
                self.assertIn(detail, p.stdout + p.stderr)
                self.assertIn('3-minute timeout', p.stdout)
                if status:
                    self.assertNotEqual(p.returncode, 0)
                    self.assertIn(detail, p.stderr)
                    self.assertIn('configuration or readiness failed', p.stderr + p.stdout)
                    self.assertNotIn('CONFIGURATION_PASSED', p.stdout)
                else:
                    self.assertEqual(p.returncode, 0, p.stderr)
                    self.assertIn('CONFIGURATION_PASSED', p.stdout)

    def test_installer_paths(self):
        # Replace side-effect boundaries, keeping actual main/option logic intact.
        harness = r'''
preflight() { PRETTY_NAME=fixture; manager=${TEST_MANAGER:-dnf}; }
repositories() { echo REPOSITORIES; }
configure() { echo CONFIGURE; [ "$TEST_FAIL" != config ]; }
install_msg() { echo BANNER; }
unstable_repos_system_msg() { :; }
preconfigured_system_msg() { :; }
load_slib() {
  LOG_PATH=$log
  log_info() { echo "[INFO] $1"; }
  log_success() { echo "[SUCCESS] $1"; }
  log_warning() { echo "[WARNING] $1"; }
  swap_plan() { swap_action=create; [ "$1" = 4 ] || [ "$1" = 0 ] || exit 91; }
  swap_plan_message() { echo PLAN; }
  swap_setup() { echo SWAP; [ "$TEST_FAIL" != swap ]; }
}
run() { echo "RUN: $*"; [ "$TEST_FAIL" != package ] || fail "Package error"; }
hostname() { echo fixture.example.test; }
mktemp() { mkdir "$TEST_DIR/work"; echo "$TEST_DIR/work"; }
TEST_DIR=$1; TEST_FAIL=$2; TEST_MANAGER=$3; shift 3
mkdir "$TEST_DIR/bin"
printf '%s\n' '#!/bin/sh' 'echo 99.0.0' > "$TEST_DIR/bin/dpkg-query"
chmod +x "$TEST_DIR/bin/dpkg-query"
PATH="$TEST_DIR/bin:$PATH"
main --yes --log-dir "$TEST_DIR" "$@"
'''
        for flags, expected in [(('--swap-only',), ['PLAN','SWAP']),
                                (('--setup',), ['REPOSITORIES']),
                                (('--no-swap',), ['REPOSITORIES','CONFIGURE'])]:
            with tempfile.TemporaryDirectory(dir='/tmp') as d:
                p = self.shell(harness, d, '', 'dnf', *flags)
                self.assertEqual(p.returncode, 0, p.stderr)
                for token in expected: self.assertIn(token, p.stdout)
                if '--swap-only' in flags:
                    self.assertNotIn('REPOSITORIES', p.stdout)
                    self.assertNotIn('CONFIGURE', p.stdout)
                if '--setup' in flags or '--no-swap' in flags:
                    self.assertNotIn('SWAP', p.stdout)
        for manager in ['dnf', 'apt-get']:
            with tempfile.TemporaryDirectory(dir='/tmp') as d:
                p = self.shell(harness, d, '', manager, '--no-swap', '--extra', 'curl')
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn('Installing Cloudmin and the KVM stack ' + manager, p.stdout)
                self.assertIn('curl', p.stdout)
                if manager == 'apt-get':
                    self.assertIn('cloudmin-core cloudmin-kvm-stack', p.stdout)
                    self.assertIn('dpkg --compare-versions', p.stdout)
                    self.assertNotIn('dnf ', p.stdout)
                else:
                    self.assertIn('@cloudmincore @cloudmin-kvm', p.stdout)
                    self.assertIn('rpm -q --whatprovides', p.stdout)
        for stage in ['swap', 'package', 'config']:
            with tempfile.TemporaryDirectory(dir='/tmp') as d:
                p = self.shell(harness, d, stage, 'dnf')
                self.assertNotEqual(p.returncode, 0, f'{stage}: {p.stdout}')
                self.assertNotIn('Installation Complete!', p.stdout)

    def test_repository_branches(self):
        code = r'''
log=/dev/null
run() { echo "$*"; }
fetch() { echo "FETCH $1"; }
manager=$1; ID=$2; branch=unstable; CLOUDMIN_INSTALL_TEMPDIR=/tmp/fixture
repositories
'''
        for manager, os in [('dnf', 'rocky'), ('apt-get', 'debian'), ('apt-get', 'ubuntu')]:
            p = self.shell(code, manager, os)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('--name=cloudmin', p.stdout)
            self.assertIn('--check-binary=0', p.stdout)
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
run() { echo "$*"; }
fetch() { echo "FETCH $1"; }
manager=$1; ID=$2; CLOUDMIN_INSTALL_TEMPDIR=/tmp/fixture
repositories
connect='ipv4 ipv6'
test_connection() { echo "CONNECT $*"; }
check_connections
"""
        hosts = dict(download_cloudmin_host='cloudmin.example.test',
                     download_cloudmin_host_dev='cloudmin-dev.example.test',
                     download_webmin_host='webmin.example.test',
                     download_webmin_host_dev='webmin-dev.example.test')
        for manager, distro in [('dnf', 'rocky'), ('apt-get', 'debian')]:
            p = self.shell(code, manager, distro, env=hosts)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('LIBRARY cloudmin-dev.example.test', p.stdout)
            self.assertIn('--host=cloudmin.example.test --unstable-host=cloudmin-dev.example.test', p.stdout)
            self.assertIn('--host=webmin.example.test --unstable-host=webmin-dev.example.test', p.stdout)
            self.assertIn('--key-server=https://webmin.example.test', p.stdout)
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
fetch() { echo "FETCH $1"; printf ':\n' > "$2"; }
finish() { :; }
load_slib
""", d, env=hosts)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.strip(), 'FETCH https://cloudmin-dev.example.test/slib.sh')

    def test_installer_options(self):
        p = self.shell('parse_args "$@"; printf "%s\\n" "$forcereinstall|$skipbanner|$VERBOSE|$bundle|$includes|$excludes|$extra|$module_name|$insecure_downloads"',
                       '-fr', '-nb', '-V', '-b', 'KVM', '-i', 'Webmin', '-e', 'Etckeeper', '-E', 'bind', '-o', 'custom', '-I')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), '1|1|1|KVM|Webmin|Etckeeper|bind|custom|1')
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
        with tempfile.TemporaryDirectory(dir='/tmp') as d:
            values = ["two words", "one'two", '; echo INJECTED', '$(echo INJECTED)', '', '%s']
            p = self.shell(r'''
CLOUDMIN_INSTALL_TEMPDIR=$1; log="$1/log with spaces"; shift
run_ok() { eval "$1"; }
run Arguments printf '<%s>\n' "$@"
''', d, *values)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.splitlines(), ['<' + x + '>' for x in values])

    def test_banner(self):
        p = self.shell(r'''
skipyesno=1; noswap=; setup=; SLIB_SWAP_API=2; disk_space_required=4; bundle=KVM
swap_plan() { :; }
swap_plan_message() { echo 'The swap space will be created with a size of 1 GiB.'; }
install_msg
''')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('Welcome to the Cloudmin GPL installer', p.stdout)
        self.assertIn('1 GiB', p.stdout)
        self.assertNotIn('Continue?', p.stdout)
        self.assertNotIn('VIRTUALMIN_LOGO', p.stdout)
        self.assertNotIn('LAMP', p.stdout)

    def test_module_and_phases(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as d:
            (pathlib.Path(d) / 'example.sh').write_text('hook__configure() { echo MODULE_CONFIG; }\n')
            p = self.shell(r'''
script_dir=$1; module_name=example; CLOUDMIN_INSTALL_TEMPDIR=$1
bind_hook load_module
bind_hook configure
hooks__phases=$(printf '5\tExtra\tprintf MODULE_STEP\tCustom step')
run() { shift; "$@"; }
extra_phases
''', d)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('MODULE_CONFIG', p.stdout)
            self.assertIn('MODULE_STEP', p.stdout)

    def test_uninstall_commands(self):
        code = r'''
manager=$1; skipyesno=1
run() { echo "$*"; }
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
            self.assertNotIn('REMOVE: /etc/webmin', p.stdout)
            self.assertNotIn('REMOVE: /var/lib/libvirt', p.stdout)

if __name__ == '__main__':
    unittest.main()
