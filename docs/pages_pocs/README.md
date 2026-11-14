# Page mockups (PoC)

Clickable UI mockups used to agree each page before building it. Sample data is synthetic and hard-coded.

| Page | File | Live mockup |
|---|---|---|
| Availability view | `availability.html` (offline, open in any browser); `availability.dc.html` (canvas source) | https://claude.ai/artifact/6tSsQJge7fCAmiLY9VQDuX |

## Notes

- `.html` files are self-contained: no internet or install needed, just open them in a browser. The Settings button replaces the canvas's tweak panel.
- `.dc.html` files are the source from the Claude design canvas and only run there (they need its `support.js`).
- The mockups are not the app. The real pages should be thin: reads from database views/functions, writes through database functions (see `docs/decisions.md`, D2–D4).

## Availability view: agreed behaviour

- Left: collapsible tree, site > building > block > floor > room > bed; beds are the rows.
- Body: one column per night; bars for allocations (coloured by course allocated vs scheduled: green at or above the green threshold, orange between thresholds, red below the red threshold), external bookings, and outages (hatched).
- Collapsed rows: per-week chips counting beds in each state on the week's limiting night (fewest free beds).
- "Colour by" filter: course colours compare allocated against either `scheduled` or `loaded`.
- Warnings strip (always shown, whatever the filter): courses with loaded > scheduled, and bookings in out-of-action beds. Bars carry matching icons.
- Bottom axis: week commencing dates (DD/MM); window moves a week at a time.
- Allocating: click an empty week on a bed = one week block (Monday first night, Sunday departure); drag across weeks and down across beds to select a group. The popup shows the range, lets the user change to exact dates, and lists clashes.
- Clashes (double booking, outages) are allowed with a warning by default; a configuration flag can make them block (D11).
- Clicking any row, bar or week summary opens an edit popup (forms still to be designed).
