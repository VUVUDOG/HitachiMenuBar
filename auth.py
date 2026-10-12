"""Persistent login lifecycle shared with the native menu bar application."""
import fcntl
import json
import uuid
from contextlib import contextmanager

import keyring


class StaleSession(Exception):
    """A newer login/logout has superseded this worker."""


class SessionStore:
    def __init__(self, runtime, service):
        self.runtime = runtime
        self.service = service
        self.generation = None

    @contextmanager
    def locked(self):
        with (self.runtime / "auth.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def _read(self):
        path = self.runtime / "auth.json"
        return json.loads(path.read_text()) if path.exists() else None

    def _write(self, name, value):
        target = self.runtime / name
        temporary = self.runtime / (name + "." + uuid.uuid4().hex + ".tmp")
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
        temporary.replace(target)

    def _current(self):
        state = self._read()
        if not state or state["generation"] != self.generation:
            raise StaleSession()
        return state

    def _clear_cache(self):
        for name in ("report.json", "devices.json", "status.json", "login.png"):
            (self.runtime / name).unlink(missing_ok=True)

    def begin(self, action=None, expected=None):
        with self.locked():
            state = self._read()
            if expected:
                if not state or state["generation"] != expected:
                    raise StaleSession()
            elif action in ("login", "logout", "import"):
                retired = set((state or {}).get("retired_accounts", []))
                retired.add((state or {}).get("account", "session"))
                state = {"generation": uuid.uuid4().hex, "state": "logged_out",
                         "retired_accounts": sorted(retired)}
                self._write("auth.json", state)
                self._clear_cache()
            elif state is None:
                # Preserve a valid pre-0.3 login without asking the user to scan again.
                # Do not hold the filesystem lock while Keychain may ask for
                # permission: native logout/relogin must remain cancellable.
                state = {"generation": uuid.uuid4().hex, "state": "authenticated", "account": "session"}
                self._write("auth.json", state)
            self.generation = state["generation"]
            if action in ("login", "import"):
                state["state"] = "pending"
                state["account"] = "session." + self.generation
                self._write("auth.json", state)
            retired = state.get("retired_accounts", [])
        if action in ("login", "logout", "import"):
            # Revocation is already persisted. Keychain work must not block the
            # native app's lock. Retired accounts remain recorded for interrupted
            # cleanup or an older worker finishing a Keychain write late.
            for account in retired:
                try:
                    keyring.delete_password(self.service, account)
                except keyring.errors.PasswordDeleteError:
                    pass
            with self.locked():
                self._current()

    def credentials(self):
        with self.locked():
            state = self._current()
            if state["state"] != "authenticated":
                return None
            account = state["account"]
        saved = keyring.get_password(self.service, account)
        with self.locked():
            state = self._current()
            if not saved:
                state["state"] = "logged_out"
                self._write("auth.json", state)
                self._clear_cache()
            return json.loads(saved) if saved else None

    def save_credentials(self, credentials):
        with self.locked():
            state = self._current()
            account = state["account"]
        keyring.set_password(self.service, account, json.dumps(credentials))
        try:
            with self.locked():
                state = self._current()
                state["state"] = "authenticated"
                self._write("auth.json", state)
        except StaleSession:
            try:
                keyring.delete_password(self.service, account)
            except keyring.errors.PasswordDeleteError:
                pass
            raise

    def memory_credentials(self, credentials):
        """Use the native app's session over a private pipe, never from a file."""
        with self.locked():
            state = self._current()
            if state["state"] != "authenticated":
                raise StaleSession()
            required = ("user_id", "ssecurity", "service_token")
            if not isinstance(credentials, dict) or not all(isinstance(credentials.get(k), str) and credentials[k] for k in required):
                raise ValueError("invalid memory session")
            return {key: credentials[key] for key in required}

    def write_json(self, name, value):
        with self.locked():
            self._current()
            self._write(name, {**value, "generation": self.generation} if isinstance(value, dict) else value)

    def write_qr(self, image):
        with self.locked():
            self._current()
            (self.runtime / "login.png").write_bytes(image)

    def clear_qr(self):
        with self.locked():
            self._current()
            (self.runtime / "login.png").unlink(missing_ok=True)
