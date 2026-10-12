# Dbee

Dbee is a small, native macOS database client for PostgreSQL, MySQL/MariaDB and SQLite. It is built
for working with databases on remote servers, usually over an SSH tunnel, and it does not store your
credentials in readable form anywhere. The one opt-in exception, Remember with Touch ID, keeps a
login encrypted by the Mac's Secure Enclave.

It is written in Swift with SwiftUI and AppKit, uses system controls throughout, and follows the
system appearance (including Dark Mode).

## Features

- **Databases:** PostgreSQL, MySQL and MariaDB, and local SQLite files.
- **Connections:** TLS modes Off, Preferred, Required (any certificate) and Verify Certificate.
  With Required or Verify Certificate, Dbee refuses a server that doesn't offer TLS before sending
  any login data. Verify Certificate needs the server's host name, not an IP address, for MySQL and
  for connections through an SSH tunnel.
  SSH tunnels with password or private key authentication, including passphrase-protected OpenSSH
  keys (Ed25519, RSA, ECDSA). You can paste a connection URL such as
  `postgres://db.example.com:5432/app?sslmode=require` into the host field.
- **Schema sidebar** with a filter field. Switch databases on the server from the toolbar.
- **Table browser:** paging, sorting, a filter builder, inline cell editing, adding and deleting
  rows. Edits are collected first; you can preview the generated SQL and commit everything in one
  transaction. While it commits, the transaction has the connection to itself, and Dbee won't start
  one while a transaction you opened in a query tab is still open.
- **Structure view:** columns, indexes, foreign keys and the table's DDL.
- **SQL editor:** syntax highlighting, completion for keywords, table and column names, line
  numbers, find, and comment toggling. Run the statement at the cursor, the selection, or the whole
  script. A script that returns several result sets lets you switch between them, and a running query
  can be cancelled.
- **Results grid** based on `NSTableView`, so large result sets stay responsive. The maximum number
  of rows read per statement is set in Settings.
- **Row inspector** that shows every column of the selected row, with JSON values pretty-printed.
- **Export and copy** as CSV, TSV, JSON, SQL `INSERT` statements or a Markdown table.
- **Query history** for the current window, kept in memory only.
- **Multiple windows and tabs**, each with its own independent connection.

## Privacy

Dbee has no accounts, analytics, telemetry or update checks. The only network connections it makes
are the database and SSH connections you open.

**Never written to disk, the Keychain, UserDefaults, caches or logs** (except as an encrypted Touch ID
login, below)**:**

- passwords and usernames (database and SSH)
- SSH private keys, key passphrases and key file paths (key files themselves are never copied)
- SQL text, query history and results (unless you export them yourself)
- window state (macOS window restoration is turned off)

Credentials live in memory only for as long as the connection is open, so Dbee can reconnect or
switch databases without asking again. They are wiped when you disconnect, close the window or quit.
A PostgreSQL connection doesn't need the password after signing in (stopping a query uses the
protocol's cancel key), so the driver drops it right away. MySQL keeps it in memory to reconnect and
to stop a running query from a second session. If a MySQL connection had to reconnect, Dbee tells you
when session settings such as autocommit, user variables, temporary tables or locks were lost,
instead of running the next statement without them.
Disconnecting also discards query results and history; query tabs keep only their SQL text.
Logging inside the database and SSH libraries is switched off, so hosts, users and SQL never reach
the system log.

**What is stored:**

- **Favorites**, only when you save one, and only while "Allow saving favorites" is on in Settings.
  A favorite holds a name, the database type, host, port, database name, TLS mode, the SQLite file
  path, and whether SSH is used with its host, port and authentication method (password or key, not
  the key path). You can remove all favorites from Settings.
- **Settings** you change: rows per page, maximum rows per query, editor font size, whether to keep
  query history during a session, and whether to confirm destructive actions.

Both are kept in the app's standard preferences (`defaults read app.dbee.Dbee`).

- **Touch ID logins**, only for favorites where you turn on *Remember with Touch ID*. Double-clicking
  such a favorite (or Connect with Touch ID) asks for Touch ID, then connects.
  - Each login is encrypted with AES-GCM under a key derived (HKDF-SHA256) from two secrets, and both
    are needed:
    - an ECDH secret from its own P-256 key created inside the Secure Enclave with
      `.biometryCurrentSet`. That key never leaves the Enclave, every use needs a fresh Touch ID check,
      there is no Mac-password fallback, and enrolling a new fingerprint makes it permanently unusable;
    - a random 32-byte secret in the login Keychain (never synced). Dbee created it, so Dbee reads it
      without a prompt; any other app trying to read it gets a macOS Keychain prompt that needs your
      Mac password.
  - On disk there is only ciphertext and the Enclave's wrapped key blob, in
    `~/Library/Application Support/app.dbee.Dbee/Logins/` (folder `0700`, files `0600`, excluded from
    Time Machine). None of it is usable on any other Mac.
  - The login is sealed together with the favorite's server details: type, host, port, database, TLS
    mode and SSH host, port and method. If the favorite is changed to point anywhere else (for example
    by something editing the preferences file), the login refuses to open and is deleted, so the real
    password can't be redirected to another server.
  - Saving never prompts; it needs only the public key. The login is saved when you save or update
    the favorite, and refreshed after each successful connect from it.
  - Forgetting a login deletes its Keychain secret as well as the file, so a copy of the file taken
    earlier (from a backup, say) can never be opened. Saving again rotates the secret the same way.
    Deleting a favorite, turning the toggle off, *Forget Saved Login* (right-click a favorite) and
    *Settings → Privacy → Forget All Saved Logins* all do this.
  - An opened login goes straight to the connection. It is never put back into the editable form, so
    it can't be read off the screen or sent to a host typed in afterwards. After that it follows the
    normal rules above: memory only, wiped on disconnect.
  - What this protects against: a stolen or lost Mac, copied files and backups, other Macs, and
    anything that rewrites your favorites. What no client can fully protect against is malware already
    running as you: it could watch you type a password, or ask you to approve both a fake Touch ID
    prompt and a Keychain password prompt. Approve these prompts only when you just asked Dbee to
    connect.
  - Ad-hoc signed builds (the default for `scripts/build-app.sh`) get a new code signature on every
    build, so the first connect after a rebuild may show a Keychain prompt for Dbee itself; choose
    *Always Allow*. Signing with a stable identity (`SIGN_IDENTITY=...`) avoids this.

### SSH host keys

When opening a tunnel, Dbee checks the server's host key against `~/.ssh/known_hosts` (and
`known_hosts2`, `/etc/ssh/ssh_known_hosts`). These files are only read, never written.

- If the key matches a known entry, the connection continues without asking.
- If the host is not listed, Dbee shows the key type and SHA256 fingerprint in a sheet on the window
  and asks whether to trust it. Switching databases keeps the tunnel open, and reconnecting accepts
  the same key again without asking, until you disconnect or close the window.
- If the key does not match the listed one, or is marked `@revoked`, Dbee refuses to connect, as
  `ssh` does, and explains how to remove the old entry with `ssh-keygen -R`.
- If `known_hosts` only lists a different type of key for the host (for example an old ECDSA entry
  while the server offers Ed25519), Dbee warns about it and Cancel is the default answer.

While a tunnel is open, its local port only forwards the connections Dbee itself makes; other
programs on the Mac can't use it. PostgreSQL connections don't use the local port at all. Dbee also
checks that the SSH server is still answering, so a dead link is reported within about a minute.

Dbee never writes these decisions to disk. To stop being asked, add the host to `~/.ssh/known_hosts`
yourself, for example by connecting once with `ssh` and checking the fingerprint.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New window |
| ⌘T | New query tab |
| ⌘↩ | Run the statement at the cursor, or the selection |
| ⇧⌘↩ | Run all statements |
| ⌘. | Stop the running query |
| ⌘R | Refresh |
| ⌘S | Commit table edits |
| ⌥⌘0 | Show or hide the row inspector |
| ⌘/ | Toggle comment |
| ⌘F | Find in the editor |
| ⇧⌘D | Disconnect |

## Building

Requirements: macOS 14 or later, Xcode 16 or later (Swift 6 toolchain).

```sh
make build    # debug build (swift build)
make app      # release build, assembled into build/Dbee.app
make run      # build the app and open it
make test     # swift test
make clean    # remove build products and build/
```

`make app` runs `scripts/build-app.sh`, which builds a universal (Apple silicon and Intel) release
binary, falling back to Apple silicon only if the universal build fails, then assembles
`build/Dbee.app` and signs it ad hoc with the hardened runtime. Two environment variables change that:

- `ARCHS=arm64` builds for Apple silicon only, which is faster.
- `SIGN_IDENTITY="Developer ID Application: …"` signs with your certificate (with a secure timestamp)
  instead of ad hoc. An ad-hoc signed app runs on the Mac that built it; to share it with others, sign
  it with a Developer ID and notarize it.

The app icon is generated by `scripts/make-icon.swift` and checked in as `Resources/AppIcon.icns`.
Run `make icon` to regenerate it.

## Tests

```sh
swift test
```

Unit tests need nothing else. Integration tests run against real servers and are skipped unless
their environment variables are set, so they are optional. To run them with Docker:

```sh
docker run -d --name dbee-it-postgres -e POSTGRES_PASSWORD=dbee_test \
  -p 127.0.0.1:55432:5432 postgres:16
docker run -d --name dbee-it-mysql -e MYSQL_ROOT_PASSWORD=dbee_test -e MYSQL_DATABASE=dbee \
  -p 127.0.0.1:53306:3306 mysql:8.4
docker run -d --name dbee-it-mariadb -e MARIADB_ROOT_PASSWORD=dbee_test -e MARIADB_DATABASE=dbee \
  -p 127.0.0.1:53307:3306 mariadb:11

DBEE_PG_PORT=55432 DBEE_MYSQL_PORT=53306 DBEE_MARIADB_PORT=53307 swift test
```

| Variable | Enables |
| --- | --- |
| `DBEE_PG_PORT` | PostgreSQL driver tests (user `postgres`, password `dbee_test`) |
| `DBEE_MYSQL_PORT` | MySQL driver tests (user `root`, password `dbee_test`, database `dbee`) |
| `DBEE_MARIADB_PORT` | The same tests against MariaDB |
| `DBEE_SSH_PORT` | SSH tunnel tests against an OpenSSH server |
| `DBEE_TB_PG_PORT`, `DBEE_TB_MYSQL_PORT` | Table browser editing tests; also need `DBEE_TB_USER`, `DBEE_TB_PASSWORD` and `DBEE_TB_DATABASE`, valid on both servers |
| `DBEE_E2E_PG_HOST`, `DBEE_E2E_MYSQL_HOST`, `DBEE_E2E_MARIADB_HOST` | End-to-end tests that reach each database through the SSH tunnel (with `DBEE_SSH_PORT`) |

The SSH tunnel tests expect an OpenSSH server with TCP forwarding enabled, a `dbee` user, and the test
key pairs in the directory named by `DBEE_SSH_KEYS_DIR`. See `Tests/DbeeTests/SSHTunnelTests.swift`
for the exact setup. Test passwords come from the environment or test defaults; nothing about a real
server is stored in the repository.

The end-to-end tests use host names that only resolve on the SSH server's Docker network, which proves
the traffic went through the tunnel. Attach the database containers to that network first:

```sh
docker network connect --alias pg dbee-it-net dbee-it-postgres
docker network connect --alias mysql dbee-it-net dbee-it-mysql
docker network connect --alias mariadb dbee-it-net dbee-it-mariadb
DBEE_SSH_PORT=52222 DBEE_E2E_PG_HOST=pg DBEE_E2E_MYSQL_HOST=mysql DBEE_E2E_MARIADB_HOST=mariadb \
  swift test --filter EndToEnd
```

Remove the containers when you're done:

```sh
docker rm -f dbee-it-postgres dbee-it-mysql dbee-it-mariadb
```
