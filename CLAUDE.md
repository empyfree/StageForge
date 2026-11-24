# StageForge – notes for Claude

SketchUp Ruby extension (.rbz): (a) staging (decks, tiers, fascia, leg reports, make/model catalogue) and (b) event seating (banks of chairs, aisles, obstacles, round table plans). Current version: see `VERSION` in `stageforge.rb`.

## Layout
- `stageforge.rb` – extension registrar and VERSION. `stageforge/main.rb` – staging UI, boundary reading (faces, groups, lines-only loops).
- Pure-Ruby engines (no SketchUp API, unit-testable): `packer.rb`, `seating.rb`, `tiers.rb`, `planner.rb`, `obstacles.rb`, `tables.rb`.
- `seating_ui.rb` – SketchUp side of seating: banks, observers, live updates, dialog callbacks, geometry building. `html/seating.html` – the seating dialog.
- `tests/` – plain-Ruby tests with a stub SketchUp API (`tests/stub`). Run: `ruby -I tests/stub tests/smoke.rb` and `ruby tests/tt.rb`. Dialog JS: extract the `<script>` from the HTML and `node --check` it.
- `releases/` – each shipped `.rbz`. Build: `zip -r StageForge-<ver>.rbz stageforge.rb stageforge`.

## Rules the user has set
- Staging never mixes metric and imperial decks. The seating dialog has its own independent unit setting. Dialog lengths are inches internally; seating-dialog field values are in display units (mm or in).
- Aisles are floor-level markers shared by all banks. Other model objects are avoided within a height band (default 100–1100 mm). Areas can be faces or closed line loops with no face (never create a face).
- Each bank is independent (own area, front, chair, settings), stored on a tagged group (`StageForge` dictionary). Changes relay only affected banks.
- Tables: 5 ft / 5 ft 6 in / 6 ft round. Suggested centre spacing 3.0 / 3.25 / 3.5 m. Dining seats 6/8/10; cabaret (internal key `horseshoe`) seats 5/6/8 over a user-set arc (10-360, default 200) at the back, facing the front or each turning to face the stage centre; cabaret front-to-back spacing is 75%. Staggered "row to row" is centre-to-centre distance. Best fit also tries in-line and staggered and keeps the fullest. A fixed table count keeps the spacing if it fits, else shrinks it to 35%, and reports the centre-to-centre distance.
- Extension Manager auto-update was dropped (user: "just an idea").

## Working style
- The SketchUp-side code cannot be run outside SketchUp; the user tests it there and reports bugs. Be honest about what was and wasn't tested. Never ship without running the smoke tests, and read their output before packaging.
- Each release: bump VERSION, add a "What's new" section to README.md, update `releases/`, commit, push.
- Ideas not built: mixed table sizes, other table shapes (rectangular, banquet, cabaret variants), guest-count-to-tables (user declined for now).
