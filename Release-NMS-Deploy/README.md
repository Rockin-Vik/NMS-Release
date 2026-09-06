# Release-NMS-Deploy

Build and install automation for the NMS server on a fresh Windows box.

| File | What it is |
| --- | --- |
| [`CODEBASE.md`](CODEBASE.md) | **Read this first.** Working understanding of the codebase — architecture, what is custom vs stock EQEmu, the migration system, and a gotchas index. |
| [`FABLED-ENCOUNTERS.md`](FABLED-ENCOUNTERS.md) | The Fabled season: why the old `Custom:EnableFabledMobs` toggle was a no-op, the push-based C++ design as implemented (`#fabled`, `fabled_npcs`, `fabled_season`), and what remains to build and test. |
| [`build-scripts/1-Install-Prerequisites.ps1`](build-scripts/1-Install-Prerequisites.ps1) | Audits the box and installs what is missing. |
| [`build-scripts/2-Setup-NMSServer.ps1`](build-scripts/2-Setup-NMSServer.ps1) | Clone → database → build → configure → run. |

Copy the whole `build-scripts/` folder to the server and run from inside it — the scripts
take all their paths from parameters, so they work from any location.

> ### The Perl version is not a free choice
>
> `zone.exe` **embeds** whichever Perl CMake finds (`cmake/DependencyHelperMSVC.cmake`
> calls `FIND_PACKAGE(PerlLibs)` and falls back to downloading portable Strawberry
> **5.24.4.1**; `CMakeLists.txt:28` pins **5.32.1** for Linux static builds). The quest
> plugins run inside *that* interpreter, so its CPAN modules and DBD driver are the ones
> that matter — not some other Perl on `PATH`.
>
> These scripts pin **Strawberry Perl 5.32.1.1**, installed from the vendor MSI rather
> than winget, for two independent reasons:
>
> - EQEmu's embedded-Perl code predates the API changes in newer Perls.
> - Strawberry 5.40+ moved to UCRT, and `DBD::MariaDB` still references the msvcrt-era
>   internal `__pioinfo` — it compiles, then dies at link with
>   `undefined reference to __imp___pioinfo`.
>
> On a fresh box this is handled for you. If the machine already has Perl 5.40 or newer,
> uninstall it first (Programs and Features → Strawberry Perl) — stage 1 detects an
> out-of-range Perl and stops rather than building against it. Decide this **before
> building**: changing Perl afterwards means rebuilding the server.

---

## Quick start

From an **elevated** PowerShell prompt, inside `build-scripts\`:

```powershell
# 1. See where the box stands (changes nothing)
.\1-Install-Prerequisites.ps1 -CheckOnly

# 2. Install what is missing (~30-60 min, mostly VS Build Tools)
.\1-Install-Prerequisites.ps1

# 3. Open a NEW PowerShell window so it picks up the updated PATH, then:
.\2-Setup-NMSServer.ps1
```

> Re-run stage 1 until the summary shows **no Failed rows**. It is idempotent — everything
> already present is skipped — and some steps only become reachable once an earlier one has
> landed. In particular, if Perl reports `PATH refresh pending`, the CPAN and DB-driver
> rows will be absent entirely rather than failing; a second run in a fresh shell picks
> them up.

Total: **2–4 hours** on a fresh box. The build (~30 min) and the database import (~20 min)
dominate.

When it finishes:

```powershell
cd C:\NMS\server
.\start-server.ps1
.\status-server.ps1
```

---

## What gets installed

**Stage 1** — VS 2022 Build Tools (C++ workload), CMake, Git, 7-Zip, MariaDB 11
(loopback-only), Strawberry Perl, and the CPAN modules `DBI`, `JSON`, `Switch`, plus a
database driver. Every check is skip-if-present, so re-running is safe.

> **On the DBD driver.** `DBD::mysql` 5.x removed MariaDB support and will not build
> against MariaDB's client libraries; 4.050 could, but no longer builds on Perl 5.42+.
> So on a MariaDB box the script installs **`DBD::MariaDB`** and accepts an existing
> `DBD::mysql` only if you happen to run real MySQL.
>
> `Release-NMS-Plugins/MySQL.pl` originally hardcoded a `dbi:mysql:` DSN, which only
> `DBD::mysql` serves. This fork patches `try_connect` to ask `DBI->available_drivers`
> and use whichever is present — MySQL boxes behave exactly as before, MariaDB boxes now
> work. Without that patch, item upgrade tiers and expansion progression fail silently.

**Stage 2** — thirteen stages, each independently re-runnable:

| # | Stage | Notes |
| --- | --- | --- |
| 1 | Clone | Public repo, `--depth 1`. ~700 MB. |
| 2 | Database | Generated password, utf8mb4, imports the 540 MB dump. |
| 3 | Build | CMake + MSBuild, Release/x64, parallel. |
| 4 | Runtime | Assembles `C:\NMS\server` — binaries, patches, 8,000 quests, 52 plugins. |
| 5 | Maps | Fetches zone pathing/LOS maps. **Not in the repo, in no README.** |
| 6 | Config | `eqemu_config.json` + `login.json` with real credentials and the public IP. |
| 7 | Migrate | `shared_memory`, then boots world until both manifests reach target. |
| 8 | Patches | The 11 loose `.sql` files nothing else applies (incl. the Fabled roster seed). Runs *after* Migrate. |
| 9 | Login | Loginserver schema + `launcher` seed. In no manifest, not in the dump. |
| 10 | Health | `nms_content_health_check.sql`, because `custom_version` lies. |
| 11 | Export | `export_client_files` → the four client files + `eqhost.txt`. |
| 12 | Services | NSSM services (manual start) + a boot task that sequences them. |
| 13 | Firewall | UDP 5998, 5999, 7000-7400, 7778, 9000. |

Layout under `C:\NMS`:

```
C:\NMS\
  src\              the cloned repo
  server\           the running server + start/stop/status scripts
  client-files\     what you hand players (overlay + the 4 exported files + README)
  logs\             transcripts and health-check output
  credentials.txt   generated passwords - Administrators only. BACK THIS UP.
```

---

## Resuming after a failure

Every stage is re-runnable. Fix the cause, then resume:

```powershell
.\2-Setup-NMSServer.ps1 -Stage Build      # from Build onward
.\2-Setup-NMSServer.ps1 -OnlyStage Health # just that one stage
```

Useful flags: `-SkipDatabaseImport` (the slowest stage), `-PublicAddress <ip>` (if the box
is behind NAT), `-InstallRoot <path>`.

> If you change `-InstallRoot`, pass a matching `-CredentialFile` to stage 1 — otherwise
> stage 2 will not find the MariaDB root password and will prompt.

---

## Design decisions

**Build on the VPS, not elsewhere.** `zone.exe` links against — and embeds — a specific
Perl. Building on the box that runs it removes a whole class of "zone.exe won't start"
problems, and guarantees the quest plugins' CPAN modules live in the interpreter the
server actually uses.

**Local loginserver, not Project EQ.** Players point at your IP on **5999** (the SoD-lineage
stream RoF2 requires — see CODEBASE.md §5.1). Nothing depends on anyone else's infrastructure. To go public later: register with PEQ, then fill in
`loginserver1.account` / `.password` / `.host` / `.port` in `eqemu_config.json`.

**All player traffic is UDP.** EQEmu builds every client-facing listener on UDP, including
world's, which is hardcoded to 9000 and is *not* the `world.tcp.port` from the config.
Opening these as TCP lets a player authenticate and then hang at server select.

**The loginserver runs two streams.** 5998 carries Titanium opcodes, 5999 the SoD-lineage
set. RoF2 needs 5999; on 5998 the handshake reply arrives with the wrong `OP_ChatMessage`
opcode and the client hangs with no server-side error. Both are opened; `eqhost.txt` is
generated pointing at 5999.

**MariaDB never leaves the box.** Bound to 127.0.0.1, and 3306 is never opened. Telnet
(TCP 9000) is bound to loopback too — it is an unauthenticated admin channel.

**Services are manual-start.** Windows service dependencies cannot express "wait until
world is actually serving before starting zones". A boot task runs `start-server.ps1`
instead, which runs `shared_memory` first and sequences the rest with real delays.

---

## Your VPS provider's firewall is separate

The Firewall stage opens Windows Firewall. Most VPS providers run **their own** network
firewall in front of the machine, and several block inbound UDP by default — so the server
looks perfectly healthy (services Running, ports bound, Windows rules enabled) while no
client can reach it.

Open these **inbound UDP** ports in the provider's control panel:

| Port | What breaks without it |
| --- | --- |
| **5999** | **Login for RoF2.** The client hangs at "Logging in to the server" forever, with no server-side error at all. See CODEBASE.md §5.1 |
| **5998** | Login for Titanium-lineage clients. Harmless to open; not what RoF2 uses |
| **9000** | World — you authenticate, then hang at server select |
| **7000–7400** | Zones — you get in-game and then cannot enter any zone |
| **7778** | Chat, mail, guild chat |

All UDP. Every client-facing EQEmu listener is UDP, so TCP rules on these numbers do
nothing. Do **not** expose 3306, TCP 9000 (telnet), 9001, or 9080/9081.

To test from outside:

```powershell
Test-NetConnection <server-ip> -Port 9000      # TCP; failure suggests upstream filtering
```

## Known caveats

- **Both stages have now been run end to end on a real Windows Server 2025 box**, with a
  RoF2 client connecting successfully. Full transcripts land in `C:\NMS\logs\`.
- **The client needs `eqhost.txt` pointing at port 5999**, not 5998. The Export stage
  generates one with the right address; CODEBASE.md §5.1 explains why the port matters.
- **Perl 5.40+ will not work**, for two independent reasons — see the Perl note at the top.
  Uninstall it via Programs and Features and let stage 1 install the pinned 5.32.1.1.
- **The first CMake configure needs internet.** The repo commits a *partial* vcpkg tree —
  `.gitignore` has a bare `bin/`, which excluded every runtime DLL — so the ~132 MB
  download is not optional despite appearances.
- **`db_version.custom_version` is not evidence.** The shipped dump arrives stamped at
  9325/25, so both manifests are no-ops on a clean import. Read the health-check output.
  See [CODEBASE.md §4.3](CODEBASE.md).
- **Waypoints may be silently dead.** The seed rows exist only as a commented-out block in
  `zone/nms_waypoints.h`. The Database stage warns if the table is empty.
- **The MariaDB root password passes on the msiexec command line** during install — the
  MSI offers no better channel. Rotate it afterwards if that matters.

---

## After the first successful run

1. Connect a client and log in once to create your account.
2. Grant yourself GM: `UPDATE account SET status = 250 WHERE name = '<your login>';`
3. Hand players the contents of `C:\NMS\client-files\` — its `README.txt` has their
   instructions. They need their own RoF2 client; it is not and cannot be included.
4. Back up `C:\NMS\credentials.txt` somewhere off the machine.
