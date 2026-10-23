# Zag Store performance diagnostics

This is an opt-in, on-device instrumentation feature. It is **off by default** and does not send data to a server.

## Capture a baseline

1. Open **Settings → Diagnostics → Performance** and enable **Measure Performance**.
2. Fully quit Zag Store and launch it again to capture the two startup milestones.
3. Open an app page from **Sources**, then from **Games** if applicable. Visit the same app twice to compare cold and warm loading.
4. Scroll horizontally through the Screenshots gallery and open a screenshot. Swipe to an adjacent screenshot and back.
5. Return to **Settings → Diagnostics → Performance** to review median and p95 values. Use **Copy Performance Report** to share the measurement text when needed.

## Measurement definitions

| Measurement | Start | End |
| --- | --- | --- |
| Launch → Interactive | App delegate's launch setup begins | Splash overlay has finished |
| Launch → Sources | App delegate's launch setup begins | Initial repository refresh task returns |
| Promotional Artwork | Promotional-banner resolver starts | A verified image is selected, or resolution finishes without one |
| Featured Artwork | Featured screenshot resolver starts | Verified image layout is selected, or resolution finishes without one |
| Apple Catalogue | Catalogue lookup starts | Screenshot URLs are returned, or lookup finishes without them |
| First 3 Screenshots | Gallery loader starts | First batch of up to three thumbnails completes |
| Screenshot Gallery | Gallery loader starts | All scheduled thumbnail batches complete |
| Full-Resolution Preview | Full-screen screenshot loading begins | The selected screenshot is ready at full resolution (neighbors prefetch afterward) |
| Screenshot Scrolling | A horizontal scroll begins | Scrolling and deceleration finish |

Screenshot scrolling also records **frame gaps over 50 ms** using a display-link callback. This is a practical frame-pacing diagnostic, *not* an official GPU dropped-frame or average FPS metric.

## Notes and limits

- Recording is local. Samples contain timing category, duration, completion result, timestamp, and scroll-gap count. They do **not** contain app names, repository URLs, signing details, bundle identifiers, or device identifiers.
- Only the latest **120 samples** are kept. Metrics are persisted with UserDefaults and can be cleared from the diagnostics page.
- The collection switch applies immediately to new measurements. Cold-start measurements require restarting the app after enabling the switch.
- First-load results depend on connectivity, existing caches, and repository response times. Compare several runs; use medians rather than a single result.
- The launch-to-interactive timing includes the intentional splash animation. The repositories milestone includes the app's initial request work and may be delayed by network access.
- Instrumentation may slightly affect the measured app. For rigorous analysis, use Instruments and Xcode's signpost/frame tools on a developer build.
