# RCE Animation Migrator (Studio Plugin)

Recursively publishes `KeyframeSequence` instances from:

```
ReplicatedFirst["Animations To Reupload"]
```

and rewires the matching `Animation.AnimationId` at the same relative path under:

```
ReplicatedStorage.RCE_Engine.Animations
```

Folders are matched by name/path and created automatically in the destination if missing.
Existing `Animation` instances at the destination are overwritten in place (their `AnimationId`
is updated to point at the freshly-published asset).

This is a first-party dev tool: it only ever touches instances inside the place you have open
in Studio, using your own logged-in publish permissions. No cookies, no external HTTP calls.

---

## Important: this must be installed as a Local Plugin, not published to the Marketplace

**Do not use Studio's "Configure/Publish as Plugin" flow to publish this to the Roblox Plugin
Marketplace.** Marketplace-published plugins run in a more restricted Studio sandbox than local
plugins, and this tool relies on calling `AssetService:CreateAssetAsync` directly on your own
logged-in session to publish assets under your account/group. That will not work reliably (or at
all) from a plugin installed through the Marketplace — this is a **local-only** dev tool.

The supported install path is always one of:

- **Option A below** — copy `src/init.server.lua` straight into your local Plugins folder, or
- **Option B below** — build it with Rojo into an `.rbxm`, insert that `.rbxm` into a place, then
  right-click it in the Explorer and choose **Save as Local Plugin**.

Both end with the plugin registered locally in Studio's own Plugins Folder — never through the
Marketplace.

---

## Important: group-owned games must publish to the Group, not a personal account

**If the place you have open is owned by a Group, you must set "Upload to" to that Group.**
Publishing under "My Account (User)" is broken for group-owned games — every upload will fail.
This isn't optional or a preference, it's a hard requirement tied to how the place itself is owned.

The plugin now detects this automatically: on the **Setup** tab, if the current place is
group-owned and you're not already set to publish to that group, a warning banner appears with a
**"Use this Group"** button that switches "Upload to" and fills in the correct Group ID for you in
one click. The same check also runs live in the onboarding wizard's setup-check page. If you ever
see repeated `PermissionDenied`-style failures, this is the first thing to check.

---

## Quick start walkthrough

Full step-by-step from a fresh Studio install to your first migration run:

1. **Open your place** in Roblox Studio (the one containing both
   `ReplicatedFirst["Animations To Reupload"]` and `ReplicatedStorage.RCE_Engine.Animations`).
2. **Enable the beta feature:** File → Beta Features → search **"CreateAssetAsync"** → toggle it
   on. This is required — without it every publish attempt fails immediately (see Troubleshooting).
3. **Restart Studio completely.** The beta toggle doesn't take effect until Studio relaunches.
4. **Reopen the same place.**
5. **(Optional) Check "Allow HTTP Requests"** — Home tab → Game Settings → Security. This plugin's
   publish calls go through `AssetService:CreateAssetAsync`, a native engine API, not
   `HttpService`, so it isn't a confirmed requirement for this plugin specifically. It's harmless
   to have on regardless, and worth checking if you run other HTTP-based tools in the same place.
6. **Install the plugin:** copy `src/init.server.lua` into your local Plugins folder (Plugins tab
   → Plugins Folder — see "Option A" below for the exact steps), then restart Studio once more so
   it loads.
7. **Open the panel:** Plugins → Animation Migrator. A **welcome wizard** opens automatically the
   first time — it walks through what the plugin does, the beta-feature requirement, and a live
   check of whether your place is set up correctly, before landing you in the tool. Click the
   **"Guide"** button top-right anytime to bring it back.
8. In the **Setup** tab, pick where uploads go and (optionally) a theme. In the **Migrate** tab,
   click **Scan**, review the tree, then **Migrate** to start publishing and rewiring animations.

The rest of this README covers each of these steps (and the Rojo-based install path) in more
detail.

---

## Required one-time setup: enable the CreateAssetAsync beta feature

This plugin publishes animations using `AssetService:CreateAssetAsync`, Roblox's official
Luau API for programmatic asset creation (added November 2024). As of this writing it still
sits behind a Studio beta toggle:

1. In Studio: **File → Beta Features**.
2. Search for **"CreateAssetAsync"** and enable it.
3. Restart Studio.

If you skip this, every publish attempt fails with:
`CreateAssetAsync and CreateAssetVersionAsync are not available yet`

---

## Option A — Fastest: just copy the script (no build tools needed)

1. Open `src/init.server.lua` in this project.
2. Copy its entire contents.
3. In Roblox Studio: **Plugins tab → Plugins Folder** (opens your local plugins directory).
4. Create a new file there named `RCEAnimationMigrator.lua` and paste the code in.
5. Restart Studio (or use **Plugins → Manage Plugins → Reload**).
6. A new **"RCE Animation Migrator"** toolbar section with an **Animation Migrator** button
   appears — click it to open the panel.

## Option B — Build with Rojo (recommended if you'll keep editing this)

### Prerequisites
- Install Rojo: https://rojo.space/docs/v7/getting-started/installation/

### Build a standalone plugin file
```bash
rojo build default.project.json --output RCEAnimationMigrator.rbxm
```

You now have `RCEAnimationMigrator.rbxm` — an ordinary Roblox model file, **not yet a plugin**.
Turn it into a local plugin like this:

1. Open any place in Studio (a scratch/empty one is fine — you'll remove this model from it after).
2. Insert the model into the place: right-click **Workspace** (or anywhere) in the Explorer →
   **Insert from File...** → pick `RCEAnimationMigrator.rbxm`. (Drag-and-drop the file onto the
   Explorer/Viewport works too.)
3. Select the inserted `RCEAnimationMigrator` item in the Explorer, **right-click it**, and choose
   **Save as Local Plugin**.
4. Delete the item from the place now (it's no longer needed there — it's saved separately as a
   plugin) and restart Studio, or use **Plugins → Manage Plugins → Reload**.

Studio writes the plugin into your local Plugins folder for you as part of step 3 — you don't need
to touch that folder manually with this method. This is the officially-supported way to turn a
built `.rbxm` into a real local plugin (as opposed to just dropping the raw file in the Plugins
folder, which also works but skips Studio's own plugin registration).

### Or live-sync while developing
```bash
rojo serve default.project.json
```
Install the Rojo plugin from the toolbox and click **Connect** to stream changes live.

## Option C — Download a pre-built release

Every tagged release on this repo's [Releases page](../../releases) is built automatically by
GitHub Actions and contains exactly one file: `RCEAnimationMigrator.rbxm`. Download it and follow
steps 1–4 under **Option B → Build a standalone plugin file** above (insert it into a place, then
right-click → **Save as Local Plugin**) — no need to install Rojo yourself.

---

## Using the panel

The panel is split into three tabs — **Setup**, **Migrate**, and **Log** — plus a **Guide** button
(top-right) that reopens the welcome wizard anytime.

### Welcome wizard

Shown automatically the first time the plugin loads (and reachable later via **Guide**): a short
walkthrough of what the plugin does, the one-time beta-feature requirement with a manual checklist
you can tick off (including a note about group-owned games needing Group upload), a **live setup
check** (see below) that re-runs whenever you land on that page, and a final "you're ready" page.
Skip it anytime; your progress and confirmations are remembered.

### Setup tab

- **Upload to:** choose **My Account (User)** (default) or **Group**. Selecting Group reveals a
  Group ID field. Your choice and Group ID are remembered between sessions.
- **Group-ownership warning:** if the open place is owned by a Group and you're not already
  publishing to it, a banner appears here explaining why User upload won't work for this place,
  with a one-click **Use this Group** button that switches the upload target and Group ID for you.
- **Theme:** **Dark**, **Light**, or **Match Studio** (default) — Match Studio mirrors Studio's
  own theme colors live, including if you switch Studio's theme while the panel is open.
- **Setup check:** live, auto-detected status for the source folder, destination folder, the
  `CreateAssetAsync` engine API, and place ownership vs. your current upload target, plus a
  **Re-check** button and the same manual beta-feature checklist from the wizard. This refreshes
  automatically after every Scan and whenever you change the upload target or Group ID, too.

### Migrate tab

1. Open the place that contains both folders, then click **Scan** — walks the source folder and
   builds a searchable, collapsible tree of every `KeyframeSequence` found. Nothing is published
   at this step. Use the **search box** to filter the tree by path as you type.
2. Review the tree, then click **Migrate**. Every animation starts publishing in parallel
   immediately (see "Performance" below). While running:
   - Each item in the tree gets a live status icon (retrying / success / cancelled).
   - The **stats bar** shows live Success / Retrying now / Remaining / Total retries / Elapsed /
     ETA.
   - The **progress bar** tracks overall completion.
   - **Cancel** stops the run after in-flight uploads finish their current attempt (nothing
     already published is undone; anything still retrying or not yet started is left unfinished).
3. Failed uploads simply keep retrying on their own until they succeed — there's no need to
   intervene. If you press **Cancel** while something is still retrying, a **Resume Unfinished**
   button appears once the run ends — click it to pick up exactly where you left off, without
   rescanning or re-touching anything that already succeeded.

### Log tab

Every result is also logged here (and mirrored to the Output window). Use the **Log: All / Errors
only** toggle to filter down to just cancelled/interrupted items, and **Clear** to reset it. Any
line for an item that needed retries is clickable — expand it to see the full per-attempt error
history instead of just the final outcome.

Everything logged in the panel is also mirrored to the Output window (View → Output), so you have
a permanent transcript even if you close the panel mid-run.

---

## Performance: maximum parallelism + retry-until-success

There's no concurrency setting anymore — **every animation in the batch publishes in parallel,
all at once.** This is the fastest the tool can go: no ramping, no per-item spacing, no cap to
tune.

**Failed uploads simply keep retrying.** There's no retry limit — an item that fails just waits
(capped exponential backoff: 1s, 2s, 4s... up to 30s between attempts) and tries again,
indefinitely, until it succeeds. The log only records each item's *final* outcome (success or
cancelled) — not every individual failed attempt — so a stubborn item that needed several retries
doesn't flood the log; its success line simply notes how many attempts it took, e.g.
`OK Guns/Glock/Reload (... ) (4 attempts)`. Live retry activity is visible in the **stats bar**
instead: **"Retrying now"** shows how many items are currently past their first failed attempt,
and **"Total retries"** is a running count across the whole batch.

The only way an item ends up incomplete is if you press **Cancel** while it's still retrying —
in that case it's collected into **Resume Unfinished**, which appears after the run ends and lets
you pick up exactly where you left off without re-touching anything that already succeeded.

**Honest expectation-setting:** the real ceiling on throughput is Roblox's server-side rate limit
for asset creation, which isn't publicly documented and can vary — firing everything at once may
mean a large batch sees a wave of retries in the first few seconds before things settle, rather
than a smooth ramp. It should still finish faster overall for most batch sizes since there's no
artificial pacing at all, but for very large batches (hundreds of animations) that wave of retries
is expected behavior, not a bug — watch "Retrying now" in the stats bar rather than assuming
something's wrong.

---

## Troubleshooting

**`CreateAssetAsync and CreateAssetVersionAsync are not available yet`**
The beta feature isn't enabled (or Studio wasn't restarted after enabling it). See setup section
above.

**`PermissionDenied` (or similar `Enum.CreateAssetResult` failure)**
First check whether this place is owned by a Group and you're uploading under **My Account**
instead — that's broken and will always fail for a group-owned game. The Setup tab flags this
automatically with a "Use this Group" fix; see "Important: group-owned games..." near the top of
this README. If that's not it, the logged-in Studio account may not have permission to publish
assets for this place/group — confirm you can publish an animation manually via Studio's built-in
Animation Editor (Avatar tab → Animation Editor → open a KeyframeSequence → Publish) to rule out
account-level issues, and if using Group upload, confirm your account has asset-creation
permissions in that group.

**A burst of failures partway through a large batch**
Expected and handled automatically — those items just keep retrying with backoff (watch "Retrying
now" and "Total retries" in the stats bar) until they succeed. There's no need to intervene. If
items seem permanently stuck retrying for a very long time without ever succeeding, that's more
likely an account/place permission issue than a transient rate limit — switch the log to **Errors
only** and check the specific `Enum.CreateAssetResult` value being reported each attempt.

**I pressed Cancel and now some animations are missing / not migrated**
Expected — Cancel stops in-flight retries rather than letting them finish. Anything that hadn't
succeeded yet is collected into **Resume Unfinished**, which appears once the run ends. Click it
to pick up exactly where you left off.

**Some animations take a long time / seem stuck**
Normal for a large batch under load — they're retrying automatically with backoff, not stuck.
Check "Retrying now" and "Total retries" in the stats bar. Destination `Animation.AnimationId`
values are only ever updated on actual success, so nothing is left in a half-migrated state.

**The panel doesn't show up / toolbar button does nothing**
Check Output for `[RCE Migrator] Plugin loaded. Open the panel from the Plugins toolbar.` on
Studio startup. If you don't see it, the file likely isn't in the right Plugins folder location,
or Studio needs a restart after adding it.

**I published this to the Roblox Plugin Marketplace and publishing/uploads fail or the plugin
misbehaves**
Expected — see "Important: this must be installed as a Local Plugin" near the top of this README.
Marketplace-published plugins run with more restricted permissions than local ones and this tool
is not designed to run that way. Uninstall the marketplace version and install it locally instead
(Option A, Option B, or Option C).

---

## Automated builds & releases (GitHub Actions)

Three workflows live under `.github/workflows/`:

- **`build.yml`** — pure build check. Runs `rojo build` on every push (any branch) and PR to catch
  build breakage. Doesn't tag or release anything.
- **`release.yml`** — auto-versioning. **Every push to `main` automatically bumps the patch
  version by one** (e.g. `v1.0.1` → `v1.0.2`), builds `RCEAnimationMigrator.rbxm`, and publishes it
  as a GitHub Release with that `.rbxm` as the **only** attached file (see Option C above). You
  don't need to tag anything yourself for normal changes.
  - To push to `main` **without** cutting a release (e.g. a docs-only change), put
    `[skip release]` anywhere in the commit message.
  - To intentionally jump to a specific version instead of the automatic patch bump (a minor or
    major release), push a tag yourself and that exact version is used instead:
    ```bash
    git tag v1.1.0
    git push origin v1.1.0
    ```
- **`lint.yml`** — syntax/validity checks: `default.project.json` is valid JSON, every workflow
  file is valid YAML and passes [actionlint](https://github.com/rhysd/actionlint), and
  `src/init.server.lua` parses as valid Luau (via `luau-analyze`, checking for real syntax errors
  only — it doesn't know Roblox's own globals like `game`/`plugin`, so it ignores those).

---

## File structure

```
RCEAnimationMigrator/
├── .github/
│   └── workflows/
│       ├── build.yml       # CI build check (every push/PR)
│       ├── release.yml     # auto-versioning + tagged GitHub Releases
│       └── lint.yml        # JSON/YAML/Luau syntax checks
├── default.project.json   # Rojo project manifest
├── src/
│   └── init.server.lua    # entire plugin -- GUI + migration logic
└── README.md               # this file
```
