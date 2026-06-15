import os

import pytest


@pytest.fixture(autouse=True)
def _reap_children():
    """Reap any PTY children a test left behind so they can't linger as zombies
    and interfere with a later test's event loop / process teardown."""
    yield
    try:
        while True:
            pid, _ = os.waitpid(-1, os.WNOHANG)
            if pid == 0:
                break
    except ChildProcessError:
        pass
