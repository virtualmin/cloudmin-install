#!/usr/bin/env python3
"""Test installer terminal output on a disposable Linux VM; optionally test swap."""
import argparse
import base64
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import struct
import subprocess
import tempfile
import termios
import time


def terminal(command, env, answer=None, prompt=None, timeout=45):
    """Run a command on a terminal and optionally answer its first prompt."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    proc = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    output = b''
    end = time.monotonic() + timeout
    try:
        while time.monotonic() < end:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
                if answer is not None and (prompt is None or prompt.encode() in output):
                    os.write(master, answer.encode())
                    answer = None
            if proc.poll() is not None:
                # Read remaining output before the terminal closes.
                continue
        if proc.poll() is None:
            proc.wait(timeout=3)
        return proc.returncode, output
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        os.close(master)


def plain_output(text):
    """Compare messages independently of the terminal's color sequences."""
    return re.sub(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\([A-Za-z]', '', text)


def require(condition, message):
    """Fail with the check name, without dumping fixture logs."""
    if not condition:
        raise AssertionError(message)
    print('PASS:', message, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installer', required=True, type=Path)
    parser.add_argument('--slib', required=True, type=Path)
    parser.add_argument('--live-swap', action='store_true')
    parser.add_argument('--config-lib', type=Path, help='Cloudmin Config lib directory for terminal checks')
    opt = parser.parse_args()
    installer = opt.installer.resolve()
    library = opt.slib.resolve()
    source = installer.read_text()
    functions = source.rsplit('\nmain "$@"', 1)[0]
    # Exercise quoted script and log paths through the shared progress helpers.
    with tempfile.TemporaryDirectory(prefix='cloudmin installer-ui-') as directory:
        root = Path(directory)
        script = root / 'cloudmin-install.sh'
        script.write_text(source)
        (root / 'functions.sh').write_text(functions)
        shutil.copyfile(library, root / 'slib.sh')
        env = dict(os.environ, TERM='xterm-256color', NO_COLOR='', NONINTERACTIVE='0', SERIAL='GPL', KEY='GPL')
        for key in ['PS1', 'TMUX', 'STY', 'ZELLIJ', 'OLDTERM', 'TERM_PROGRAM']:
            env.pop(key, None)
        # Exercise the actual graphics output and its text-only fallbacks.
        logo = root / 'logo.sh'
        logo.write_text('. ' + shlex.quote(str(root / 'functions.sh')) + '\ninstall_logo\n')
        for term, program, marker in [('xterm-kitty', '', b'\x1b_G'),
                                      ('xterm-256color', 'iTerm.app', b'\x1b]1337;')]:
            status, output = terminal(['sh', str(logo)], dict(env, TERM=term, TERM_PROGRAM=program))
            require(status == 0 and marker in output, program or term + ' logo protocol')
            if marker == b'\x1b_G':
                payload = output.split(b'q=2;', 1)[1].split(b'\x1b\\', 1)[0]
                png = base64.b64decode(payload)
                require(png.startswith(b'\x89PNG\r\n\x1a\n') and len(payload) < 4096,
                        'embedded Cloudmin PNG fits one graphics chunk')
        for changes in [dict(TERM='dumb'), dict(NO_COLOR='1'), dict(TMUX='fixture')]:
            logo_env = dict(env, TERM='xterm-kitty')
            logo_env.update(changes)
            status, output = terminal(['sh', str(logo)], logo_env)
            require(status == 1 and not output, 'logo fallback ' + str(changes))
        # Keep installation side effects in fixtures while using real slib progress.
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        for name in ['dnf', 'rpm', 'apt-get', 'dpkg', 'dpkg-query', 'hostnamectl']:
            command = '#!/bin/sh\nprintf "%s\\n" "$0 $*" >>"$TEST_EVENTS"\n'
            if name == 'dnf':
                command += '[ "$TEST_FAIL" != package ] || exit 9\n'
            if name == 'dpkg-query':
                command += 'echo 99.0.0\n'
            command += 'exit 0\n'
            (bin_dir / name).write_text(command)
            (bin_dir / name).chmod(0o700)
        (bin_dir / 'cloudmin-config-system').write_text('#!/bin/sh\necho CONFIGURATION_PROGRESS\n[ "$TEST_FAIL" != config ]\n')
        (bin_dir / 'cloudmin-config-system').chmod(0o700)
        wrapper = root / 'wrapper.sh'
        wrapper.write_text('. ' + shlex.quote(str(root / 'functions.sh')) + r'''
pre_check_all() { ID=rocky; PRETTY_NAME=fixture; manager=${TEST_MANAGER:-dnf}; }
is_installed() { return 1; }
cloudmin_license_file="$(dirname -- "$0")/license"
preconfigure_cloudmin_release() {
  install="$manager -y install"; upgrade="$manager -y upgrade"
  case "$manager" in apt-get) package_type=deb ;; *) package_type=rpm ;; esac
}
manage_cloudmin_branch_repos() { run_ok 'printf REPOSITORIES' 'Fixture repository setup'; }
hook__phase4_post() { echo phase4_post >>"$TEST_EVENTS"; }
hook__phases_all_post() { echo phases_all_post >>"$TEST_EVENTS"; }
hook__clean_post() { echo clean_post >>"$TEST_EVENTS"; }
hook__phase3_pre() { [ "$TEST_FAIL" != hook ]; }
main "$@"
''')
        for manager, failure in [('dnf', ''), ('apt-get', ''), ('dnf', 'package'), ('dnf', 'config'), ('dnf', 'hook')]:
            case = root / (manager + '-' + (failure or 'success'))
            case.mkdir()
            events = case / 'events'
            fixture_env = dict(env, PATH=str(bin_dir) + ':' + env['PATH'], TEST_EVENTS=str(events), TEST_FAIL=failure, TEST_MANAGER=manager)
            status, output = terminal(['sh', str(wrapper), '-y', '-nb', '-ns', '-fr', '--log-dir', str(case)], fixture_env)
            expected_success = not failure
            require((status == 0) == expected_success and (b'Installation Complete!' in output) == expected_success,
                    manager + ' lifecycle ' + (failure or 'success'))
            if expected_success:
                require(b'Phase ' in output and b'CONFIGURATION_PROGRESS' in output and b'[SUCCESS]' in output,
                        manager + ' phases, configuration and completion output')
                require('clean_post' in events.read_text(), manager + ' lifecycle hooks reached cleanup')
            else:
                require(b'[ERROR]' in output and b'Cleaning up' not in output, failure + ' stops the install')
        # Configuration uses the same progress display and must restore the cursor on failure.
        if opt.config_lib:
            progress = root / 'progress.pl'
            progress.write_text("use Cloudmin::Config::Plugin; use Log::Log4perl qw(:easy); "
                                "Log::Log4perl->easy_init($OFF); $|=1; "
                                "my $p=Cloudmin::Config::Plugin->new(name=>'Fixture',total=>1); "
                                "$p->spin('Checking fixture'); select undef,undef,undef,0.5; "
                                "die qq(Fixture failed mid-check\\n) if $ARGV[0]; $p->done(1);\n")
            config_env = dict(env, PERL5LIB=str(opt.config_lib.resolve()))
            for mode in ['', 'die']:
                status, output = terminal(['perl', str(progress), mode], config_env)
                require((status == 0) == (not mode) and b'Checking fixture' in output and
                        b'\x1b[?25l' in output and b'\x1b[?25h' in output,
                        'configuration progress and cursor cleanup ' + (mode or 'success'))
        # A real installed host must require -fr, then permit the normal banner.
        if Path('/etc/webmin/server-manager/config').exists():
            result = subprocess.run(['sh', str(script)], env=env, text=True, capture_output=True, timeout=30)
            require(result.returncode != 0 and 'Cloudmin is already installed on this system' in result.stderr,
                    'installed host refuses an accidental reinstall')
            status, output = terminal(['sh', str(script), '-fr', '--no-swap', '--log-dir', str(root)], env,
                                      answer='n\n', prompt='Continue? (y/n)')
            require(status == 0 and b'Welcome to the ' in output and b'Phase ' not in output,
                    '-fr reaches the real installation banner and cancels before changes')
        # --swap-only -fr must remain standalone and cancellation must do nothing.
        require(not Path('/swap.vm').exists() and not Path('/swap.virtualmin/swapfile').exists(),
                'no pre-existing installer-managed swap')
        fstab = Path('/etc/fstab').read_bytes()
        status, output = terminal(['sh', str(script), '--swap-only', '--swap', '64M', '-fr', '--log-dir', str(root)], env,
                                  answer='n\n', prompt='Apply these swap changes? (y/n)')
        output = re.sub(rb'\x1b\[[0-9;?]*[A-Za-z]|\x1b\([A-Za-z]', b'', output)
        require(status == 0 and b'[INFO] Started swap setup' in output and b'Swap setup cancelled' in output,
                'swap-only -fr shows the swap prompt and cancellation messages')
        require(Path('/etc/fstab').read_bytes() == fstab, 'cancelled swap preserves fstab')
        if opt.live_swap:
            require(not Path('/swap.vm').exists() and not Path('/swap.virtualmin/swapfile').exists(),
                    'no pre-existing installer-managed swap')
            try:
                result = subprocess.run(['sh', str(script), '--swap-only', '--swap', '64M', '-fr', '-y', '--log-dir', str(root)],
                                        env=env, text=True, capture_output=True, timeout=90)
                require(result.returncode == 0 and '[SUCCESS] Swap setup completed successfully.' in plain_output(result.stdout),
                        'real 64 MiB swap creation')
                active = subprocess.check_output(['swapon', '--show=NAME', '--noheadings'], text=True)
                require('/swap.vm' in active or '/swap.virtualmin/swapfile' in active, 'fixture swap is active')
            finally:
                result = subprocess.run(['sh', str(script), '--swap-only', '--swap', '0', '-y', '--log-dir', str(root)],
                                        env=env, text=True, capture_output=True, timeout=90)
                require(result.returncode == 0, 'fixture swap removal')
            require(Path('/etc/fstab').read_bytes() == fstab, 'swap cycle preserves original fstab')
            require(not Path('/swap.vm').exists() and not Path('/swap.virtualmin/swapfile').exists(), 'fixture swap cleaned up')
        result = subprocess.run(['sh', str(script), '--swap-only', '--swap', '0', '-fr', '-y', '--log-dir', str(root)],
                                env=env, text=True, capture_output=True, timeout=30)
        require(result.returncode == 0 and '[SUCCESS] System swap left unchanged.' in plain_output(result.stdout),
                'no-op swap reports that swap is unchanged')


if __name__ == '__main__':
    main()
