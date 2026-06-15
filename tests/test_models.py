import json

from limousine.core.models import McpConfig, Project, Workspace


def test_workspace_parse_and_mcp_default():
    ws = Workspace.from_json(
        {"name": "W", "projects": {"p": {"path-on-disk": "x", "optional-git-repo-url": "git@h:/r.git"}}}
    )
    assert ws.name == "W"
    assert ws.projects["p"].path_on_disk == "x"
    assert ws.projects["p"].git_repo_url == "git@h:/r.git"
    # no mcp block -> default-enabled config
    assert ws.mcp_config == McpConfig(enabled=True, port=6891)


def test_workspace_mcp_explicit_off_roundtrip():
    ws = Workspace.from_json({"name": "W", "projects": {}, "mcp": {"enabled": False, "port": 7000}})
    assert ws.mcp_config.enabled is False and ws.mcp_config.port == 7000
    assert ws.to_json()["mcp"] == {"enabled": False, "port": 7000}


def test_project_list_and_map_module_forms_equivalent():
    list_form = Project.from_json({"modules": [{"name": "m", "services": {"s": {"commands": {"run": "x"}}}}]})
    map_form = Project.from_json({"modules": {"m": {"services": {"s": {"commands": {"run": "x"}}}}}})
    for proj in (list_form, map_form):
        assert [m.name for m in proj.modules] == ["m"]
        assert proj.modules[0].services["s"].run_command == "x"


def test_module_config_declared_flag():
    declared = Project.from_json({"modules": [{"name": "m", "services": {}, "config": {}}]})
    undeclared = Project.from_json({"modules": [{"name": "m", "services": {}}]})
    assert declared.modules[0].config.declared is True
    assert undeclared.modules[0].config.declared is False


def test_agent_guide_list_joins_paragraphs():
    p = Project.from_json({"modules": [], "agent-guide": ["a", "b"]})
    assert p.agent_guide == "a\n\nb"


def test_service_default_command_precedence():
    from limousine.core.models import Service

    assert Service.from_json("s", {"commands": {"start": "a", "run": "b"}}).default_command == "b"
    assert Service.from_json("s", {"commands": {"dev": "c"}}).default_command == "c"
