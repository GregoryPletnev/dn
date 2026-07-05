import os
import pytest

from tuitest import TuiSession

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DN = os.path.join(ROOT, 'bin', 'dn')


@pytest.fixture
def sandbox(tmp_path):
    left = tmp_path / 'left'
    right = tmp_path / 'right'
    left.mkdir()
    right.mkdir()
    (left / 'alpha').mkdir()
    (left / 'beta').mkdir()
    (left / 'alpha' / 'inner.txt').write_text('hello\n')
    (left / 'a.txt').write_text('aaa\n')
    (left / 'b.txt').write_text('bbbbbb\n')
    (right / 'r.txt').write_text('rrr\n')
    return tmp_path


@pytest.fixture
def dn(sandbox):
    s = make_session(sandbox)
    s.wait_text('a.txt')
    yield s
    s.close()


def make_session(sandbox, env=None, left=None, right=None):
    e = {'DN_CONFIG_DIR': str(sandbox / 'cfg')}   # keep tests off ~/.config
    e.update(env or {})
    s = TuiSession([DN, str(left or sandbox / 'left'),
                    str(right or sandbox / 'right')], env=e)
    return s
