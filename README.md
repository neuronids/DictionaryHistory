# DictionaryHistory

Apple's Dictionary keeps no history. This adds one, without changing how you look words up.

You keep using Apple's real Dictionary window. A small menu-bar agent sits in front of it,
records the word, then hands off. Nothing about the definition you see changes.

## How it captures

Two independent layers. The first needs no permissions; the second is opt-in.

### Layer 1 - Services (default, no permissions)

Via the macOS **Services** mechanism. The system hands the selected text to the app directly,
so there is **no Accessibility permission**, no keylogging, no UI scraping, and nothing to
break when Apple redesigns Dictionary.app.

Definitions come from `DCSCopyTextDefinition` — public SDK API, `API_AVAILABLE(macos(10.5))`,
unchanged since 2007.

### Layer 2 - Dictionary.app watcher (opt-in, needs Accessibility)

Catches what Layer 1 structurally cannot: words **typed** into Dictionary.app's own
search field, and cross-references **clicked** inside an entry.

This is the main route: **Watch Dictionary.app** is on by default and needs
Accessibility permission once.

Both cases load a new entry into Dictionary's web view, so `AXLoadComplete` on the
`AXWebArea` is the single signal covering both. The search field is watched only to
tell them apart — typing fires one event per keystroke, so the field is never the
source of truth. Every candidate headword must resolve via `DCSCopyTextDefinition`
before it is stored, which filters out UI chrome and half-typed prefixes.

The `via` column records which path caught each word:

| `via` | meaning |
|---|---|
| `service` | selected in another app, ⌥⌘D |
| `typed` | typed into Dictionary.app's search field |
| `link` | cross-reference clicked inside an entry |
| `cli` | added with `dh add` |

This layer reads Dictionary.app's window structure, which is undocumented and can change
between macOS releases. If it goes quiet, dump the live hierarchy and adjust the selectors
in `Sources/watcher.swift`:

```
dh dump-ax
```

## Install

```
./install.sh
```

Then grant Accessibility once:
**System Settings → Privacy & Security → Accessibility**, tick **DictionaryHistory**.
Every reinstall revokes it; the menu shows a warning when that happens.

There is deliberately no keyboard shortcut. (⌥⌘D, the obvious candidate, belongs to
macOS's own "Turn Dock hiding on/off" and never reaches a Service.)

## Daily use

Open Dictionary from the Dock and look words up as usual. Each entry you land on is
logged — typed searches and clicked cross-references alike.

The Service is still available without a shortcut: select a word, right-click →
**Services → Look Up & Log**.

Click the 􀉚 menu-bar icon for today's count, your last 10 words (click to re-open),
full history search, CSV export, and a pause switch.

## From the terminal

```
dh recent 20        # most recent lookups
dh search seren     # substring search
dh top 25           # most frequent words, grouped by lemma
dh add <word>       # log without opening the UI
dh path             # path to history.db
```

## Data

`~/Library/Application Support/DictionaryHistory/history.db` — plain SQLite, WAL mode.

```sql
CREATE TABLE lookups(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    word        TEXT NOT NULL,  -- what you asked for
    resolved    TEXT,           -- lemma Apple matched: "ran"->"run", "mice"->"mouse"
    ts          REAL NOT NULL,  -- unix seconds
    source_app  TEXT,           -- app you were reading in
    context     TEXT,           -- surrounding text, only if you selected more than one word
    via         TEXT            -- service | typed | link | cli
);
```

Local only, no network. Delete the file to erase everything; Pause Logging to stop temporarily.

## Privacy

Everything stays on this machine. The app makes no network requests of any kind, and
there is no telemetry, sync, or account.

What is stored, and nowhere else:

| File | Contents |
|---|---|
| `~/Library/Application Support/DictionaryHistory/history.db` | your lookups |
| `~/Library/Application Support/DictionaryHistory/watcher.log` | diagnostics — **words withheld by default** |

The diagnostic log records what the watcher did, not what you read: looked-up words are
replaced with a character count unless you opt in with `dh debug on`. Turn it back off
with `dh debug off`.

Automatic sentence capture was considered and **declined** — the app never reads text you
did not select. If you want the sentence recorded, select it yourself and it is stored as
context; otherwise nothing beyond the word leaves your screen.

You can delete at any time:

```
dh forget <word>     remove every record of one word
dh purge --yes       delete the entire history
```

`Pause Logging` in the menu stops recording without deleting anything.

## Known limits

- Apple's built-in ⌃⌘D popover and the three-finger-tap gesture stay unlogged. They are
  handled inside a sandboxed system process with no hook available. Use ⌥⌘D instead.
- Layer 1 is verified working. Layer 2 is **written but not verified against a live
  accessibility tree** — the development machine had no Accessibility grant, so its
  selectors are reasoned from Dictionary.app's structure, not observed. Confirm with
  `dh dump-ax` before relying on it.
- Built and compile-tested on macOS 12.7.6 / Intel. Verify on the target machine with
  `./probe-target.sh` before trusting it.
