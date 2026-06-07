# MBLib — internal API change log

Tracks API additions, behavior changes, and breaking changes to MBLib, per version. **Distinct from `src/Modules/Changelog.lua`** — that file is the user-facing in-game release notes; this one is developer-facing only and is intentionally excluded from the release zip (only `LICENSE` and `README.md` ship alongside `src/`, per `build.ps1`).

## How to use this file

- **When bumping a consumer addon to a new MBLib version:** scan the entries between the consumer's previously-vendored MBLib version and the new one. Anything in **Breaking** needs a fix in the consumer before running `mblib-update.ps1`; **Removed** / **Deprecated** entries flag call sites that need updating.
- **When making any change to MBLib that affects the surface a consumer sees** (any function on `addon.MBLib.*`, any SavedVariables shape, any expected load order, any string key in `MBLib.L`): add an entry under the current unreleased section.

## Sections per version

- **Added** — new public API (modules, methods, fields, settings).
- **Changed** — behavior change that consumers may observe but won't break them.
- **Breaking** — a consumer must change its code or data to keep working. Always include a one-line migration note.
- **Removed** — public API deleted. Include the replacement (if any).
- **Deprecated** — still works, slated for removal. Include the timeline + replacement.

Reference file paths so consumer maintainers can grep for usages: prefer ``Modules/X.lua`` (relative to MBLib's `src/`) over module names alone.

---

## 1.0.5 (unreleased)

### Breaking

- **Source tree restructured.** ``src/Modules/`` is gone. Module files now live under either ``src/CoreModules/`` (always loaded by ``MBLib.xml``) or ``src/OptModules/<Feature>/`` (each opt-in feature gets its own subdirectory + loader XML).
    - **CoreModules** (always loaded): ``Strings``, ``Constants``, ``Utils``, ``Settings``, ``Commands``, ``Changelog``, ``Notifications``, ``CopyPopup``, ``OptionsScreen``.
    - **OptModules** (opt-in via consumer's loader XML):
        - ``OptModules/Movers/`` — ``MoverController``, ``Mover``, ``Movers``, ``MoversPanel``. Loader: ``OptModules/Movers/Movers.xml``.
        - ``OptModules/MacroButton/`` — the draggable action-bar macro button. Loader: ``OptModules/MacroButton/MacroButton.xml``.
        - ``OptModules/Fonts/`` — ``Fonts`` + bundled ``Expressway.ttf`` (LibSharedMedia integration). Loader: ``OptModules/Fonts/Fonts.xml``.
        - ``OptModules/Icons/`` — ``IconFrame``, ``IconCatalog`` (~1.4 MB), ``IconPicker``. Loader: ``OptModules/Icons/Icons.xml``.
    - **Migration:** consumer addons that use any of these features must reference the corresponding opt loader XML alongside ``MBLib.xml``:
        ```xml
        <Include file="MBLib\MBLib.xml"/>
        <Include file="MBLib\OptModules\Movers\Movers.xml"/>
        <Include file="MBLib\OptModules\MacroButton\MacroButton.xml"/>
        <Include file="MBLib\OptModules\Fonts\Fonts.xml"/>
        <Include file="MBLib\OptModules\Icons\Icons.xml"/>
        ```
    - The root-level ``MBLib_Icons.xml`` from earlier in this release cycle is removed; reference ``OptModules\Icons\Icons.xml`` directly.

- **``MBLib.IconPicker:SetDebugDumpCallback`` removed.** The icon-picker dump (used for offline catalog pruning) now lives entirely inside MBLib — consumers don't register a callback. Instead, the consumer's debug toggle just calls ``MBLib:SetDebugEnabled(on)`` (below) and the picker handles dump writing + auto-refresh + completion popup itself. Dump SV path moved from ``<AddonData>.DebugIconCatalog`` to ``<AddonData>._MBLib.iconDump`` (the ``_MBLib`` namespace inside the consumer's SavedVariables).

### Added

- **``MBLib:IsDebugEnabled()`` / ``MBLib:SetDebugEnabled(on)``** (``Init.lua``) — generic debug-mode toggle. Opt-modules that surface developer-facing behavior (currently the icon-picker dump pipeline) gate on this. Consumer addons mirror their own debug toggle into MBLib via ``SetDebugEnabled``; the in-memory ``_debugEnabled`` flag isn't persisted, so the consumer is responsible for restoring it on each addon load.

- **``MBLib.IconPicker:RebuildAndDump()``** (``OptModules/Icons/IconPicker.lua``) — invalidates the cached macro-icon catalog and rebuilds it, firing the internal debug-mode dump + auto-refresh popup. Invoked automatically by the picker's ``PLAYER_LOGIN`` handler when the stored dump's WoW version differs from the current client; consumers don't typically need to invoke this directly.

- **``MBLib.Fonts:RefreshOptionsForDef(def)``** (``OptModules/Fonts/Fonts.lua``) — repopulates ``def.Options`` for ``Display_FontType``-keyed dropdowns. Called by ``OptionsScreen``'s dropdown ``GetOptions`` each time the dropdown opens, so LSM fonts registered after MBLib's initial scan (by other addons) surface without a ``/reload``.

### Changed

- **``MBLib.Fonts:GetAvailableFonts()`` always rebuilds the list.** Previously cached behind an early ``if self._fontList then return ...`` — that froze the result to whatever LSM had registered at first call (typically only the WoW defaults + MBLib's bundled Expressway). Late-registered LSM fonts (from other addons) now surface in consumer dropdowns automatically.

- ``MBLib.L`` (``Modules/Strings.lua``) — flat table of every user-facing literal in MBLib. New convention: any new UI text in MBLib must be added here and referenced as ``MBLib.L.<KEY>`` rather than hardcoded in the consuming module. Same shape as a consumer addon's ``addon.L``. Loaded as the first module in ``MBLib.xml`` (right after ``Init.lua``) so every other module can read it.

- ``MBLib.Mover`` (``Modules/Mover.lua``) — generic single-frame mover. ``MBLib.Mover:Begin(frame, opts)`` arms a frame for mouse dragging and delegates the on-screen UI to the shared ``MBLib.MoverController``. ``opts`` supports a ``title`` string (rendered as the controller's description line — identifies which frame is being positioned), an optional size slider, a ``hideWhileMoving`` frame (typically the consumer's edit form), and ``onConfirm`` / ``onCancel`` callbacks. Snapshots and restores frame state on End — including ``IsShown()``, so a normally-hidden notification frame doesn't linger on screen after the user finishes positioning. Snapshots the start-of-session position too so the controller's Revert button can roll back without saving.

- ``MBLib.MoverController`` (``Modules/MoverController.lua``) — the single floating controller frame used by both ``MBLib.Mover`` (single-frame mode) and ``MBLib.Movers`` (bulk mode). Same frame, same code — both modes call ``MoverController:Show(opts)`` with different option shapes. Layout: title (always shown), [X] close in the top-right corner (calls ``onClose``), optional description line under the title (single-frame mode passes the frame's displayName; bulk mode leaves nil), optional size slider, centered Save / Revert button pair. Loaded as a sibling module before Mover and Movers in ``MBLib.xml``.

  Placement options (per Show call):
    - default: opens centered at top of screen; controller is itself draggable, position not persisted.
    - ``opts.stickToFrame = <Frame>``: controller anchors above or below the given frame (whichever side grows away from the nearest screen edge), and its own drag-to-move is disabled — it's pinned to the target. The consumer must call ``MoverController:Reanchor()`` after every drag stop on the target so the controller follows. ``MBLib.Mover`` (single-frame mode) sets this to the frame being positioned; ``MBLib.Movers`` (bulk mode) leaves it off because there's no single target.

- ``MBLib.MoverController:Reanchor()`` — re-runs placement against the current stick target. No-op when not currently sticking. Single-frame consumers call this from their ``OnDragStop`` handler so the controller follows the moved frame around the screen.

- ``MBLib.IconFrame`` (``Modules/IconFrame.lua``) — generic on-screen icon primitive for "flash an icon when a thing happens" notifications. ``IconFrame:Create(name)`` returns an instance; instance methods ``SetIcon(fileID)``, ``SetIconSize(size)``, ``Flash(seconds)``, ``CancelFlash()``, ``GetIconFrame()``. Owns its texture, size, and fade lifecycle; does NOT own its position (consumers apply via ``SetPoint`` or ``MBLib.Movers``). ``Flash`` shows the icon and schedules a fade after ``seconds`` of visible hold; a second ``Flash`` while one is in flight replaces the timer (latest hit wins). ``seconds <= 0`` shows indefinitely until ``CancelFlash``.

- ``MBLib.IconPicker`` (``Modules/IconPicker.lua``) — modal icon-picker dialog. ``IconPicker:Show({title?, current?, onSelect, onCancel?})`` opens a singleton popup with a virtualized 10×7 grid backed by ``MBLib.IconCatalog`` (see below). A unified Search field accepts either icon file-name substrings (e.g. ``druid``) or numeric FileDataIDs. ``onSelect(fileID)`` fires on Save. Reachable via Esc through ``UISpecialFrames``.

- ``MBLib.IconCatalog`` (``Modules/IconCatalog.lua``) — flat array of ``{ FileDataID, lowercased_icon_name }`` pairs for every ``Interface/Icons/*.blp`` entry in WoW. Auto-generated by ``tools/refresh-iconnames.ps1`` from the ``wowdev/wow-listfile`` community CSV. ~30K entries, ~1.5 MB Lua source. Regenerate per WoW patch with ``pwsh ./tools/refresh-iconnames.ps1`` and commit. Consumers don't read the table directly — it's the data source the IconPicker indexes for name search.

- ``MBLib.MoverController`` — ``Show(opts)`` now auto-hides Blizzard's Settings panel for the duration of the session and ``Hide()`` re-opens it. Consumers no longer need to call ``HideUIPanel(SettingsPanel)`` themselves; the controller handles it. Restore uses ``ShowUIPanel(SettingsPanel)`` (deferred by one frame via ``C_Timer.After(0, ...)``) which preserves the previously-active subcategory.

- ``MBLib.L.ICON_PICKER_TITLE`` / ``ICON_PICKER_ID_LABEL`` / ``ICON_PICKER_SELECTED_LABEL`` / ``ICON_PICKER_CANCEL_BTN`` — new keys for the picker UI.

- ``MBLib.Movers`` (``Modules/Movers.lua``) — registry of movable display frames, plus bulk-edit mode. ``Movers:Register(id, spec)`` registers a frame; spec accepts ``{frame, displayName, sizeSlider?, onSave, onCancel}``. ``Movers:ShowAll()`` puts every registered frame into mover mode at once with a single centered controller; ``HideAll(saved)`` ends the session (revert path restores each frame to its pre-session position via the snapshot taken in ``_armFrame``). ``RevertInPlace()`` restores positions without ending the session (used by the controller's Revert button). ``SetOnShowAll`` / ``SetOnHideAll`` for UI sync.

  Controller layout: title at top with addon name (e.g. "Meower Movers"), [X] close button top-right (reverts AND closes), Save and Revert buttons centered below (equal width, Revert reverts in place WITHOUT closing).

- ``MBLib.MoversPanel`` (``Modules/MoversPanel.lua``) — the **Settings → Movers** subcategory, auto-built for every consumer alongside Display Settings. Renders a Watchers-style list: "Show movers" toggle button, one row per registered mover with a per-row "Show" action that calls ``MBLib.Mover:Begin`` on that frame only.

### Changed

- ``Modules/OptionsScreen.lua`` — every user-facing literal migrated to ``MBLib.L``. Behavior unchanged. Consumers do not need to do anything.

- ``Modules/OptionsScreen.lua`` — ``IsAddonInstalled`` renamed to ``IsAddonLoaded`` internally and now uses ``C_AddOns.IsAddOnLoaded(name)`` rather than ``GetAddOnInfo(name)``. The "Other Addons by MorphieBlossom" list now only marks an addon as installed when it is *actually loaded* (a disabled or partially-uninstalled addon now reads as missing). Consumer-visible change but doesn't break anything.

- ``Init.lua`` — ``MBLib:GetSettingsSubcategoryName()`` now reads its default from ``MBLib.L.SETTINGS_SUBCATEGORY_DEFAULT``, falling back to the literal ``"Display Settings"`` if ``L`` somehow isn't loaded.

### Breaking

*(none — this release is additive)*

### Removed

*(none)*

### Deprecated

*(none)*

---

## 1.0.4 and earlier

No internal change log was kept before this file existed. Reconstructing prior history is intentionally out of scope — start the log here and grow it forward.
