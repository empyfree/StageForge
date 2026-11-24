# StageForge

A SketchUp extension for event layouts. Draw an area in your model, and StageForge fills it: with **stage decks** and steps, or with **seating**, either rows of chairs or round table plans. Everything is measured from your own geometry and updates as the model changes.

## What it does

### Staging
Draw a boundary (a face, a group, or a closed loop of lines) and pick a staging system. StageForge tiles it with real deck sizes from a make-and-model library.

- **Library of makes and models.** Choose from the built-in catalogue, or add your own decks in `user_catalog.json`. A stage never mixes metric and imperial decks.
- **Default deck and orientation.** The default deck's long edge runs along the side it divides into evenly, so a 9 m × 4 m stage of 2 × 1 m decks comes out as clean whole decks.
- **Awkward shapes.** Corner pieces, triangles and semicircles fill odd outlines, and the quote shows what is left uncovered and which sizes would tile fully.
- **Tiers and steps.** Multi-level stages follow the stage grid, with leftover length split evenly at both ends.
- **Fascia.** Hard or soft fascia round the edge.
- **Legs and reports.** Legs are placed under each deck, with a leg report for the whole stage.
- **Units.** Show lengths in mm or feet independently of the deck system.

### Seating
Pick the area, the front (a line or an object) and a chair, and StageForge lays out the seating.

- **Rows of chairs:** *Equal rows* (a straight grid), *Offset rows* (chairs sit in the gaps of the row before), or *Curved rows* around a focal point you pick, the centre of the front object, or a radius from the front.
- **Round tables:** 5 ft, 5 ft 6 in or 6 ft tables.
  - *Dining* has every chair facing the table, with 6, 8 or 10 seats suggested by size.
  - *Cabaret* has chairs over 200° at the back of the table, all facing the front, with 5, 6 or 8 seats suggested by size.
  - Tables can be laid out *In-line*, *Staggered* or *Best fit*. Best fit packs in as many tables as will fit.
  - Suggested centre-to-centre spacing is 3.00, 3.25 or 3.50 m. Seats and spacing can be overridden.
- **Spacing you control:** side-to-side and front-to-front pitch (570 mm and 1100 mm by default), clear space at the front, and a gap to the area edge.
- **Aisles:** mark any shapes as aisles, and chairs and tables keep out of them. They are shared by every bank.
- **Keeps clear of the model.** Chairs and tables avoid other objects in the model within a height band you set with a slider, and you can tell it to ignore anything that shouldn't block.
- **Banks.** Run any number of seating areas at once. Each bank has its own area, front, chair and settings, and you can copy settings from one to another.
- **Live updates.** Move an aisle, an object or the area, and only the affected banks re-lay themselves, in the same undo step.
- **Simple boxes or real chairs.** Use plain boxes while testing, swap to your chair component to finish, and export the counts to CSV.

### Status
The layout engines are tested outside SketchUp. The SketchUp-side parts (dialogs, observers, drawing the geometry) are tested in SketchUp by the user, so expect rough edges and report them.


## What's new in 0.10.1

- Horseshoe is now called **Cabaret**. Its chairs cover 200 degrees of the table, and its suggested row-to-row spacing is 75% of the centre-to-centre spacing.
- In **Staggered** layouts, "Row to row" is the centre-to-centre distance to the neighbouring tables in the next row.
- **Best fit** now also tries the in-line and staggered layouts and keeps whichever holds the most tables.

## What's new in 0.10.0 - table plans

The Seating dialog has a new **Layout type** switch: *Rows of chairs* or *Round tables*. Tables share everything else: banks, aisles, objects to avoid, automatic updates, the area and front.

- **Sizes:** 5 ft, 5 ft 6 in, 6 ft round tables.
- **Arrangements:** *Dining* (chairs evenly round the table, all facing the centre) and *Horseshoe* (chairs spread over the back half, all facing the front).
- **Suggested seats:** dining 6 / 8 / 10, horseshoe 5 / 6 / 8. **Suggested centre-to-centre spacing:** 3.00 m / 3.25 m / 3.50 m. Type over any value to override; changing size or arrangement returns to the suggestion.
- **Layouts:** *In-line* (rows square to the front), *Staggered* (alternate rows shifted half a table and closed up), *Best fit* (as many tables as will fit, no neat rows).
- Tables are drawn as cylinders (30 in / 760 mm high); chairs as boxes, or your chair component if you picked one (otherwise a 450 x 450 x 900 mm block).
- Result panel and CSV report tables, guests and per-row counts. A warning appears if the seat count is too many for the table or the spacing is tighter than the chairs need.

## What's new in 0.9.1

- **Areas from lines only, no face needed.** Select a closed set of lines (loose, or all the lines inside a group or component) and use them as the seating area or stage boundary. No face is created, so nothing is added to your model. Lines drawn inside another loop become cut-outs. The lines must be flat and form clean closed loops (curves are fine); otherwise you get a message saying what is wrong. The area follows the lines when you edit them, including live updates.
- **Height slider readout fixed.** It showed raw inches with no unit (e.g. "9 to 211"). It now reads, for example, "Avoids objects from 100 mm to 1.10 m above the floor" (feet and inches in imperial), and says to press Place seating when automatic updates are off.

## What's new in 0.9.0 - height range and live object tracking

- **Height range slider** (two handles, 0 to 6 m above the floor of the seating area): an object blocks chairs if any part of it lies inside the range. Default is 100 mm to 1100 mm, so rugs and ground are ignored, and so are trusses and banners that start above the top handle. Raise the top handle to avoid taller things; lower the bottom handle to include kerbs and cables. Setting is per bank and saved with it.
- **Objects are tracked live:** with "Update automatically" ticked, moving, resizing or editing an object that blocks (or starts to block) a bank re-lays just that bank, the same way aisles do. One model scan serves all banks.
- Changing the slider, gap or tick-box re-lays the bank being edited immediately when automatic updates are on.
- "Refresh all banks" remains for when automatic updates are off.

## What's new in 0.8.0 - chairs avoid objects in the model

- Seating now keeps clear of other objects automatically (tick-box "Keep chairs clear of other objects in the model", on by default, per bank). Anything that rises more than 100 mm above the seating area's floor, and starts below the top of a chair, blocks the chairs under its footprint: a stage, truss tower, pillar, table, planter and so on. Not blocking: things at floor level (ground, paths, rugs), things wholly overhead, hidden or invisible-tag objects, other banks' chairs, and your aisle markers. Floor-level aisle markers work as before.
- "Extra gap around objects" widens each blocking object's footprint.
- "Ignore selected objects" / "Stop ignoring selected" tag groups or components (ground, terrain, a venue shell) that should never block. Saved in the model.
- Objects are checked every time a bank is laid out (including when aisles change). If you move an object, press "Refresh all banks".
- If an object covers most of the area (typically a floor or ground group), the result says which one, so you can ignore it.

## What's new in 0.7.0 - seating banks and shared aisles

- **Banks:** you can have any number of seating banks (e.g. ten areas). Each bank keeps its own area, front, chair, layout type and pitches, stored on its own chairs group in the model. A bank list in the Seating dialog lets you switch, add ("New bank" copies the current settings) and delete. Clicking a bank's chairs in the model also selects it in the list.
- **Aisles are now shared, saved objects:** "Mark selection as aisles" tags faces/groups as aisles in the model (they survive save and reopen). Every bank reacts to every aisle wherever they overlap. "Unmark selection" and "Unmark all" remove them.
- **Only affected banks re-lay:** when an aisle is added, removed, moved or reshaped, only the banks it overlaps (before or after the change) are recalculated. A bank also re-lays when its own area is edited. Marking/unmarking aisles re-lays straight away; edits after that follow when automatic updates are on.
- The preview switch (boxes / chair component) applies to every bank.
- Banks and aisles made with 0.6.x: chairs groups are recognised as banks. Aisles from earlier versions were remembered only per session, so mark them again once.

## What's new in 0.6.4

- With automatic updates on, reshaping or resizing an aisle marker (or the seating area), including edits inside a group, re-lays the seating when the edit finishes. Uses a fingerprint of the aisle and area outlines checked after each edit, so it does not depend on per-object notifications.

## What's new in 0.6.3

- Marking more objects as aisles adds them to the existing aisles and re-lays the placed seating at once, so chairs are cleared from the new aisles (no need to press Place seating, and it works with automatic updates off). "Clear aisles" re-lays the seating the same way.
- A seating group can no longer be picked up as an aisle by accident.

## What's new in 0.6.2

- Seating no longer loses track of its group. Each seating group is tagged, and every tagged group in the set is replaced when the layout is rebuilt, so old and new chairs can no longer overlap (this happened after undo/redo, or when the group was edited).
- Click a seating group in the model and the dialog loads its settings (layout type, pitches, front, aisles, area, chair). Change from offset to equal rows and press Place seating.
- With "Update automatically" ticked, changing a setting in the dialog (layout type, pitches, facing, etc.) re-lays the seating straight away.
- Undo/redo are handled: aisle, area and group references are found again by persistent id and watching resumes. Undoing an aisle move re-lays the chairs to match.

## What's new in 0.6.1

- Deck orientation on a plain rectangular stage: the default deck's long edge now runs along whichever side it divides evenly into (the longer side if both do). A 9 m x 4 m stage of 2 x 1 m decks is built as 9 columns of 2 decks. Only used to choose between equally good layouts, so coverage never drops.

## What's new in 0.6.0

- Version number shown in both dialogs, window titles, error messages and Help > About.
- Fixed `4'` displaying as `3' 12"`; imperial lengths now show fractions to 1/16".
- Display units (mm / feet) are independent of the deck system, so you can work in mm with 8' x 4' decks. Quote line gives both, e.g. "28' x 12' (8.53 m x 3.66 m) of 8' x 4' decks".
- Tiered steps follow the stage grid; leftover length is reported and split evenly at both ends (fixes the 465 mm offset).
- Semicircle decks get a third leg under the middle of the arc.
- Library cards show full, non-duplicated names.
- Seating: the front row sits on the front edge of the area's bounding box (chair front edge on the line); spare space is lost at the back; rows are centred across the width.
- Seating: preview with simple proxy boxes and swap to the real chair; live re-layout when aisle/keep-clear markers or the area change.

Not verified inside SketchUp itself: observers/live updates, proxy geometry, dialogs and edge picking. Please report anything odd.

## Install
SketchUp > Extensions > Extension Manager > Install Extension... > choose `StageForge-0.5.0.rbz`, restart SketchUp.
Needs SketchUp 2017 or newer (HtmlDialog). Menu: Extensions > StageForge > Stage Builder...

## Use
1. Draw a closed shape flat on the ground (rectangle, lines, arcs, circle - holes/cut-outs are respected) so it becomes a face.
2. Select the face, open Stage Builder, click "Use selected face".
3. Choose Metric/Imperial, Make, Model, finished height (type `600`, `0.8 m`, `24`, `2' 6"`), fascia (None/Hard/Soft), block detail (Solid or Deck + legs).
4. Tick the blocks you own in the library.
5. Generate. One undo step removes the whole stage. The result panel lists coverage %, block counts, areas, and exports a CSV.

## How it packs
* Phase 1: rectangular decks are laid on a grid, trying several grid angles (aligned with the longest boundary edges, plus the other 3 start corners) and offsets; largest decks first.
* Phase 2: remaining gaps are filled with every ticked shape (triangles, quadrants, semicircles, corner/chamfer, custom convex polygons, extra rectangles), each anchored and edge-aligned to the boundary or to blocks already placed, largest first.
* The best layout (most area covered, then fewest blocks) wins. Blocks stay inside the boundary; anything unfillable is reported as "Uncovered".

## Adding your real makes and models
The shipped library ("Generic") uses typical sizes only, not manufacturer data. Click "Edit / add makes and models..." - this creates `~/StageForge/user_catalog.json` from a template. Same schema as `stageforge/catalog.json`.
Shapes: `rect` (w,h), `tri` (w,h; right angle at origin), `quad` (r), `semi` (r), `chamfer` (w,h,cut), `poly` (convex `points`). Dimensions are in the model's `dim_unit` (mm or in).
Per model: `deck_thickness`, `leg_size`, `hard_fascia_thickness`, `soft_pleat_pitch`, `heights`, `default_height`.

## Status
Written without access to SketchUp/Ruby in the build environment, so it has NOT been run yet. Expect to fix small things on first load (Ruby Console: Window > Ruby Console shows errors). Known limits:
* One flat face per run; a face inside a group needs that group opened for editing.
* No per-block quantity limits yet; blocks may not overhang the boundary.
* Fascia follows the outer outline only (not cut-outs).

## Seating Planner (new in 0.4.0)
Menu: Extensions > StageForge > Seating Planner...
1. Seating area: select a flat face, click "Use selected face".
2. Front: select a line/edge (a boundary edge works) or an object such as the stage, click "Use selection as front". For an object, the side facing the seating becomes the front.
3. Chair: select your chair component, click "Use selected component". Set which way it faces in its own axes (default +X). Chairs are placed as instances of YOUR component, positioned by the centre of its bounding box.
4. Arrangement: Equal rows, Offset rows (alternate rows shifted half a pitch so each chair sits in the gap of the row before), or Curved rows.
5. Pitch: side to side (default 570 mm) and front to front (default 1100 mm), both centre to centre. Optional clear space at the front and gap to the area edge.
Curved rows: every chair faces the focal point. Pick the focal point in the model, derive it from the front + a radius, or use the centre of the front object. Radius = focal point to the centre line of the first row; side pitch is measured along each arc. Optional stagger of alternate rows.
Chairs are only placed where their whole footprint box fits inside the area (holes respected). No aisles yet.

### Aisles (new in 0.4.0)
Draw any flat faces for aisles/gangways (they may run beyond the seating area, be any shape, or be several faces). Select them and click "Add selected faces as aisles". Any chair whose footprint box would overlap an aisle is left out. "Clear aisles" resets the list; aisle faces are re-read when you place seating, so editing them in the model is picked up. The seating-area face itself is ignored if it is in the selection.

## What's new in 0.4.0
* **Groups work as markers.** The stage boundary, the seating area and the aisles can each be a loose face OR a group/component containing a flat face (found at any depth). If a group holds several flat faces, the largest is the boundary; every flat face inside an aisle group is kept clear. Keep marker groups simple (just the outline face).
* **Fascia follows the decking.** Hard and soft fascia now trace the real outside edge of the placed decks (and any internal gaps), not the drawn outline. Edges that touch the tiered steps get no fascia.
* **Save library choices.** Tick/untick blocks and choose the default deck, then press "Save library choices"; that selection is what loads every time (per make/model). "Reset to catalog" restores the shipped defaults. Unsaved changes are flagged.
* **Default deck.** A round "default" button on each rectangular deck (metric default 2 x 1 m, imperial 8' x 4'; set `"default": true` on a block in the catalog to change what ships). It sets the step depth and the default overlap.
* **Tiered steps.** In "Tiered steps", click "Pick boundary edge..." (then click edges of the boundary, Esc to finish) or select edges and press "Use selected edge(s)". Steps are built OUTSIDE each marked edge: tiers one default-deck deep, each running under the next higher tier by the overlap (default half the deck width), with tops stepping down evenly from the stage height. Step rise defaults to 200 mm / 8" maximum; steps = ceil(height / rise) - 1 (a 600 mm stage gives two steps at 200 mm). Tier decks are filled from your ticked rectangular decks. Legs on a deck's outer edge are shortened to bear on the tier below; all other legs reach the floor. Stage decks next to the steps get the same bearing legs when "Deck + legs" is selected. Risers and exposed ends get the chosen fascia. With "Solid" block detail the stage blocks run to the floor and so intersect the tier decks beneath them - use "Deck + legs" for stepped edges.
* The packer now prefers layouts whose decks sit flush against stepped edges.

## What's new in 0.5.0
* **Steps inside the boundary.** In "Tiered steps" choose "Inside the boundary": the steps finish on the marked edge and the stage shrinks back to make room (the marked edge is moved inwards by steps x tier pitch, and the decks are packed into what is left). "Outside the boundary" works as before. Coverage % and the block list then refer to the reduced stage; step decks are listed separately as "(steps)". If steps would use up the whole stage you get an error instead of a broken layout. Inside steps clip the boundary with straight cuts, so keep stepped edges on simple (ideally convex) parts of the outline.
* **Number of steps from the height.** The dialog aims for a rise of 200 mm (8 in) per step and suggests a count: 600 mm -> 2, 900 mm -> 3 (225 mm rise), 1200 mm -> 5 (200 mm rise). Change "Aim for a rise of" to alter the target, or type a number in "Number of steps" to override it. The rise is then recalculated as height / (steps + 1), and the readout shows step tops, rise and the floor space the steps use. The override clears when you change the height.
* **Leg report.** The result panel and CSV list every leg by length and type (ground-reaching, or bearing on the deck below), with a total. Legs follow the modelled legs: 4 per rectangle, 3 per triangle or quadrant, 2 per semicircle. The report is produced even in "Solid" block detail.
* **Leg deduction.** Legs are shorter than the finished height by a per-model amount (25 mm metric, 1 in imperial in the shipped catalog; key `leg_deduction` in the catalog, and an override field under "Staging system"). The modelled deck slab uses the same thickness so legs meet its underside. A leg standing on a lower step is measured from that step's top: a 200 mm rise gives a 175 mm leg with a 25 mm deduction. Older user catalogs that use `deck_thickness` still work.
* **Fix:** the packer's grid step was rounded slightly, so on some sizes a whole row or column of decks at the far edge was left unfilled (a 5 x 3 m area reached only 96.7%). It now fills 100% when the decks allow it.

Tested outside SketchUp (plain Ruby): packing, perimeter tracing, step counts, inside/outside steps and the leg tallies. The SketchUp-specific parts (geometry creation, dialogs, edge picking) are still untested here.
