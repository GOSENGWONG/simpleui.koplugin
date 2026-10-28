# Tiny Critter

A pixel-art companion for your Home Screen, with a speech bubble that comments on your reading. It is off by default: add it from the layout editor, then choose the critter, its side, the decorations, the topics and where the phrases come from.

## What it does

- **Passive phrases** — a greeting for the time of day, your streak, books finished this year, goals and milestones.
- **Conversation** — tap the critter (or press Enter) to open a chat. The bubble shows a prompt and a panel below it offers 2–3 replies; **Say something else…** draws a new prompt. The window closes on a tap outside, Back, suspend or a screen size change. Without a touch screen, Up/Down move the selection and Press chooses.
- **Mood** — the critter has a mood from *grumpy* to *radiant*. It rises with the reading you do each day and with conversation (up to a daily cap), and falls on days you do not read. Mood only shapes the conversation.
- **Event reactions** — without being tapped, it comments on what happened: finishing a book, a reading session, low battery, a special date, a new month, your return after time away, or the device charging. One pending reaction is shown at a time, and it expires after two days. Toggle with **React to events**.
- **Daily challenges** — it can offer one challenge a day (read a number of minutes or pages today, read for a minute to keep your streak, or start a session before a deadline hour). A completed challenge gives a mood bonus and a reaction. Challenges expire at midnight, with no penalty.
- **Reading suggestions** — ask "Want something new to read?" and it suggests a book from your library that you have not opened yet; you can open it, ask for another or say not now.
- **Bubble style** — *Pixel* (default, stepped corners and tail) or *Smooth* (anti-aliased).
- **Fonts** — the bubble uses the font of the module's Message style; in the Pixel style that defaults to the bundled Geist Pixel family.
- **Your name** — set **Your name** and some phrases will use it.

## Layout

The bubble has a fixed size, so the critter and the decorations never move. You choose which side of the bubble the critter stands on, arrange up to two decorations on each side (in the order they stand on the screen; any that do not fit are left out), and align the whole group left, centre or right on wide screens.

## Bundled critters

Suey (the default, a cat), Chonk (a cat with heart-shaped sunglasses and a tiara), Tulu (a tiny winged tentacle-faced sea monster), Frankie (a stitched-together patchwork monster), Vlad (a pale, pointy-eared little vampire in a red-lined cape), Sholmes (a deerstalker-wearing detective in a long brown coat), Argos (a loyal floppy-eared dog with a red collar) and Hazel (a messy-haired little witch in a crooked pointed hat and a gingham dress). Each has twelve moods: `neutral`, `happy`, `party`, `sleepy`, `cheer`, `love`, `sad`, `surprised`, `curious`, `grumpy`, `shy`, `playful`.

## Custom critters and decorations

Everything below lives in `<KOReader settings dir>/simpleui/sui_critters/`. The folder is created when you open the *Critter* picker and is never touched by updates.

- **Your own critters** — a critter is a folder named after it holding `neutral.png` (required) and optionally one image per mood above, all with the same canvas size. A single loose `.png` file is used for every mood; `.svg` works too. A PNG whose longest side is 64 px or less is treated as pixel art and enlarged without smoothing. A critter with the same name as a bundled one replaces it.
- **Your own decorations** — `.png` (or `.svg`) files in `sui_critters/decor/`. Loose files stand on the floor of the row; put them in `decor/wall/` to hang them at mid-height or in `decor/ceiling/` to hang them from the top. Pixel-art decorations are enlarged by the same factor as the critter.
- **Your own phrases** — put a `phrases.lua` in the same folder, returning a list of `{ text = "...", sub = "...", mood = "happy", period = "morning", min_streak = 3, min_books = 1 }`. Only `text` is required.
  - `sub` is the smaller second line (up to two lines in the bubble).
  - `mood` is one of the twelve moods listed above (`neutral`, `happy`, `party`, `sleepy`, `cheer`, `love`, `sad`, `surprised`, `curious`, `grumpy`, `shy`, `playful`); any other value shows `neutral`.
  - `period` is one of `morning`, `afternoon`, `evening`, `night`.
  - `text` and `sub` may use `{streak}`, `{books}`, `{pages}`, `{minutes}`, `{goal}`, `{weekday}` and `{name}` (the name you gave the critter). A phrase is skipped while one of its placeholders has no value.
  - Set **Phrases** on the module to *Included and mine* or *Mine only*.

Custom critters are included in [backups](../README.md#backup--restore).

Back to the [README](../README.md).
