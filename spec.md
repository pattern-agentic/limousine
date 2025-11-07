
A python-based tkinter app for managing a web app dev environment.


## Dependencies

Should use minimal dependencies, ideally just tcl/tk, subprocess, and
other built-ins.

Use uv to manage python dependencies. Main app source file should be `limousine/main.py`.

## Persistent Storage - global

Stores global data in a file `.limousine` in the home
directory of the user. This should include:

```
{
    "limousine-project": [
        "<path/to/.limousine.proj>",
        ...
    ]
}
```

## Persistent Storage - per project

A folder containing a file named 

    .limousine.proj

it should store the following data in the json format:

```
{
    "modules": [
        {
            "name": "...",
            "git-repo-url": "<https or git url to a git project>",
            "clone-path": "relative-or-absolute-path/to/clone/project/at",
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

When each command is executed, it should generate a PID file:

```
  .limousine/pids/{service-name}-{safe-command-name}.pid
```

which is removed when the command finishes.

## App Storage (in memory)

In memory, the app should use this model:

```
    {
        "current-project-file": "/path/to/.limousine-proj",
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


## UI layout - startup

On startup, the app should read the global configuration. If it's
missing or empty, it should create it and ask to select a project
folder with a `.limousine-proj` file. If present and there is one
project, it should load that one. If present and there are multiple
projects, it should ask the user which one to load. Once a project is
selected it should move to the main layout.

## UI layout - main layout

The app should have a tab-based layout with the following tabs:

  - Dashboard: this tab displays a list of the various module-services
    and docker-services (services of the same modules should be
    grouped in some way). each module should have a dropdown menu at the
    end with options to:
      - clone the project if not present on disk 
      - "update env file", see dedicated section
      
    each service should have buttons at the end to:
      - start/stop the service (regular services and docker servicse both)

    
  - [Service tab]: each service / docker service gets its own service
    tab. It should have a bar at the top that allows starting/stopping
    the service, and a dropdown to execute other commands (shows
    stdout/progress in a new window). Most of the window should be a
    streaming log of the app log (stdout+stderr from the run
    command). 


There should be a settings button (or dropdown menu) with an about
dialog thta shows the log path for the app log (not service logs) and
version number (get from importlib).

## Running commands

Commands should run using the subprocess module, with stdout+stderr
captured in realtime. Every command should store a pid file on disk
(as previously specified) and store the path in the long-running
process data. When the command ends, or is stopped, the pid file
should be deleted.

Commands should copy the system environment to run commands in, and
load the active env file and active secrets file into the env of the
command before running it.

If a stale pidfile exists when the app tries to start a command (left
over from a previous crashed app for example), the app should check if
the process exists. If it doesn't it can just remove the pid file and
sproceed. If it doesn, ti should prompt the user if they want to kill
the process and proceed or astop.

The project should leverage external commands where appropriate,
e.g. to clone git repos. 


## Env file loading/updating

When an env file is updated via the menu option, it should:

  - copy the source file to the active file if no active file is present (same for secrets)
  - OR, if active file is present, update the active file from the source env file (but not the secrets), by adding keys that are present in source but not in active and then showing an alert summary. Also warns for entries present in active but not in source, for both env and secrets env.

## Service dependencies

Resonsibility for starting the services in the right order is currently the responsibility of the user.

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
