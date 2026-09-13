# Next steps

## Decision (2026-08-27)

DictionaryHistory is a **reference tool**, not a study tool. It records what you met
and lets you find it again. Review and scheduling belong to Anki.

**The division of labour:** we are the *selector*, Anki is the *scheduler*.

That split is not just deference — it plays to a signal Anki cannot see. Anki schedules
on how you perform *inside Anki*. We know how often a word defeated you *in the wild*,
which is the better answer to the prior question: which words deserve a card at all.
We also hold the sentence you actually met it in. So we choose and enrich; Anki drills.

---

## Now

- [x] Repeat-count badge (`3×`), intensifying at 3+, grouped by lemma
- [x] Gloss on every row, part-of-speech stripped
- [x] Dates without the year, unless the year is not the current one
- [x] Honest watcher status + self-healing permission recovery
- [x] **Trails** — `via = "link"` runs render as one row
      (`serendipity → fortuitous → adventitious`). A gap over 10 minutes ends a trail;
      grouping is suppressed inside a search, where each match should stand alone.
- [x] **Privacy controls** — words withheld from the diagnostic log by default
      (`dh debug on` to opt in), plus `dh forget <word>` and `dh purge --yes`.

## Soon

- [x] ~~**Automatic context capture**~~ — **declined 2026-08-28.** The user prefers not
      to have the app reading surrounding text continuously, on both privacy and
      resource grounds. The manual route stays available and costs nothing: select the
      whole sentence instead of the word, and Layer 1 stores it as context today.
- [ ] **Stable signing identity** — replace the ad-hoc signature with a self-signed
      certificate so macOS stops revoking Accessibility on every rebuild. Needs the
      user's password once (to trust the certificate), which is why it has not been
      done yet. Until then: **grant Accessibility only after the final install of a
      session**, because every `./install.sh` silently revokes it.
- [ ] **Mac Mini migration** — run `./probe-target.sh` on arm64 / macOS 26 first.
      `dh dump-ax` if the watcher's selectors need correcting for that release.

## Later

- [ ] **Anki-shaped export** — CSV with the fields a card actually wants:
      front = word, back = gloss, example = captured sentence, tags = source app + date.
      Cheap, and removes most of the reason to want a plugin.
- [ ] **Anki add-on** — a proper plugin that pulls straight from `history.db`:
      suggests cards for words above a repeat threshold, skips words already in the
      deck, and keeps the example sentence attached. Only worth building after the
      export has been used in anger and the field mapping has settled.

## Known limits

- The system ⌃⌘D popover and three-finger-tap remain uncapturable: they run in a
  sandboxed system process (`LookupViewService`) with no available hook.
- Layer 2's accessibility selectors are verified on macOS 12 and macOS 26.6
  (search field at depth 4, web area at depth 5).

## Decision (2026-09-13) — no shortcut

The user opens Dictionary.app from the Dock with the mouse. No keyboard shortcut:
the Service keeps its right-click entry but has no `NSKeyEquivalent`, and
**Watch Dictionary.app** is on by default, so Accessibility is the one setup step.
(⌥⌘D was unusable anyway: macOS binds it to "Turn Dock hiding on/off".)
