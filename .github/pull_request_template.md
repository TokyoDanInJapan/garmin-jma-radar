<!--
Keep this short. The commit messages should carry the detail; this is for the
context a reviewer can't get from the diff.
-->

## What and why

<!-- What changes, and the constraint or bug that motivated it. -->

## How it was verified

<!--
Which of these you actually ran, and on what. CI covers the proxy and compiles
plus unit-tests both widgets, but it cannot exercise a real device.

- [ ] `npm run lint && npm run typecheck && npm run coverage` (proxy)
- [ ] Widget unit tests (`monkeydo bin/test.prg <device> -t`)
- [ ] Ran in the simulator
- [ ] Ran on a real Edge device (say which)
-->

## Notes for the reviewer

<!--
Anything worth flagging: a cross-project contract touched (DEVICE_TILE_SIZE lives
in three files), a JMA endpoint assumption, a change to the deploy path, or a
CHANGELOG entry added under `## Unreleased`.
-->
