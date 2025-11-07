
A python-based tkinter app for managing a web app dev environment.


## Dependenceis

Should use minimal dependencies, ideally just tcl/tk, subprocess, and
other built-ins.

Use uv to manage python dependencies. Main app source file should be `limousine/main.py`.

## Persistent Storage - global

Stores global data in a file `.limousine-project-driver` in the home
directory of the user. This should include:

```
{
    "limousine-project": [
        "<path/to/.limousine.project>",.
        ...
    ]
}
```

## Persistent Storage - per project

A folder containing a file named 

    .limousine-project

it should store the following data in the json format:

```
{
    "services": [
        {
            "name": "...",
            "git-repo-url": "<https or git url to a git project>",
            "clone-path": "relative-or-absolute-path/to/clone/project/at",
            "commands": {
              "run": "cli-command-to-start-the-server", # every service has a run command, may have others
              "migrate": "...",
              "seed-db": "..."
            },
            "config: {
                "active-env-file": ".env.dev",
                "active-secrets-env-file": "env.dev.secrets",
                "source-env-file": "env.example",
                "source-secrets-file": "env.secrets.example",
                "vault-secrets-path": "/path/in/vault/to/a/secret" #optional
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
        }
        "postgres": "",
        "redis": ""
    },
}

```

When each command is executed, it should generate a PID file:

```
  .limousine/pids/{command}.pid
```

which is removed when the command finishes.

## App Storage (in memory)

In memory, the app should use this model:

```
    {
        "current-project-file": "/path/to/.limousine-project",
        "services" {
            "<service-name>": {
                "command-state": {
                    "<command>": <long-running-process-data>
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

Where the long runnnig process data is:

```
    {
        "state": "<running|stopped>"
        "last-error": None | str,
        "pid": None | str , # if it has a value, process is running
        "start-time": <int-timestamp-seconds-since-epoch>
        "output": <open pipe for stdout + stderr>
    }
```

These can dedicated classes that implement the same conceptual model,
or actual python dicts, as seems most appropriate.


## UI layout

The app should have a tab-based layout with the following tabs:

  - Dashboard: this tab displays a list of the various services and
    docker-services. each row should have a dropdown menu at the end with options to:
      - clone the project if not present on disk (regular services only)
      - start/stop the service (regular services and docker servicse both)
      - "update env file", which updates the active env file from the source env file (but not the secrets), by adding keys that are present in source but not in active and then showing an alert summary. Also warns for entries present in active but not in source, for both env and secrets env.

    
  - [Service tab]: each module / docker service gets its own service
    tab. It should have a bar at the top that allows starting/stopping
    the service, and a dropdown to execute other commands (shows
    stdout/progress in a new window). Most of the window sohuld be a
    streaming log of the app log (stdout+stderr from the run command).


There should be a settings button (or dropdown menu) with an about
dialog thta shows the logs and version number (get from importlib).

## Running commands

Commands should run using the subprocess module, with stdout+stderr
captured in realtime. Every command should store a pid file on disk in
`.limousine/pids/<service>/<safe-command-name>.pid` and store the path
in the long-running process data. When the command ends, or is
stopped, the pid file should be deleted.

Commands should copy the system environment to run commands in.

## Responsiveness 

If the app does any potentially long running or UI blocking tasks, it
should show a spinner (e.g. cloning github repos), ideally with a
cancel button. 

## Source file structure

Aim for a modular approach with reusable components in separate
files. Files should not be longer than ~150 lines whenever possible,
though can go up to ~200 lines if necessary. Don't write comments. 

Use the standard `logging` module, piped to both stdout and a log
file. Log any exceptions caught with `exc_info=True`. Never swallow
exceptions without logging them. 

## Cross-platform

The app is intended to run on MacOs and Linux. 
