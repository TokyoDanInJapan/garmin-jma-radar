# Troubleshooting

## On the device

| Symptom | Cause and fix |
| --- | --- |
| `Set Proxy URL in settings` | The proxy URL is empty. Bake it into the build with `.env`. For a Store install, set it in Garmin Connect. |
| `Request failed (404)` | The proxy URL is wrong or is still the placeholder. Or no Worker is deployed at that host. |
| `Auth failed: check key` | The proxy key does not match the Worker's `PROXY_TOKEN`. The proxy key is the Worker token, not a Cloudflare API token. |
| `Acquiring GPS...` or `No GPS fix` | The widget has no GPS fix yet. Go outside, or set a position in the simulator. After the widget shows a failure, tap the screen to try again. |
| You cannot find the app on the device | Rain Radar JP is a *widget*, so it is not in the Connect IQ Apps menu. Open it from the widget loop. Swipe down, then swipe left or right. If the widget is not on the device at all, the build used the wrong product ID, or the `.prg` went into the wrong folder. |
| The `IQ!` logo shows on the device | The app stopped because of an error. Open `Garmin/Apps/LOGS/CIQ_LOG.YML` on the device to read the exception and the stack trace. |
| The proxy returns `401` | `PROXY_TOKEN` is not set on the Worker. Run `wrangler secret put PROXY_TOKEN`. |
| The app ignores changed settings | An old `.SET` settings file overrides the baked-in defaults. `build.sh` and `run-sim.sh` delete that file when they bake in `.env` values. On a real device, run `remove-device.sh`, then deploy again. |

## Simulator

| Symptom | Cause and fix |
| --- | --- |
| `Unable to connect` from `monkeydo` | The simulator's debug port (1234) is not ready yet. `run-sim.sh` checks the port for up to 90 s and tries to attach again. If the attach still fails, close the simulator window completely and run the script again. |
| The simulator does not start on Ubuntu 24.10 or newer | The simulator needs `webkit2gtk-4.0` and `libsoup2.4`, and Ubuntu removed them after 22.04. Use the distrobox container. See [connect-iq-sdk.md](connect-iq-sdk.md), Option C. |
| The simulator stops responding after a forced restart | A forced stop leaves the Connect IQ host in a state that blocks the debug port. Always close the simulator from its own window. |
| The GPS position does not change | The simulator reads the position from `simulator.ini` only when it starts from closed (a **cold** start). It also writes that file again when it closes. Close the simulator, then run `run-sim.sh --lat .. --lon ..`. To change the position while the simulator runs, use *Simulation → GPS/Position*. |

## Proxy

| Symptom | Cause and fix |
| --- | --- |
| `/health` reports `rateLimiter: false` | The `RATE_LIMITER` binding in `wrangler.toml` is not active. Check the `namespace_id`. If a namespace was first registered in the old `[[unsafe.bindings]]` form, it creates a limiter that never blocks a request. The deploy smoke test fails in this case. |
| Frames are blank | JMA returns 404 for tiles with no rain, which is normal. The Worker limits the zoom to 4–11, because JMA and GSI serve no tiles above z=11. The Worker returns `400` for coordinates outside the bounding box for Japan. |
| `502 upstream error` | The JMA endpoints are not documented, and their format may have changed. A request to JMA can also time out. Check the Worker logs. All the code that builds JMA URLs is in `proxy/src/jma.js`. |

## CI

| Symptom | Cause and fix |
| --- | --- |
| The `widgets` job fails while it downloads device profiles | The pinned device archive moved or is gone. Set the `CIQ_DEVICES_URL` repository variable to a mirror that you control. See `.github/scripts/install-connectiq.sh`. |
| A required check never reports and the PR is stuck | A change added a `paths:` filter to the `pull_request` trigger of a workflow. A check with a path filter does not report on a PR that changes none of those paths. A required check that does not report blocks that PR permanently. |
