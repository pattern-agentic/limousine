"""In-memory secrets gateway, backed by `sops` + `age`.
Port of lib/server/secret_store.dart.

Holds the dev's age private key (pasted at startup via the wrapper) in memory;
never touches disk with it. Public key is derived once and cached.

All encryption / decryption is delegated to the `sops` CLI. Limousine does NOT
inject secrets into spawned services — the start command in each project's
limousine.proj does `sops exec-env secrets.env '<cmd>'` itself. This module's
runtime responsibilities are:
  - validate the key on startup against a `secret-store-stamp` (sops-encrypted)
  - serve the secrets editor UI (decrypt for view, encrypt on save)
  - expose the private key so the service manager can forward SOPS_AGE_KEY into
    spawned child processes

Deliberately not called "vault" — that name belongs to HashiCorp Vault, and
this is a much smaller, single-key local-disk feature.
"""

from __future__ import annotations

import asyncio
import enum
import hmac
import logging
import os
import tempfile
from pathlib import Path

from . import env as env_mod

_log = logging.getLogger("limousine.secret_store")


class SecretStoreStatus(enum.Enum):
    # No age private key was supplied at startup. Server runs but services that
    # need encrypted secrets cannot start (their commands will sops-fail).
    MISSING_KEY = "missingKey"

    # Key supplied + stamp existed + decrypted successfully.
    VERIFIED = "verified"

    # Key supplied + no stamp on disk → just created one with this key.
    NEW_STAMP = "newStamp"

    # Key supplied + stamp existed + sops decryption failed. The caller treats
    # this as fatal and exits.
    MISMATCH = "mismatch"


class SecretStoreLockedException(Exception):
    pass


_STAMP_PLAINTEXT = "limousine-secret-store-v2"


class SecretStore:
    def __init__(self) -> None:
        self._private_key: str | None = None  # AGE-SECRET-KEY-…
        self._public_key: str | None = None  # age1…
        self._status: SecretStoreStatus = SecretStoreStatus.MISSING_KEY
        self._workspace_dir: str | None = None
        self.on_status = None  # callback(SecretStoreStatus) — replaces the Dart stream

    @property
    def status(self) -> SecretStoreStatus:
        return self._status

    @property
    def unlocked(self) -> bool:
        return self._private_key is not None

    @property
    def private_key(self) -> str | None:
        """The age private key, exposed so the service manager can forward it
        into child processes as SOPS_AGE_KEY. None if the store is locked."""
        return self._private_key

    @property
    def workspace_dir(self) -> str | None:
        return self._workspace_dir

    @staticmethod
    def stamp_path_for(workspace_path: str | Path) -> str:
        return str(Path(workspace_path).parent / ".limousine" / "secret-store-stamp")

    def _set_status(self, s: SecretStoreStatus) -> None:
        self._status = s
        if self.on_status:
            self.on_status(s)

    async def init_for_workspace(self, workspace_path: str | Path) -> None:
        """Read `LIMOUSINE_AGE_KEY` from the environment, validate it by deriving
        the public key, then verify or create the workspace stamp file."""
        self._workspace_dir = str(Path(workspace_path).parent)
        key_env = os.environ.get("LIMOUSINE_AGE_KEY")
        self._private_key = None
        self._public_key = None

        if not key_env:
            self._set_status(SecretStoreStatus.MISSING_KEY)
            _log.warning(
                "LIMOUSINE_AGE_KEY not set — secret store locked. "
                "Services with encrypted secrets will fail to decrypt."
            )
            return

        pub = await self._derive_public_key(key_env.strip())
        if pub is None:
            self._set_status(SecretStoreStatus.MISMATCH)
            _log.error(
                "LIMOUSINE_AGE_KEY does not parse as a valid age private key. "
                "Restart with a key produced by `age-keygen`."
            )
            return
        self._private_key = key_env.strip()
        self._public_key = pub

        stamp_path = self.stamp_path_for(workspace_path)
        if not Path(stamp_path).exists():
            _log.info("No secret-store stamp at %s — creating one.", stamp_path)
            try:
                await self._create_stamp(stamp_path)
            except Exception as e:
                self._private_key = None
                self._public_key = None
                self._set_status(SecretStoreStatus.MISMATCH)
                _log.error("Failed to create stamp: %s", e)
                return
            self._set_status(SecretStoreStatus.NEW_STAMP)
            _log.info(
                "Secret-store stamp created. This age key is now bound to %s. "
                "Restart with a different key and the server will refuse to start.",
                Path(workspace_path).name,
            )
            return

        ok = await self._verify_stamp(stamp_path)
        if ok:
            self._set_status(SecretStoreStatus.VERIFIED)
            _log.info("Secret-store stamp verified.")
        else:
            self._private_key = None
            self._public_key = None
            self._set_status(SecretStoreStatus.MISMATCH)
            _log.error(
                "SECRET-STORE STAMP MISMATCH for %s. The supplied age key does "
                "not decrypt the existing stamp. Restart with the correct key, "
                "or delete %s plus any encrypted secrets.env files to start fresh.",
                Path(workspace_path).name,
                stamp_path,
            )

    async def unlock(self, private_key: str) -> SecretStoreStatus:
        """Supply the age key at runtime (secrets editor) when it wasn't in the
        env at startup. Derives the pubkey and verifies/creates the stamp, same
        contract as init_for_workspace."""
        if self._workspace_dir is None:
            raise RuntimeError("no workspace open")
        pub = await self._derive_public_key(private_key.strip())
        if pub is None:
            return SecretStoreStatus.MISMATCH
        self._private_key = private_key.strip()
        self._public_key = pub
        stamp_path = str(Path(self._workspace_dir) / ".limousine" / "secret-store-stamp")
        if not Path(stamp_path).exists():
            await self._create_stamp(stamp_path)
            self._set_status(SecretStoreStatus.NEW_STAMP)
        elif await self._verify_stamp(stamp_path):
            self._set_status(SecretStoreStatus.VERIFIED)
        else:
            self._private_key = None
            self._public_key = None
            self._set_status(SecretStoreStatus.MISMATCH)
        return self._status

    def verify_header_key(self, candidate: str) -> bool:
        """Constant-time equality check of an API auth header against the
        in-memory key, before returning secret values over the wire."""
        stored = self._private_key
        if stored is None:
            return False
        return hmac.compare_digest(candidate.strip(), stored)

    async def decrypt_secrets(self, path: str | Path) -> dict[str, str]:
        """Decrypt the dotenv-formatted, sops-encrypted secrets file at [path]."""
        if not Path(path).exists():
            return {}
        key = self._private_key
        if key is None:
            raise SecretStoreLockedException(
                "Secret store is locked. Restart the server with LIMOUSINE_AGE_KEY set."
            )
        result = await self._sops_decrypt(str(path), key)
        if result is None:
            raise SecretStoreLockedException(
                f"Failed to decrypt {path}. The file may not be sops-encrypted, or "
                "it was encrypted to a different age recipient than the current key."
            )
        return env_mod.parse_env_lines(result.split("\n"))

    async def save_secrets(self, path: str | Path, content: dict[str, str]) -> None:
        """Encrypt [content] (dotenv KV map) and write the sops-armored result
        to [path]. Overwrites in place."""
        pub = self._public_key
        if pub is None:
            raise SecretStoreLockedException(
                "Secret store is locked. Cannot save encrypted secrets."
            )
        plain = env_mod.serialize(content)
        encrypted = await self._sops_encrypt(plain, pub)
        if encrypted is None:
            raise SecretStoreLockedException(f"sops encrypt failed for {path}")
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(encrypted)

    def dispose(self) -> None:
        self._private_key = None
        self._public_key = None

    # ------------------------------------------------------------------------
    # sops/age shell-out helpers
    # ------------------------------------------------------------------------

    async def _derive_public_key(self, private_key: str) -> str | None:
        proc = await asyncio.create_subprocess_exec(
            "age-keygen",
            "-y",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out_b, err_b = await proc.communicate(f"{private_key}\n".encode())
        if proc.returncode != 0:
            _log.warning("age-keygen -y failed: %s", err_b.decode())
            return None
        pub = out_b.decode().strip()
        if not pub.startswith("age1"):
            _log.warning("age-keygen -y produced unexpected output: %s", pub)
            return None
        return pub

    async def _sops_decrypt(self, path: str, private_key: str) -> str | None:
        """`sops -d --input-type dotenv --output-type dotenv <path>`. Returns
        decrypted dotenv text, or None on any failure."""
        env = {**os.environ, "SOPS_AGE_KEY": private_key}
        proc = await asyncio.create_subprocess_exec(
            "sops",
            "-d",
            "--input-type",
            "dotenv",
            "--output-type",
            "dotenv",
            path,
            env=env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out_b, err_b = await proc.communicate()
        if proc.returncode != 0:
            _log.warning("sops -d %s failed (exit %s): %s", path, proc.returncode, err_b.decode())
            return None
        return out_b.decode()

    async def _sops_encrypt(self, plaintext: str, public_key: str) -> str | None:
        """`sops -e --age <pub> --input-type dotenv --output-type dotenv <file>`.
        Returns encrypted text, or None on failure."""
        # sops doesn't read /dev/stdin reliably for typed inputs; round-trip via
        # a tempfile (with a .env extension) to make input-type detection
        # deterministic.
        with tempfile.TemporaryDirectory(prefix="limousine-sops-") as tmp:
            input_path = str(Path(tmp) / "in.env")
            Path(input_path).write_text(plaintext)
            proc = await asyncio.create_subprocess_exec(
                "sops",
                "-e",
                "--age",
                public_key,
                "--input-type",
                "dotenv",
                "--output-type",
                "dotenv",
                input_path,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            out_b, err_b = await proc.communicate()
            if proc.returncode != 0:
                _log.warning("sops -e failed (exit %s): %s", proc.returncode, err_b.decode())
                return None
            return out_b.decode()

    async def _create_stamp(self, stamp_path: str) -> None:
        assert self._public_key is not None
        encrypted = await self._sops_encrypt(
            f"LIMOUSINE_STAMP={_STAMP_PLAINTEXT}\n",
            self._public_key,
        )
        if encrypted is None:
            raise RuntimeError("sops encrypt failed creating stamp")
        p = Path(stamp_path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(encrypted)

    async def _verify_stamp(self, stamp_path: str) -> bool:
        assert self._private_key is not None
        decrypted = await self._sops_decrypt(stamp_path, self._private_key)
        if decrypted is None:
            return False
        return f"LIMOUSINE_STAMP={_STAMP_PLAINTEXT}" in decrypted
