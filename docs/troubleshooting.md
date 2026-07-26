# Troubleshooting

## On the device / in the widget

| Symptom | Cause / fix |
| --- | --- |
| `Set Proxy URL in settings` | Proxy URL is empty - bake it via `.env`, or (Store installs) set it in Garmin Connect. |
| `Request failed (404)` | Proxy URL is wrong / still the placeholder, or no Worker is deployed at that host. |
| `Auth failed - check key` | Proxy key doesn't match the Worker's `PROXY_TOKEN` (and isn't a Cloudflare API token). |
| `Acquiring GPS…` / `No GPS fix` | No fix yet - go outside (or set a sim position); tap Retry once it fails. |
| Can't find the app on the device | It's a *widget* - open it from the widget loop (swipe down, then left/right), not the Connect IQ Apps menu. If absent entirely, it was built for the wrong product id or copied to the wrong folder. |
| `IQ!` logo on the device | The app errored/crashed - read `Garmin/Apps/LOGS/CIQ_LOG.YML` on the device for the exception + stack trace. |
| Proxy returns `401` | `PROXY_TOKEN` not set on the Worker - `wrangler secret put PROXY_TOKEN`. |
| Settings changed but the app ignores them | A stale `.SET` file is shadowing the baked defaults. `build.sh`/`run-sim.sh` clear it when `.env` values are baked in; on a real device, `remove-device.sh` then redeploy. |

## Simulator

| Symptom | Cause / fix |
| --- | --- |
| `Unable to connect` from `monkeydo` | The sim's debug port (1234) isn't up yet. `run-sim.sh` polls for up to 90s and retries the attach; if it still fails, close the simulator window completely and re-run. |
| Simulator won't start on Ubuntu 24.10+ | Missing `webkit2gtk-4.0` / `libsoup2.4`, dropped after 22.04. Use the distrobox container - see [connect-iq-sdk.md](connect-iq-sdk.md), Option C. |
| A forced restart wedges the sim | A hard kill leaves the Connect IQ host in an unclean-shutdown state that blocks the debug port. Close it from its own window instead. |
| GPS position won't change | The sim only reads position from `simulator.ini` on a **cold** start, and rewrites it on exit. Close the sim, then `run-sim.sh --lat .. --lon ..`; or set it live via *Simulation > GPS/Position*. |

## Proxy

| Symptom | Cause / fix |
| --- | --- |
| `/health` reports `rateLimiter: false` | The `RATE_LIMITER` binding in `wrangler.toml` didn't materialise. Check the `namespace_id` -- one first registered under the old `[[unsafe.bindings]]` form provisions a no-op limiter that never enforces. The deploy smoke test fails on this. |
| Frames render blank | JMA 404s are normal for empty tiles, but a whole-frame blank usually means the zoom is past `z=11`, or the coordinates are outside the Japan bounding box (the Worker 400s those). |
| `502 upstream error` | JMA's undocumented endpoints changed shape, or an origin fetch timed out. Check the Worker logs; all JMA URL construction is in `proxy/src/jma.js`. |

## CI

| Symptom | Cause / fix |
| --- | --- |
| `widgets` job fails fetching device profiles | The pinned device archive moved or disappeared. Set the `CIQ_DEVICES_URL` repo variable to a mirror you control; see `.github/scripts/install-connectiq.sh`. |
| A required check never reports and the PR is stuck | Something re-added a `paths:` filter to a workflow's `pull_request` trigger. A path-filtered check does not report on a non-matching PR, so a required check blocks it forever. |
