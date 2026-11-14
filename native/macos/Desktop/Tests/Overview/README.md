# Native overview checks

Run `sh native/macos/Desktop/Tests/Overview/run.sh` for deterministic geometry and selection tests. This executable uses Foundation and CoreGraphics geometry: it does not open a panel, request Accessibility or Screen Recording, capture images, or mutate native windows.

The AppKit controller is built by `scripts/build-macos-app.sh`. Its panel is temporary and nonactivating. It becomes key for Escape, arrows, Tab, Shift-Tab, Enter, F and +/- without changing the frontmost application. Closing it invokes one callback after the panel disappears. Mouse selection and accessibility activation return the original UUID. Only wheel and pinch events delivered inside the panel change overview scale; there is no global event monitor, capture stream or display timer.

Manual checks require the owner's desktop and were not performed by the headless tests:

- Open from the menu and the global shortcut; Escape immediately returns keyboard input to the prior native window. Repeat without clicking the overview first.
- Register two overlapping Chrome windows and a Finder window. Check icons, real titles, page geometry, frontmost hit selection, Tab access to both overlapping originals, arrows and Enter. Identical titles must still select the exact original.
- Place a window on a distant page. Fit with F, zoom with wheel and pinch around the pointer, choose it and type immediately after the manager reveals and focuses it at 1:1.
- Press Escape after changing overview zoom and selection; world frames and the product camera remain unchanged. After closing the panel, ordinary app scrolling reaches the original app.
- Use VoiceOver to find the named window buttons and activate one. Disabled unavailable and closed records must not activate another window.
- Leave overview idle and confirm there is no recurring repaint or screen capture. Click another application to dismiss; reopening must work.

The controller owns only transient presentation. The caller must suspend global workspace movement while it is visible, supply current snapshots via `update`, and implement native reveal/focus for the selected UUID. Supply `backToFront` from native stacking order if available; without it, the focused original is foremost and other records retain registration order. Optional `backToFront` on `update` preserves the existing order when omitted.
