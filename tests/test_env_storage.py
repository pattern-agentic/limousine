from limousine.backend import env, storage


def test_env_parse_and_quoting():
    parsed = env.parse_env_lines(['# comment', 'A=1', 'B="two words"', "C='x'", 'bad', 'D=  v  '])
    assert parsed == {"A": "1", "B": "two words", "C": "x", "D": "v"}


def test_env_serialize_quotes_special_values():
    out = env.serialize({"A": "1", "B": "two words", "C": "a=b"})
    assert "A=1" in out
    assert 'B="two words"' in out
    assert 'C="a=b"' in out


def test_env_compare(tmp_path):
    (tmp_path / "active").write_text("A=1\n")
    (tmp_path / "source").write_text("A=1\nB=2\n")
    cmp = env.compare_env_files(tmp_path / "active", tmp_path / "source")
    assert cmp.active_exists and cmp.source_exists
    assert cmp.missing_in_active == {"B"}
    assert cmp.extra_in_active == set()


def test_pid_file_roundtrip_and_sanitize(tmp_path):
    wksp = tmp_path / "w.wksp"
    wksp.write_text("{}")
    storage.write_pid_file(wksp, "mod/svc", 4242)
    assert (storage.pids_dir(wksp) / "mod_svc.pid").exists()
    assert storage.load_all_pid_files(wksp) == {"mod/svc": 4242}
    storage.delete_pid_file(wksp, "mod/svc")
    assert storage.load_all_pid_files(wksp) == {}


def test_json_error_snippet_marks_bad_line():
    content = '{\n  "a": 1,\n  "b": oops\n}'
    snippet = storage.json_error_snippet(content, content.index("oops"))
    assert ">>>" in snippet
    assert "oops" in snippet


def test_project_exists_ignores_bare_git(tmp_path):
    proj = tmp_path / "proj"
    (proj / ".git").mkdir(parents=True)
    assert storage.project_exists_on_disk(tmp_path, "proj") is False
    (proj / "file.txt").write_text("x")
    assert storage.project_exists_on_disk(tmp_path, "proj") is True
