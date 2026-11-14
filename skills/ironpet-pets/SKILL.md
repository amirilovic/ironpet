---
name: ironpet-pets
description: Create a new pet (character) for ironpet, the macOS desktop pet, as an animated sprite sheet. Use when the user asks to create, build or draw a new ironpet pet or character, for example "create a new ironpet character: a red fox with a scarf".
---

# Create an ironpet pet

A pet is one PNG sprite sheet. ironpet shows every valid sheet in `~/.ironpet/pets/` as an animated tile in Settings → Pet, and the user picks it there. You write the sheet. You do not edit ironpet itself.

## Steps

1. Work out a short kebab-case name from the description, without a leading "a", "an" or "the": "a red fox with a scarf" becomes `red-fox-with-a-scarf`. The output is `~/.ironpet/pets/<name>.png`. If that file exists, pick another name. Never overwrite a sheet.
2. Find the reference generator, `make_pet.swift`. The request gives its path. Otherwise it is `tools/make_pet.swift` in the ironpet repository, or `Contents/Resources/make_pet.swift` inside `IronPet.app`. Copy it to a scratch folder and edit the copy. Never edit the original.
3. In your copy, add a theme for the new pet to the `themes` dictionary. A theme sets the colors (`fur`, `furShade`, `outline`, `cream`, `earPink`, `blush`, `iris`), markings, `tail`, `cloak`, `muzzle` and so on. The `species` value (`wolf`, `hamster`, `panda`, `bunny`, `cat`) picks the ears, tail and face in the `switch theme.species` blocks. Reuse the closest species and recolor it. Add a new `Species` case and a branch in each switch only when no existing one comes close, for example for a fox, long pointed ears and a bushy tail.
4. Run `swift make_pet.swift <theme> <scratch>/<name>.png`. The first argument is the theme name from the dictionary.
5. Open the PNG and look at it. Check that the character matches the description in the idle, waving, jumping and running rows, and that no cell is cropped. Fix the theme and run again until it does.
6. Check the size with `sips -g pixelWidth -g pixelHeight <file>`. It must be 1536 x 2704.
7. Move the finished file into `~/.ironpet/pets/<name>.png` in one step (`mkdir -p` the folder, then `mv`). ironpet reloads the folder every couple of seconds, so a half-written file would show up as a broken tile.
8. Tell the user the path and what you drew. They pick the pet in Settings → Pet.

## Sheet layout

A transparent PNG, 1536 x 2704 pixels. 8 columns and 13 rows, every cell 192 x 208 pixels. The cell at column `c`, row `r` starts at x = `c * 192`, y = `r * 208` from the top left. Draw the same character in every cell, facing the viewer, centered, with the feet near the bottom. Leave unused cells transparent.

| Row | Animation | Frames |
| --- | --- | --- |
| 0 | idle | 6 |
| 1 | run right | 8 |
| 2 | run left | 8 |
| 3 | waving | 4 |
| 4 | jumping | 5 |
| 5 | failed | 8 |
| 6 | waiting | 6 |
| 7 | running | 6 |
| 8 | review | 6 |
| 9, 10 | look directions | 16 in total, 8 per row |
| 11 | drinking (ironpet's own row) | 6 |
| 12 | stretching (ironpet's own row) | 8 |

Frames fill a row from column 0. Rows 9 and 10 hold sixteen head turns. Frame `i` (row 9 first) has the eyes looking toward the angle `i * 22.5` degrees clockwise from straight up. A sheet 2288 pixels tall (rows 0 to 10, the Codex pet v2 layout) also loads, but ironpet then plays the waving row for drinking and stretching, so always draw all 13 rows.

The generator already draws every row for its six pets (ghost, mochi, hamster, panda, bunny, cat), so a recolored or re-themed copy keeps the layout correct.
