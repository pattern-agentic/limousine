
## Running

    python3 -m venv .venv
    source .venv/bin/activate
    pip install -r requirements.txt
    CTRL+D # to exit venv
    
    ./venv/bin/python -m limousine.m

On macOS, may need to install tkinter:

    brew install python-tk

Things can go wrong with TCL/TK version mismatches. The app prints out
the tcl/tk version it uses when it runs.

On linux, find the version of tcl tk:

    find /usr -name init.tcl
    find ~ -name init.tcl
    
    cat /usr/share/tcltk/tcl8.6/init.tcl | grep Tcl # should be ~8.6.xx
    


### Project file structure

At the root of the project, in a file named `limousine.proj`:

```
    {
      "modules": {
        "mgmt-api": {
          "services": {
            "mgmt-api": {
              "commands": {
                "start": "uv run uvicorn pattern_management_api.main:app",
                "alembic-heads": "uv run alembic heads",
                "upgrade-db": "uv run alembic upgrade head",
                "seed-db": "uv run python seed_db.py"
              }
            },
            ...
            "postgres-pattern": {
              "commands": {
                "start": "docker run --rm --name pattern-postgres -p 5432:5432 -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=$PN_MGMT_DB_PASSWORD -e POSTGRES_DB=pattern_management -v pattern_dev_postgres_data:/var/lib/postgresql/data postgres:15-alpine",
                "drop-db": "docker volume rm pattern_dev_postgres_data"
              }
            }
          },
          "config": {
            "active-env-file": ".env.dev",
            "source-env-file": "env.example",
            "secrets-file": ".env.secrets.dev",
            "secrets-example-file": "env.secrets.example"
          }
        }
      },
      "docker-services": {
        "nats": {
          "commands": {
            "start": "docker run --rm -p 4222:4222 -p 8222:8222 nats -js -sd /data -m 8222 "
          }
        }
      }
    }
```


### Workspace file structure

In a file named `limousine.wksp`:

```
{
  "name": "Pattern Agentic - App",
  "projects": {
    "mgmt-api": {
      "optional-git-repo-url": "git+ssh://github.com/pattern-agentic/pattern-management-api.git",
      "path-on-disk": "../mgmt-api"
    },
    "studio-frontend": {
      "optional-git-repo-url": "https://github.com/pattern-agentic/pa-studio-frontend.git",
      "path-on-disk": "."
    }
  }
}

```
