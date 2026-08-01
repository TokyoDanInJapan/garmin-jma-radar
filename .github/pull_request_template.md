<!--
Keep this short. The commit messages should carry the detail. This template is
for the context a reviewer cannot get from the diff.
-->

## What and why

<!-- What changes, and the constraint or bug that motivated the change. -->

## How it was verified

<!--
Say which of these you actually ran, and on what. CI covers the proxy, and it
compiles and unit-tests both widgets, but it cannot exercise a real device.

- [ ] `npm run lint && npm run typecheck && npm run coverage` (proxy)
- [ ] Widget unit tests (`monkeydo bin/test.prg <device> -t`)
- [ ] Ran in the simulator
- [ ] Ran on a real Edge device (say which device)
-->

## Notes for the reviewer

<!--
Anything worth flagging: a cross-project contract you touched (DEVICE_TILE_SIZE
lives in three files), a JMA endpoint assumption, a change to the deploy path, or
a CHANGELOG entry added under `## Unreleased`.
-->
