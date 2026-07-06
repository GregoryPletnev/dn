#!/usr/bin/env python3
"""Fake OpenSSH sftp for tests: executes batch commands against a local
directory tree (FAKE_SFTP_ROOT) pretending it is the remote filesystem.
Invocation mirrors the real client: fakesftp.py ... -b batchfile target"""

import os
import shutil
import stat
import sys
import time


def die(msg):
    sys.stderr.write(msg + '\n')
    sys.exit(1)


ROOT = os.environ.get('FAKE_SFTP_ROOT')
if not ROOT:
    die('FAKE_SFTP_ROOT not set')

batchfile = None
args = sys.argv[1:]
i = 0
target = None
while i < len(args):
    if args[i] == '-b':
        batchfile = args[i + 1]
        i += 2
    elif args[i].startswith('-'):
        i += 1
    else:
        target = args[i]
        i += 1

if target is None:
    die('no target host')
if target.split('@')[-1].split(':')[0] == 'badhost':
    die('ssh: Could not resolve hostname badhost')


def real(p):
    return os.path.join(ROOT, p.lstrip('/'))


def ls_line(path, name):
    st = os.stat(path)
    mode = 'd' if stat.S_ISDIR(st.st_mode) else '-'
    mode += 'rwxr-xr-x' if stat.S_ISDIR(st.st_mode) else 'rw-r--r--'
    t = time.localtime(st.st_mtime)
    mon = time.strftime('%b', t)
    return '%s    1 u        g    %12d %s %2d %02d:%02d %s' % (
        mode, st.st_size, mon, t.tm_mday, t.tm_hour, t.tm_min, name)


def unq(s):
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    return s


def split_args(line):
    """split on spaces, honoring '...' quoting"""
    out, cur, q = [], '', False
    for ch in line:
        if q:
            cur += ch
            if ch == "'":
                q = False
        elif ch == ' ':
            if cur:
                out.append(cur)
                cur = ''
        else:
            cur += ch
            if ch == "'":
                q = True
    if cur:
        out.append(cur)
    return [unq(a) for a in out]


lines = []
if batchfile:
    with open(batchfile) as f:
        lines = [l.rstrip('\n') for l in f if l.strip()]

for line in lines:
    parts = split_args(line)
    cmd = parts[0]
    opts = [p for p in parts[1:] if p.startswith('-')]
    rest = [p for p in parts[1:] if not p.startswith('-')]
    try:
        if cmd == 'ls':
            d = real(rest[0]) if rest else ROOT
            if not os.path.isdir(d):
                die('ls: %s: No such file or directory' % rest[0])
            print('sftp> ls -la %s' % (rest[0] if rest else '/'))
            for name in sorted(os.listdir(d)):
                print(ls_line(os.path.join(d, name), name))
        elif cmd == 'get':
            src, dst = real(rest[0]), rest[1]
            if '-r' in opts:
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)
        elif cmd == 'put':
            src, dst = rest[0], real(rest[1])
            if '-r' in opts:
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)
        elif cmd == 'rm':
            os.unlink(real(rest[0]))
        elif cmd == 'rmdir':
            os.rmdir(real(rest[0]))
        elif cmd == 'mkdir':
            os.makedirs(real(rest[0]), exist_ok=True)
        elif cmd == 'rename':
            os.rename(real(rest[0]), real(rest[1]))
        else:
            die('unknown command: %s' % cmd)
    except OSError as e:
        die('%s: %s' % (cmd, e))
