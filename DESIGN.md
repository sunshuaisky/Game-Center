# Design System

## Direction

An understated native Mac library for a person choosing a game at their desk in the evening. The window should feel calm and familiar, while artwork gives each title its own identity.

## Color

Strict monochrome system with light and dark appearances. Default to the macOS appearance, then allow a manual in-app override. Game cover artwork keeps its original color; app chrome, navigation, controls, and typography stay grayscale.

Light appearance:

- Canvas: `oklch(97% 0 0)`
- Sidebar: `oklch(93% 0 0)`
- Surface: `oklch(99% 0 0)`
- Primary text: `oklch(21% 0 0)`
- Secondary text: `oklch(45% 0 0)`
- Primary action: `oklch(24% 0 0)` with near-white text
- Hairline: `oklch(86% 0 0)`

Dark appearance:

- Canvas: `oklch(15% 0 0)`
- Sidebar: `oklch(12% 0 0)`
- Surface: `oklch(19% 0 0)`
- Primary text: `oklch(93% 0 0)`
- Secondary text: `oklch(73% 0 0)`
- Primary action: `oklch(91% 0 0)` with near-black text
- Hairline: `oklch(28% 0 0)`

## Typography

Use the system UI font stack. Keep labels and controls at native Mac scale; use a modest title hierarchy and reserve larger type for the selected game title.

## Layout

- A full-window library keeps device-specific keyboard or controller hints at the bottom left and settings at the top right.
- The selected game's cover fills the background with a contrast overlay for readable labels.
- A centered platform switcher separates the selected game's title area from a horizontal cover rail.
- Selection is visually clear and remains centered as the user moves through the rail.

## Components

- Bottom command hints: switch automatically between keyboard and controller mappings.
- Platform switcher: shows GBA, NDS, and Mac counts with a clear selected state.
- Game tile: cover artwork and title, with a strong focus outline for controller navigation.
- Settings: appearance choices and import action stay in the top-right menu.
- Language: follow the system, Chinese, English, or Japanese; online descriptions follow the selected language and fall back to English.
- Cover selection: game details can assign an image from the user's files.
- Metadata: show a short synopsis in the hero and a longer description plus source links in details; failed matches can be retried.

## Interaction

- Selection and hover respond quickly with a short ease-out transition.
- Respect `prefers-reduced-motion`.
- D-pad or the left stick moves horizontally through games; LB/RB switches platforms. LT toggles favorites, X plays, A confirms or opens details, Y opens options, B returns, and Menu/Options opens settings.
- Inside options, settings, details, cheats, and build surfaces, directional input moves focus and A confirms the focused action.
- Switch build intermediates and reusable caches are visible under `switch/build/`, separated into `S2Arm` and `nxnative`; library scanning excludes this tree.
- Arrow keys and Return mirror the primary navigation actions, with X/A/Y letter shortcuts for play, details, and options.
- Favorite toggles, cover selection, platform switching, and import are interactive in the native app.
- Metadata fetches use the game title only, cache results locally, and provide source links.
- Controller glyph letters appear only while a compatible controller is connected; mouse and keyboard prompts stay device-neutral.
- Appearance toggle follows macOS by default and allows a persisted light or dark override.
- Selection changes the background artwork and keeps the focused game visible in the carousel.
