# Troubleshooting

## On the device, in the widget

| Symptom | Cause and fix |
| --- | --- |
| `Set Proxy URL in settings` | The proxy URL is empty. Bake it in with `.env`, or, for Store installs, set it in Garmin Connect. |
| `Request failed (404)` | The proxy URL is wrong or still the placeholder, or no Worker is deployed at that host. |
| `Auth failed: check key` | The proxy key does not match the Worker's `PROXY_TOKEN`. Note that the key is not a Cloudflare API token. |
| `Acquiring GPS...` or `No GPS fix` | There is no fix yet. Go outside, or set a simulator position. Once the widget fails, tap Retry. |
| You cannot find the app on the device | Rain Radar JP is a *widget*. Open it from the widget loop: swipe down, then left or right. It is not in the Connect IQ Apps menu. If it is absent entirely, it was built for the wrong product id or copied to the wrong folder. |
| The `IQ!` logo shows on the device | The app failed with an error. Read `Garmin/Apps/LOGS/CIQ_LOG.YML` on the device for the exception and the stack trace. |
| The proxy returns `401` | `PROXY_TOKEN` is not set on the Worker. Run `wrangler secret put PROXY_TOKEN`. |
| Settings changed, but the app ignores them | A stale `.SET` file is shadowing the baked defaults. `build.sh` and `run-sim.sh` clear that file when `.env` values are baked in. On a real device, run `remove-device.sh`, then deploy again. |

## Simulator

| Symptom | Cause and fix |
| --- | --- |
| `Unable to connect` from `monkeydo` | The simulator's debug port (1234) is not up yet. `run-sim.sh` polls for up to 90 s and retries the attach. If it still fails, close the simulator window completely and run the script again. |
| The simulator will not start on Ubuntu 24.10 or newer | `webkit2gtk-4.0` and `libsoup2.4` are missing, because Ubuntu dropped them after 22.04. Use the distrobox container. See [connect-iq-sdk.md](connect-iq-sdk.md), Option C. |
| A forced restart wedges the simulator | A hard kill leaves the Connect IQ host in an unclean-shutdown state that blocks the debug port. Close the simulator from its own window instead. |
| The GPS position will not change | The simulator reads the position from `simulator.ini` only on a **cold** start, and rewrites the file on exit. Close the simulator, then run `run-sim.sh --lat .. --lon ..`. You can also set the position live through *Simulation > GPS/Position*. |

## Proxy

| Symptom | Cause and fix |
| --- | --- |
| `/health` reports `rateLimiter: false` | The `RATE_LIMITER` binding in `wrangler.toml` did not materialise. Check the `namespace_id`. A namespace first registered under the old `[[unsafe.bindings]]` form provisions a no-op limiter that never enforces. The deploy smoke test fails on this. |
| Frames render blank | JMA 404s are normal for empty tiles, but a whole blank frame usually means the zoom is past `z=11`, or the coordinates are outside the Japan bounding box. The Worker returns 400 for those coordinates. |
| `502 upstream error` | JMA's undocumented endpoints changed shape, or an origin fetch timed out. Check the Worker logs. All JMA URL construction is in `proxy/src/jma.js`. |

## CI

| Symptom | Cause and fix |
| --- | --- |
| The `widgets` job fails while fetching device profiles | The pinned device archive moved or disappeared. Set the `CIQ_DEVICES_URL` repo variable to a mirror you control. See `.github/scripts/install-connectiq.sh`. |
| A required check never reports and the PR is stuck | Something re-added a `paths:` filter to a workflow's `pull_request` trigger. A path-filtered check does not report on a non-matching PR, so a required check blocks that PR forever. |
