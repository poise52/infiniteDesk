# Chrome window focus acceptance

This is an opt-in graphical acceptance test for the actual InfiniteDesk board.
It uses the installed Google Chrome and a new temporary profile. The fixture
pages are local files; they do not load external content. The launcher does not
use the user's Chrome profile, remote debugging, Accessibility grants, or input
injection. `--disable-background-networking` reduces Chrome background activity;
it is not a network isolation guarantee.

1. Build and open `target/InfiniteDesk.app` using the repository README. Allow
   the permissions normally required for screen capture and window focus. The
   ⌘Return operation requires macOS 15.2 or later and Accessibility access for
   InfiniteDesk.
2. Run `native/macos/Browser/Tests/Chrome/launch.sh --launch`. Record the printed
   disposable profile path and leave the launcher running in its terminal. Chrome
   output goes to `first.log` and `second.log` in that profile. A successful
   second request is not proof that a window opened. Two separate Chrome windows
   should appear with titles
   **InfiniteDesk Chrome A** and **InfiniteDesk Chrome B**. Confirm the pages show
   their corresponding large A/B identifiers and `TARGET-A` / `TARGET-B` values.
   Each target field requests initial focus via HTML `autofocus` on a fresh page
   load; focus may depend on Chrome and macOS. If they did not open as separate
   windows, stop; the test setup has failed.
3. In InfiniteDesk, use **Preview…** on separate board cards and select Chrome A
   and Chrome B respectively in the macOS picker. Confirm each live preview
   shows the matching page. If necessary, use `N` to add a card. Leave both
   windows open throughout the test.
4. Make Chrome B the foreground window by clicking it. Return to InfiniteDesk,
   select the card showing Chrome A, and press ⌘Return with the board focused.
   The original Chrome A window must come to the front. Click its **Target text**
   field, append `-from-board-A`, and confirm that the displayed target value is
   `TARGET-A-from-board-A`, the page shows **TARGET EDITED**, and the neutral
   decoy remains `DECOY-A`.
5. Make Chrome A foreground, return to the board, select the card showing Chrome
   B, and press ⌘Return. The original Chrome B window must come to the front.
   Click its **Target text** field, append `-from-board-B`, and confirm that the
   displayed target value is `TARGET-B-from-board-B` and the decoy remains
   `DECOY-B` and the page shows **TARGET EDITED**. Return to A and confirm its value remains `TARGET-A-from-board-A`.

A successful result requires the correct original window to be visibly brought
forward in both directions and the values to remain on their respective pages.
The visibility and focus readouts are diagnostics for the page only; neither is
proof that its native window is frontmost. A picker failure, permission failure,
ambiguous title, or an unsupported system is an inconclusive setup, not a pass.

### Replace a Chrome field from the board

Start with a fresh pair of fixture windows for this independent test. The
**TARGET EDITED** marker is sticky; typing into the original Chrome window
in the focus test would invalidate the initial **TARGET NOT EDITED** check.
Record the marker and target/decoy values in both cards before sending.

1. With **Chrome A** in front, click **Target text**. Return to InfiniteDesk,
   select the title bar of its card, and click **More… → Replace focused Chrome field…**. Check that the
   identified field is the target. Type `desk-A-проверка` into the board's
   replacement field and choose **Replace**.
2. Keep InfiniteDesk in front. In the live preview check both the editable
   field and the page's **Target value** readout. The field and readout must
   both equal `desk-A-проверка`, and the decoy must still be `DECOY-A`.
   Repeat from B using `desk-B-проверка`; verify both the decoy in B and the
   entire A result are unchanged.
3. As a negative control start a replacement for A, switch board selection
   to B, and return to A. The old form must be gone. Neither the selection
   change nor Escape may edit either page.

Typing directly into the original Chrome window in the focus test above
does not count as board input. An Accessibility readback alone also does not
prove Chrome delivered an input event to the page.

### Pick an unfocused field in a scaled preview

1. Reload both fixture pages. Arrange the two Chrome windows side by side so
   their text fields do not overlap in desktop coordinates. Confirm each page
   shows **Active field: target**, **TARGET NOT EDITED**, both DOM input counters
   at zero, and the original target and decoy values. If needed, click the
   **Target text** field on the original page once to establish initial focus.
   Leave the decoys untouched.
2. Return to InfiniteDesk and keep it frontmost for the rest of the test.
   Select card A by its title bar. At reduced board zoom, click **More… → Pick Chrome field…**
   and then click inside the **Neutral decoy** input in the live image.
   Confirm the replacement form names the decoy and both counters still read
   zero. Enter `picked-A-проверка` into the board form and click **Replace**.
3. From the preview, verify that the editable decoy and its page value both
   show `picked-A-проверка` and that its DOM input counter increased. The
   target still reads `TARGET-A`, its counter is zero, and **TARGET NOT
   EDITED** remains visible. Check B still shows both original values and
   zero events.
4. Select B by its title bar, enlarge the board zoom, and repeat on its
   unfocused decoy with `picked-B-проверка`. Verify its decoy counter
   increased, its target value and counter stayed unchanged, and A retained
   its result. Record the zooms and the before/after counters for both cards.
5. Arm **More… → Pick Chrome field…** and click the page heading. Verify no replacement form
   opens. Arm the picker again and press Escape. Pick another field, then
   switch cards before choosing **Replace**. Confirm the form disappears and
   the four values and counters stay unchanged.

Close both fixture windows after testing. Once the disposable-profile Chrome
process has exited, remove the exact temporary profile directory printed by the
launcher. Do not remove a profile while its Chrome process is running. `--check`
only verifies the executable and fixture files without opening a window.
