# Changelog

## 1.1.0 — 2026-08-09

### Added

- **Extend off map** (per path/wall, Select tool): a slider (0–10 grid
  squares) that virtually continues a wall or path's edge-touching ends past
  the canvas. Dungeondraft won't let you draw beyond the map border, so a
  wall running to the edge used to end its shadow in a rounded cap and let
  sun leak around its imaginary continuation — now the shadow runs clean off
  the border. Applies to terrain contours, free-standing walls, and "Stops
  outside shadows" blockers alike; only ends that touch the map edge extend,
  closed loops are unaffected, and nothing visible is drawn off-canvas.
  Default is 0, so existing maps render unchanged until you use it. If a
  faint cut-off still shows with the sun blowing along the edge, raise the
  slider — the artifact moves off-canvas by exactly the extension.

## 1.0.0 — 2026-08-09

Initial release. Sun-aware terrain shadows cast from cliff and wall paths:
physically accurate lengths from height (in feet) and sun angle, real
penumbra, multi-tier stacking, one-sided walls, portals that open to the sun
and project light patterns, object shadows traced from the object's own
artwork, layer-aware placement, and export-resolution baking.
