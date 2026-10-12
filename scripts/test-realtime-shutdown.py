#!/usr/bin/env python3
"""Actual hung LuaLaTeX workers must exit on TERM, EOF, and engine shutdown."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
host = repo / 'TexFast Realtime.app/Contents/MacOS/rtex-host'
env = os.environ.copy()
env['PATH'] = '/Library/TeX/texbin:' + env.get('PATH', '')
env['RTEX_TEXDIR'] = str(repo / '.build/realtime-engine/share/rtex/tex')


def group_members(group):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,pgid=,state=,command='], text=True)
    return [(int(words[0]), words[2], words[3]) for line in rows.splitlines()
            if len(words := line.split(None, 3)) == 4 and int(words[1]) == group]


def check(mode, hung):
    with tempfile.TemporaryDirectory(prefix='texfast-process-audit-') as directory:
        root = Path(directory)
        body = '\\directlua{while true do end}\n' if hung else ''
        (root / 'main.tex').write_text('\\documentclass{article}\n' + body + '\\begin{document}Hello.\\end{document}\n')
        p = subprocess.Popen([str(host), 'serve', '--project', directory, '--main', 'main.tex', '--build', str(root / 'build')],
                             stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
        group = p.pid
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                workers = [row for row in group_members(group) if 'lualatex' in row[2]]
                if workers:
                    break
                if p.poll() is not None:
                    raise AssertionError(p.stderr.read().decode())
                time.sleep(.05)
            assert workers, 'fixture must launch actual LuaLaTeX workers'
            if mode == 'terminate':
                p.terminate()
            elif mode == 'eof':
                p.stdin.close()
            else:
                p.stdin.write(b'{"cmd":"quit"}\n'); p.stdin.flush()
            assert p.wait(timeout=5) == 0, p.stderr.read().decode()
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and group_members(group):
                time.sleep(.05)
            assert not group_members(group), f'{mode} left workers: {group_members(group)}'
            print(f'PASS: {mode} cleans up all engine workers (hung={hung})')
        finally:
            # Only this disposable fixture's process group is eligible for cleanup.
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(group, signal.SIGKILL)
                    p.wait()
            for pid, state, command in group_members(group):
                if directory in command and state != 'Z':
                    os.kill(pid, signal.SIGKILL)


for mode, hung in [('terminate', True), ('quit', True), ('eof', False)]:
    check(mode, hung)

# Model force-quitting the app while its engine is in a nonterminating preamble.
with tempfile.TemporaryDirectory(prefix='texfast-owner-audit-') as directory:
    root = Path(directory)
    (root / 'main.tex').write_text('\\documentclass{article}\n\\directlua{while true do end}\n\\begin{document}Hello.\\end{document}\n')
    launcher = """
import pathlib, subprocess, sys, time
host, root = sys.argv[1:]
p = subprocess.Popen([host, 'serve', '--project', root, '--main', 'main.tex', '--build', root + '/build'], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pathlib.Path(root, 'pid').write_text(str(p.pid))
time.sleep(30)
"""
    owner = subprocess.Popen([sys.executable, '-c', launcher, str(host), directory], env=env)
    group = None
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if (root / 'pid').exists():
                group = int((root / 'pid').read_text())
                if any('lualatex' in row[2] for row in group_members(group)):
                    break
            time.sleep(.05)
        assert group and any('lualatex' in row[2] for row in group_members(group)), 'owner-death fixture launched compiler workers'
        owner.kill(); owner.wait()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and group_members(group):
            time.sleep(.05)
        assert not group_members(group), f'owner death left workers: {group_members(group)}'
        print('PASS: app process death cleans up the supervisor, engine, and hung LuaLaTeX workers')
    finally:
        if owner.poll() is None:
            owner.kill(); owner.wait()
        if group and group_members(group):
            os.killpg(group, signal.SIGKILL)
