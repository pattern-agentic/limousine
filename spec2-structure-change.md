
# Project file structure change

Instead of the previous structure where the git repo url and the clone
path are specified in the `limousine.proj` file, we take them out, so
the structure becomes:

```
{
    "modules": [
        {
            "name": "...",
            "services": {
                "<name>" => {
                    "commands": {
                      "run": "cli-command-to-start-the-server", # every service has a run command, may have others
                      "migrate": "...",
                      "seed-db": "..."
                    },
                    ...
                }
            }
            "config": {
                "active-env-file": ".env.dev",
                "active-secrets-env-file": "env.dev.secrets",
                "source-env-file": "env.example",
                "source-secrets-file": "env.secrets.example",
            }
        },
        ...
    ],
    "docker-services": {
        "nats": {
            "commands": {
                "start": "...", # every docker service has start and stop commands, may have others
                "stop": "..."
            }
        },
        "postgres": "",
        "redis": ""
    },
}

```

(same structure, no github url or clone path in the module).

Instead, we add support for workspace files named `limousine.wksp`,
which should have this structure:

```
{
    "name": "...",
    "projects": {
        "proj-name": {
            "path-on-disk": "relative/or/absolute/path",
            "optional-git-repo-url": "<https or git url to a git project>"
        }
    }
}
```

Global storage in `~/.limousine` should reference the workspace files:

```
{
    "limousine-workspaces": [
        "<path/to/.limousine.wksp>",
        ...
    ]
}
```

When the app first loads, instead of a `limousine.proj` file, it
should display the list of previous workspace files, with the option
to open a `limousine.wksp` file. 

In memory storage should look like:

```
    {
        "current-workspace-file": "/path/to/limousine.wksp",
        "projects": {
            "project-name": {
                "path-on-disk": "...",
                "optional-git-repo-url": "..",
                "exists-on-disk": True|False
            }
        },
        "modules" {
            "<module-name>": {
                "services": {
                   "<service-name>" : {
                        "command-state": {
                            "<command>": <long-running-process-data>
                        },
                    },
                    ...
                },
                "source-state": {
                    "cloned": true | false
                },
            }
        },
        "docker-services": {
            "command-state": {
                "<command>": <long-running-process-data>
            }
        }
    }
```

Where the modules/docker services maintain the same structure (minus
the path/git rep for modules), and they're loaded from the
`limousine.proj` files in the path of each project that exists on disk. 

# UI Modifications

The dashboard should be modified to display the projects, with the
path of each project, whether it exists on disk, and a `clone` button
if it does not exist on disk and if a git url was provided.

The service/docker tabs remain as before. However we want to add a dropdown at the top right of each service tab (not for docker tabs) ( see @limousine/ui/service_tab/service_tab.py ) that shows  `Show env variables...` or `Show secrets...` . 

### Show env variables dialog

This dialog should open in a new window (and live in a new source
file). It should show side-by-side views of the active and source env
files. If the active file it shows a notice `env file missing, copy
from {source-env-file}?`.

### Show secrets dialogic

Similarly, this dialog should open in a new window and live in a
separate soruce file. It should show die-by-side views of the active
and source secret files.
