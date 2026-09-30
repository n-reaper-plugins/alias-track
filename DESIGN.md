# AliasTrack design (v0.1.0)

## The model in one paragraph

A **group** lives inside one folder. It owns a **definition** (def): the member items, stored in def-local time `0..len`,
like a small virtual source. Each **alias item** is a *window* `{pos, len, offs}` onto a def, exactly like a normal
item is a window onto its audio file. Members are **derived**: for every alias, each def member is clipped to the
window and placed at `pos + (rel - offs)`. So moving an alias moves its members, trimming hides or reveals them
(non-destructively), splitting makes two windows onto the same def, and copying makes another window.

```
def (0..2 s)      kick [0..1]      snare [1..2]      hh [0..2]
alias A  pos 10  offs 0   len 2   ->  kick 10..11, snare 11..12, hh 10..12
alias B  pos 20  offs 1   len 1   ->  snare 20..21, hh 20..21 (clipped left, short fade on the cut edge)
```

## Your decisions, and how they are implemented

| Question | Decision | Implementation |
|---|---|---|
| Where is the window offset kept? | **B**: the alias is an empty MIDI item | `CreateNewMIDIItemInProj`, `B_LOOPSRC = 0`; the take's `D_STARTOFFS` *is* `offs`. REAPER keeps it right through trims, splits and copies, so no tag is needed for it. |
| Are tags copied on split / duplicate? | **No** | Identity comes from tags on *our* items only. Anything untagged on a lane is new: a **split piece** if it has the same *anchor* (`pos - offs`) as a known alias that got shorter, otherwise a **copy**. Member pieces are matched the same way (same track, same source, same anchor). |
| GUIDs of materialised copies | **Fresh** | Members are created from the stored item chunk with new `IGUID`, take `GUID` and `FXID`. `POOLEDEVTS` (MIDI pool) is *kept* on the linked lane, so pooled MIDI members share note edits natively, and renewed on the COPIES lane. Setting: "Keep MIDI pooled". |
| Razor and other cuts | **They cut the alias too** | If a member is split at *t* (S key, split at cursor, razor delete ...), the alias is split at *t* in the same sync; every other member spanning *t* is then split natively (the original stays the left piece, so it keeps its per-item state). A razor through all member tracks removes that range from the alias; a razor on *some* tracks leaves the middle alias **MIXED** (Apply = remove that material from the group, Revert = restore it). |
| Undo | A sane default plus an option | See below. |
| Linked vs. real copies | Linked by default, two lanes | See "Lanes". |
| Colours | Your 262° theme | `ATUI.lua` uses the THEME table, `push_theme` and the balanced `PopStyleColor` verbatim; a test checks 17 pushed and 17 popped, open and collapsed. |

## What a sync does (every 0.3 s after the project stops changing, never while the mouse button is down*)

1. **Cuts**: a member was split -> split its alias at the same time(s), rescan.
2. **New alias items**: split pieces inherit the def; copies on the ALIAS lane use the group's def; copies on the COPIES
   lane fork from the def named in their take ("Beat #3"), or from the group's def.
3. **Lane changes**: a known alias moved to COPIES forks the def (make unique); moved to ALIAS uses the group's def again (link).
4. **Hand-over**: after a split, members that now lie in the new piece are *re-tagged*, not recreated; spanning ones are split natively.
5. **Member edits** (moved inside the window, trimmed, volume, mute, pitch, rate, fades on uncut edges, moved to
   another track inside the folder) go into the def, so every linked alias follows. Things we cannot apply safely make
   the alias **MIXED**: a member deleted, moved past the alias edges, moved out of the folder, or trimmed at an edge the
   alias itself cut.
6. **Materialise**: write, adopt (an untagged item that is exactly the wanted piece), create, or delete.
7. Tags and the group data (JSON in the ALIAS lane's `P_EXT`) are written only if they changed.

\* only when the js_ReaScriptAPI extension is installed; otherwise the debounce alone applies.

## Undo strategy

The problem: your edit is one undo point; if the sync that follows is a second undo point, Ctrl+Z undoes only the sync,
the next sync redoes it, and you are stuck.

* **"One step per edit" (default, `silent`)**: syncs create **no** undo points (the project is still marked modified).
  Ctrl+Z restores the state before *your* edit, which should include the group data and every tag, because they are item/track state
  (to be confirmed in real REAPER: spike S5), and the next sync derives the same result again. Undoing a member
  edit is just another edit: the old position is detected and propagated back. This is deterministic because every
  member is derived from alias + def.
* **"Separate sync steps" (`steps`)**: every sync that changes anything is its own undo point `AliasTrack: sync`. While
  that label is at the top of the redo stack (you just undid a sync), syncing **pauses**: press Ctrl+Z again to undo
  your own edit, or edit something to continue.
* **Commands** (Group, Make unique, Link, Apply, Revert, Flatten, Ungroup, Add, Remove, Push, Rename, Detach) always
  create one undo point each, in both modes.

## Lanes: linked and unique

```
Drums (folder)
  ALIAS · Beat     <- every alias here shows the group's def (linked)
  COPIES · Beat    <- every alias here has its own def (unique), created on first use
  Kick / Snare / HH
```

* Drag an alias between the lanes (or press **Make unique** / **Link**) to switch it.
* Copying an alias on the ALIAS lane makes a linked copy; on the COPIES lane an independent copy of *that* variant.
* Split pieces of a unique alias share its def (they are still one variant, just two windows).
* Linking again drops the variant's own edits (one Ctrl+Z brings them back).

## Where things are stored

| Tag | On | Content |
|---|---|---|
| `AT_lane` | lane track | `gid|linked` or `gid|unique` |
| `AT_group` | ALIAS lane | JSON: name, colour, main def, defs (members with chunk, geometry and properties), counters |
| `AT_i` / `AT_w` / `AT_h` | alias item | `gid|iid|def`, last window, members it has |
| `AT_m` / `AT_a` | member item | `gid|iid|mid`, the snapshot we last wrote (to tell your edits from our writes) |

Settings are global (`ExtState AliasTrack/cfg`). Nothing is kept in project ExtState, because that is not part of undo.

## Limits in v0.1.0

* Chunk-level edits of a member (FX, envelopes, take changes) are not detected automatically: use **Push selected edits**.
* Two linked aliases editing the *same* member in one sync: the first wins.
* Frozen mode shows the groups but not their MIXED state.
* Items on the folder track itself cannot be members.
* Stretch markers / take envelopes are carried in the chunk but not re-mapped when a window cuts a member.

## Open questions

1. **Timebase.** The alias is a MIDI item; in a project with beat timebase it stretches with tempo changes while audio
   members may not. Force the alias to time timebase (`C_BEATATTACHMODE = 0`), or follow the track/project setting?
2. **Deleting an alias.** Currently deletes its members (setting to release them instead). Right default?
3. **Razor on some tracks only.** Now: the alias is cut, the middle is MIXED. Alternative: apply the deletion to the
   group straight away (every linked alias loses that material). Which one?
4. **Moving a member past the alias edge.** Now MIXED; Apply extends the alias. Extend automatically instead?
5. **Separate actions** (Group selected, Make unique, Link, Apply, Flatten) as their own scripts for shortcuts and
   toolbars, talking to the running window through ExtState?
6. **Nested groups** (an alias lane inside a group's folder being a member of an outer group): refuse, or support later?
7. **Lane look**: small fixed height and no master send for lane tracks?
