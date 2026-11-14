# Native window placement and input

From the repository root, run `native/macos/Browser/Tests/Focus/Fixture/launch.sh --launch`.
This builds and opens **InfiniteDesk Input Fixture**, a separate AppKit application.
`--check` builds and verifies its ad-hoc signature without opening the windows.
The fixture uses no Accessibility or Screen Recording APIs. Grant Accessibility to
InfiniteDesk to let it position the windows.

1. Observe the original positions of **InfiniteDesk Focus Fixture A** and **B**.
   B starts in front. Both windows show an editable field, a click counter and 100
   numbered rows bearing their window letter.
2. In InfiniteDesk, use **Window…** on a visible card, choose **InfiniteDesk Input
   Fixture**, then window **A**. Check that A's title bar and native controls appear
   over the chosen card and B stays in place.
3. Click A's field, press ⌘A and type `native A проверка`. Click its button once.
   Scroll until row 25 is visible. Verify the exact text, **Clicks: 1** and row
   label in A. In B verify **Editable B**, **Clicks: 0** and the first row.
4. Return to the board with ⌘Tab, move the card, and resume the selected window
   with ⌘Return. Verify A appears over the card's new location and retains its
   text and counter. Return to the board and click **Restore**. Check A's original
   desktop position and size against step 1.

Quit the fixture with ⌘Q or close both windows.
