#!/bin/sh
# Stub Docker credential helper.
#
# macOS Docker Desktop sets `credsStore: desktop` (or `desktop-store`) in
# ~/.docker/config.json, which tells the docker CLI to invoke
# `docker-credential-desktop` for every auth lookup. That binary is part of
# the Docker Desktop GUI app — it doesn't exist inside our Linux container.
# Without this shim, ANY `docker run <public-image>` call from inside the
# limousine container fails the very first pull with:
#
#   docker: error getting credentials - err: exec: "docker-credential-desktop":
#   executable file not found in $PATH
#
# This script satisfies the binary lookup and answers the credential-helper
# protocol with "no credentials" — the CLI then falls through to anonymous
# auth, which is fine for public images (Docker Hub, ghcr.io public repos).
# Private registries (which would need real creds) still fail, but with an
# accurate error from the registry itself.
#
# Symlinked under all three names docker CLI might invoke on macOS:
#   docker-credential-desktop
#   docker-credential-desktop-store
#   docker-credential-osxkeychain
case "$1" in
  get)
    echo "credentials not found in native keychain" >&2
    exit 1
    ;;
  list)
    echo '{}'
    ;;
  store|erase)
    ;;
esac
exit 0
