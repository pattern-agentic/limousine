from limousine import launch

_KEYS = ("LIMOUSINE_WORKSPACE", "LIMOUSINE_CLONE_ROOT", "LIMOUSINE_MCP_PORT", "LIMOUSINE_LAN")


def _clear_env(monkeypatch):
    for k in (*_KEYS, "LIMOUSINE_AGE_KEY", "LIMOUSINE_NO_KEY_PROMPT"):
        monkeypatch.delenv(k, raising=False)


def test_read_config_parses_file(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    _clear_env(monkeypatch)
    (tmp_path / ".limousine.config").write_text(
        '# a comment\nLIMOUSINE_WORKSPACE=/w/foo.wksp\nLIMOUSINE_MCP_PORT="7000"\nUNRELATED=x\n'
    )
    resolved, from_file = launch.read_config()
    assert resolved["LIMOUSINE_WORKSPACE"] == "/w/foo.wksp"
    assert resolved["LIMOUSINE_MCP_PORT"] == "7000"  # quotes stripped
    assert "UNRELATED" not in resolved
    assert "LIMOUSINE_WORKSPACE=/w/foo.wksp" in from_file


def test_env_wins_over_file(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    _clear_env(monkeypatch)
    (tmp_path / ".limousine.config").write_text("LIMOUSINE_CLONE_ROOT=/from/file\n")
    monkeypatch.setenv("LIMOUSINE_CLONE_ROOT", "/from/env")
    resolved, from_file = launch.read_config()
    assert resolved["LIMOUSINE_CLONE_ROOT"] == "/from/env"
    assert from_file == []  # env-sourced values aren't reported as "loaded from file"


def test_setup_wizard_writes_config(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    _clear_env(monkeypatch)
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    answers = iter(["/abs/foo.wksp", "/abs/clones", "7000", "y"])
    monkeypatch.setattr("builtins.input", lambda *a, **k: next(answers))

    saved = launch.run_setup_wizard()
    assert saved["mcp_port"] == 7000 and saved["lan"] is True
    assert saved["workspace"] == "/abs/foo.wksp"

    text = (tmp_path / ".limousine.config").read_text()
    assert "LIMOUSINE_WORKSPACE=/abs/foo.wksp" in text
    assert "LIMOUSINE_MCP_PORT=7000" in text
    assert "LIMOUSINE_LAN=1" in text
    resolved, _ = launch.read_config()
    assert resolved["LIMOUSINE_WORKSPACE"] == "/abs/foo.wksp"


def test_setup_wizard_needs_tty(monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    assert launch.run_setup_wizard() is None


def test_cli_reason_messages():
    from limousine.cli import _reason

    assert "file not found: /x/y.wksp" == _reason(FileNotFoundError(2, "nope", "/x/y.wksp"))
    assert _reason(ValueError("Invalid JSON in foo")) == "Invalid JSON in foo"
    assert "RuntimeError: boom" == _reason(RuntimeError("boom"))


def test_prompt_age_key_env_and_no_prompt(monkeypatch):
    monkeypatch.setenv("LIMOUSINE_AGE_KEY", "AGE-SECRET-KEY-xyz")
    assert launch.prompt_age_key() == "from LIMOUSINE_AGE_KEY"

    monkeypatch.delenv("LIMOUSINE_AGE_KEY")
    monkeypatch.setenv("LIMOUSINE_NO_KEY_PROMPT", "1")
    assert launch.prompt_age_key() == "locked (no key)"
