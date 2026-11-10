# Remove background (Pictty 1.6, part 1)

Date: 2026-11-10 · Branch: `1.6` · Status: design approved in conversation

## What the person sees
- A **Background** button in the toolbar after Enlarge (SF Symbol `person.and.background.dotted`), and
  **Edit ▸ Remove Background**. Its strip: **Transparent · White · Black · Colour… · Blurred | Off**.
- The subjects (people, pets, objects — all of them, as Photos does) are found by macOS's own subject
  lifting (`VNGenerateForegroundInstanceMaskRequest`; Pictty needs macOS 15, so every user has it).
  Nothing is bundled and nothing loads until the button is used.
- While the mask is made (under a second; once per picture and size), the mascot badge
  "BACKGROUND · finding the subject" shows. No subject: toast "No subject found to keep", nothing changes.
- **Colour…** opens the standard colour panel; the fill follows it live. **Blurred** keeps the real
  background, blurred (radius 1.5 % of the longer side), for a portrait look.
- Works with every other edit: Before/After, crop, Enlarge, Image Size, Save, Save As, Print, Copy, compare off.

## Order
original → adjustments → **background** → crop → Enlarge → Image Size → turn. The mask is made from
the picture as it reaches this step (Vision is not swayed by exposure), at that picture's size, cached
per size on the editing session. Edges: Vision's soft mask, as it comes.

## Saving
- Transparent: Save over a JPEG (or another format without alpha) opens Save As with PNG chosen, and a
  toast says why. Save As keeps the user's choice of PNG / HEIC / TIFF.
- The other fills save to any format.

## Code
- `PicttyCore/BackgroundFill.swift`: `enum BackgroundFill: Equatable { transparent, white, black,
  colour(r, g, b), blurred }`, `BackgroundComposite.apply(_ image: CGImage, mask: CGImage, fill:) -> CGImage?`
  (Core Image: blend with mask; blurred = CIGaussianBlur of the picture, clamped edges).
- `Pictty/Render/SubjectMask.swift`: `SubjectMask.make(for: CGImage) -> CGImage?` (Vision, all
  instances, scaled to the input size, grey float), off the main thread.
- `Pictty/UI/ViewerWindowController+Background.swift`: `setBackground(_:)`, the mask cache and badge,
  the strip's colour panel; hooks in `present`, `renderEdited`, `EditState`, `EditSnapshot`, revert, endLight.
- Toolbar button + strip like Enlarge's; Edit menu item; Spanish strings; dev hooks `background <fill>`.

## Testing
- Unit: `BackgroundComposite` — with a half-white mask: transparent → alpha 0 outside, subject unchanged
  inside; white/black/colour → that colour outside; blurred → inside unchanged, outside differs.
- App (dev hooks) on portrait/pet photos: mask found, Save As PNG has alpha, JPEG Save routes to Save As,
  sizes with crop/Enlarge, P0: launch and browsing timings unchanged, no Vision work while browsing.
