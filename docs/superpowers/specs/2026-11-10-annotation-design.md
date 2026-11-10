# Annotation (Pictty 1.6, part 2)

Date: 2026-11-10 · Branch: `1.6` · Status: design approved in conversation ("sounds perfect")

## What the person sees
- **Annotate** in the toolbar and **Edit ▸ Annotate**. While annotating, the main toolbar steps aside
  and the **annotation bar** shows at the bottom (like the crop bar): tools, style, Undo/Redo, Done.
- Tools (key): Select (V), Arrow (A, drag its middle to curve), Rectangle (R), Rounded rectangle (U),
  Circle (O; ⇧ = round/square), Text (T, a pill behind it), Steps (N: ①②③, renumbered on delete),
  Highlighter (H), Blur (B), Censor (X: pixelate, or a solid bar), Magnifier (M), Spotlight (S).
- **Smart redact** (wand): macOS's text and face recognition finds e-mails, phone numbers, card numbers
  (censored) and faces (blurred); each is an ordinary annotation, undoable.
- **Smart colour** (Auto, the default swatch): each new shape takes the palette colour that stands out
  most against the picture under it. Six colours + custom, three widths, Fill, Shadow (on by default).
- Click selects, drag moves, handles resize, ⌫ deletes, ⌘D duplicates, ⌘Z / ⇧⌘Z (and Edit ▸ Undo/Redo).
  Esc deselects, then leaves; Return leaves.

## Model and order
- Annotations live in the picture's own 0…1 coordinates before the crop (stored orientation): a later
  crop keeps them on the same content. Widths and text sizes are fractions of the final picture's
  shorter side, so Enlarge and Image Size keep their look.
- Order: … crop → Enlarge → Image Size → **annotations** → turn. Drawn last, at the final resolution.
- On screen: a view over the canvas, redrawn on every layout (zoom, pan, turn), drawn by the same code
  that burns them into the pixels on Save, Save As, Print and Copy. Before/After hides them.
- P0: nothing of this loads or runs until Annotate is opened; smart redact runs only on its click.

## Code
- `PicttyCore/Annotation.swift`: `Annotation`, `AnnotationStyle`, geometry (bounds, hit tests,
  handles, arrow curve), step numbering, contrasting colour.
- `PicttyCore/AnnotationRenderer.swift`: Core Graphics drawing + Core Image for blur, pixelate,
  magnifier; spotlight dims outside.
- `Pictty/UI/AnnotationOverlayView.swift`, `AnnotationToolbarView.swift`,
  `ViewerWindowController+Annotate.swift`; hooks in the edit chain like the other edits.

## Testing
- Unit: numbering after delete; contrasting colour; hit tests and mapping through a crop; renderer:
  an arrow marks pixels on its line only, blur changes pixels inside its rect only, a solid censor is
  black inside, spotlight darkens outside only, output size equals input.
- App: dev hooks to add each kind, save, and compare; P0 launch timing.
