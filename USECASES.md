# AeroSpace Use Cases — Personal Playbook

This document is tailored to a specific desk setup: one ultrawide monitor (laptop closed), a
split keyboard with dedicated hyper and meh one-shot keys, and a workflow centered on
workspace 1 (work) with Slack left, active work center, and floating tools right.

---

## Your Baseline Layout

```
┌─────────────┬──────────────────┬─────────────────────┐
│   LEFT 32%  │   CENTER 36%     │    RIGHT 32%        │
│             │                  │                     │
│   Slack     │  Browser / Dia   │  Ghostty  Granola   │
│   (tiled)   │  (tiled)         │  cmux     Notion    │
│             │                  │  Email    (all float)│
└─────────────┴──────────────────┴─────────────────────┘
                                           Workspace P (hidden)
                                           └─ Personal Dia
```

**Key facts that shape every use case:**
- Right zone is a floating pile — you control it manually with `meh-h/a/e`
- Floating window positions cannot be fully controlled by snapshots or presets
- Zoom auto-routes to center when opened (`[[on-window-detected]]`)
- Personal browser is permanently quarantined to workspace P

---

## Recommended Config Additions

Add these to your `aerospace.toml` before using the use cases below:

```toml
[zones]
widths = [0.32, 0.36, 0.32]
layouts = ["accordion", "accordion", "accordion"]
gap = 10
focus-mode-collapsed-width = 80   # px: see notification badges, can't read content

[[zone-presets]]
name = "focus"
widths = [0.10, 0.80, 0.10]
layouts = ["accordion", "accordion", "accordion"]

[[zone-presets]]
name = "meeting"
widths = [0.18, 0.64, 0.18]
layouts = ["accordion", "accordion", "accordion"]

[[zone-presets]]
name = "balanced"
widths = [0.32, 0.36, 0.32]
layouts = ["accordion", "accordion", "accordion"]

[mode.main.binding]
    # Add these alongside your existing bindings:
    hyper-f       = 'zone-focus-mode toggle'          # deep focus toggle
    alt-ctrl-tab  = 'focus-zone --scope mru'          # return to previous zone
    hyper-p       = 'zone-preset focus'               # expand center to 80%
    hyper-m       = 'zone-preset meeting'             # meeting proportions
    hyper-0       = 'zone-preset --reset'             # back to your defaults
```

---

## Use Case 1: Deep Focus / Flow State

**When:** You're coding or writing and Slack is pulling your eyes left.

**What happens:** Center zone expands to ~80% of screen. Left and right collapse to 80px
slivers — wide enough to show a red Slack notification badge, too narrow to read anything.

**How to enter:**
```
hyper-f   →  zone-focus-mode toggle
```

**How to exit:**
```
hyper-f   →  zone-focus-mode toggle   (same key, restores exact proportions)
```

**While in focus mode:**
- You can still switch zones with `alt-ctrl-h / alt-ctrl-a / alt-ctrl-e` — focus mode shifts
  to follow you automatically
- `hyper-f` always exits back to your original widths, not the config defaults

**Honest limitation:** Floating windows in the right zone physically stay where they are;
they don't "collapse." The right zone just becomes a narrow sliver of screen real estate
behind them.

---

## Use Case 2: Meeting Mode

**When:** A Zoom call is starting.

**What happens:** Zoom auto-routes to center when you open it (already configured). You
widen center to 64% so the video is larger, shrink flanks to give Slack chat and Granola
notes room without dominating.

**One-time setup:** Position Granola in the right region of your screen and position Slack
(already in left zone) wherever you like. These positions are remembered by macOS between
sessions.

**How to enter:**
```
hyper-m   →  zone-preset meeting
```

**During the meeting:**
- `alt-ctrl-h` → jump to Slack to read/type chat
- `alt-ctrl-tab` (focus-zone --scope mru) → return to Zoom
- `alt-ctrl-e` → jump to Granola notes

**How to exit:**
```
hyper-0   →  zone-preset --reset   (back to your 32/36/32 defaults)
```

**Honest limitation:** Zone presets resize zones but don't move windows. If you have other
tiled windows in center besides Zoom they'll stay there too. Works best when center has only
one window (Zoom).

---

## Use Case 3: Communications Check

**When:** You want to scan Slack without losing your coding mental context.

**The pattern:** Jump left, read, jump back. One key each direction.

```
alt-ctrl-h      →  focus Slack (left zone)
alt-ctrl-tab    →  focus-zone --scope mru → returns to wherever you came from
```

`--scope mru` returns you to the last zone you were in before you jumped to Slack, so it
works regardless of whether you were in center or right before the check.

**Note:** `mruZones` now updates on every focus change (mouse or keyboard), so even if you
clicked into Slack with the mouse, `alt-ctrl-tab` will still know to return you to center.

---

## Use Case 4: Distraction Reduction (no context switching)

**When:** You want to work without switching modes — just a lighter version of focus mode.

This is already mostly handled by your setup:
- Personal browser is on workspace P, unreachable unless you press `alt-p`
- Slack is in its own zone; you can ignore it without hiding it

If the visual presence of Slack is still distracting:
```
hyper-p   →  zone-preset focus    # collapse left/right to narrow slivers
```

This is lighter than `zone-focus-mode` because it resizes proportions permanently (until
you reset) rather than toggling — useful when you want the layout to stay compressed for
an extended session rather than toggling in and out.

---

## Use Case 5: Travel / Laptop Mode

**When:** No ultrawide. Zones automatically deactivate — you get standard accordion layout
on the single laptop screen.

**For work travel (you still need structure):**

Suggested workspace split when on the road:
- Workspace `1` — browser (active work, same as always)
- Workspace `2` — Slack (alt-2 to check, alt-1 to return)
- Workspace `3` — terminals

The accordion-cascade layout on the laptop screen handles multiple windows in one workspace
well — windows fan out with 24px offsets so you can see what's behind.

**For personal use:** Just workspace P + your browser. Everything else stays out of the way.

**No config needed** — zones deactivate automatically when the ultrawide isn't connected.

---

## Use Case 6: End of Day / Morning Reset

**When:** Windows have drifted. You want to start the next day with a clean slate.

**Save your good layout:**
When everything is positioned where you want it, save a snapshot:
```
aerospace workspace-snapshot save morning
```

**Restore in the morning:**
```
aerospace workspace-snapshot restore morning
```

This restores tiled windows (browser, Slack) to their saved zones by app bundle ID.
Floating windows (Granola, terminals) are moved back to their workspace but **not to a
specific screen position** — that's still a manual step with `meh-h/a/e`.

**Honest limitation:** Snapshot restore matches by bundle ID first-come-first-served. If
you have two Dia windows open (Work + Personal), it cannot guarantee which one lands in
which zone — the routing rules (`[[on-window-detected]]`) handle that instead. Close and
reopen Dia windows if they end up on the wrong workspace after a restore.

**Suggested binding:**
```toml
hyper-r = 'workspace-snapshot restore morning'
```

---

## Quick Reference Card

| Situation | Key | Command |
|-----------|-----|---------|
| Enter deep focus | `hyper-f` | `zone-focus-mode toggle` |
| Exit deep focus | `hyper-f` | `zone-focus-mode toggle` |
| Meeting layout | `hyper-m` | `zone-preset meeting` |
| Focused layout | `hyper-p` | `zone-preset focus` |
| Reset layout | `hyper-0` | `zone-preset --reset` |
| Jump to Slack | `alt-ctrl-h` | `focus-zone left` |
| Return from Slack | `alt-ctrl-tab` | `focus-zone --scope mru` |
| Restore morning layout | `hyper-r` | `workspace-snapshot restore morning` |
| Send window to scratchpad | `hyper-s` | `send-to-scratchpad` |
| Summon scratchpad | `meh-s` | `scratchpad` |
| Move tiled to zone | `hyper-h/a/e` | `move-node-to-zone left/center/right` |
| Move float to zone | `meh-h/a/e` | `move-floating-to-zone left/center/right` |

---

## What Doesn't Work (Yet)

- **Floating window positions in snapshots** — snapshot restore puts floating windows on
  the right workspace but not at a specific screen position. Use `meh-h/a/e` to park them.
- **Two identical app windows** — if you have two Dia windows, snapshot restore can't
  distinguish them. The `[[on-window-detected]]` rules (Work:/Personal: title matching) are
  more reliable for Dia routing.
- **Right zone layout** — your right zone is intentionally a freeform float pile. There's
  no "arrange the right zone" command; you park things there manually when you open them.
