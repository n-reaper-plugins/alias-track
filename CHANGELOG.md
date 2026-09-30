# Changelog

## 0.1.0 – first version
* Group selected items inside one folder: ALIAS lane + one empty-MIDI alias item per instance.
* Window model: move / trim (non-destructive) / split / copy of aliases; members derived with short fades on cut edges.
* Cutting a member (split, razor) cuts the alias and the rest of the group; members are split natively and handed over,
  not recreated.
* Linked copies on the ALIAS lane, independent variants on the COPIES lane; Make unique / Link; variants named "Name #n".
* Member edits propagate to linked aliases; MIXED state with Apply / Revert for what cannot be applied automatically.
* Push selected edits (chunk: FX, envelopes, takes), Add / Remove selected, Flatten, Ungroup, Rename, Detach all.
* Fresh item / take / FX GUIDs for every materialised copy; MIDI pool kept on the linked lane (setting).
* Undo modes: "One step per edit" (silent syncs, default) and "Separate sync steps" (pauses after undoing a sync).
* Debounced live sync (0.3 s, waits for mouse release with js_ReaScriptAPI), Freeze.
* ReaImGui window in the 262° theme; macOS installer; offline tests: 261 checks.
