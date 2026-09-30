# Real-REAPER spikes

The offline tests run against `tools/mock_reaper.lua`, which *assumes* the REAPER behaviours below. Each one should be
confirmed once in real REAPER (7.x). `spike_1_probe.lua` checks S1 to S4 automatically and prints a report to the
console; the rest need a few manual steps.

| # | Assumption | How to check | If it is wrong |
|---|---|---|---|
| S1 | An empty MIDI item's take `D_STARTOFFS` changes when its **left edge is trimmed**, and the right piece of a **split** gets `offs + distance` | probe | Fall back to keeping the offset in the `AT_w` tag (option A) |
| S2 | An unlooped empty MIDI item can be **extended** past its original end without looping or stopping | probe | Create aliases with a long source (e.g. 1 hour) and trim them |
| S3 | Item `P_EXT` is **not** copied by split or duplicate; the **take name is** copied by duplicate | probe | If P_EXT *is* copied: duplicate tags are already handled (the second item is treated as new), but copies of unique aliases could then use the tag instead of the take name |
| S4 | `SetItemStateChunk` keeps the GUIDs written in the chunk (so we must refresh them) | probe | Nothing breaks; `refresh_guids` just becomes unnecessary |
| S5 | Track and item `P_EXT` are part of the **undo snapshot** | Group items, move the alias, Ctrl+Z twice: the lane and its group data must disappear with the first undo that reaches "AliasTrack: group items" | Silent mode would lose the group data on undo; keep a copy in project ExtState as a fallback |
| S6 | A **razor delete** keeps the original item as the *left* piece | Razor-delete the middle of a tagged member, then check which piece still has `AT_m` (SWS "Show item notes / P_EXT" or the probe's `dump` function) | Cut detection must also look for the original on the right |
| S7 | Default **fades on split** ("overlap and crossfade items when splitting") only touch the cut edges | Split a member with the preference on and off | Nothing: fades on cut edges are ignored anyway |
| S8 | **Ripple editing** moves the alias and its members by the same amount in one change | Ripple-edit a region before a group | If REAPER moves them in two steps, the debounce should still see one change |
| S9 | Scanning cost: one sync on a project with 5 000 items stays under ~50 ms | Time `app:sync()` with `reaper.time_precise` | Scan only the folders that contain lanes |
| S10 | Beat timebase: an alias does not stretch differently from its audio members on tempo changes | Tempo change under a group, project timebase = beats | Force `C_BEATATTACHMODE` on alias items (open question 1) |
