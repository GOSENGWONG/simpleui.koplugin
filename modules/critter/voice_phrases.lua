-- voice_phrases.lua — Simple UI
-- Phrases each bundled critter says in its own voice besides the general ones
-- of phrases.lua, in the same categories and with the same fields.
-- A phrase is { id, critter, cat, mood, when(f), text(f), sub?(f) }.

local _ = require("infra/sui_i18n").translate

local Voices = {}

-- When each situation applies, from the facts of phrases.lua.
local WHEN = {
    greet_morning   = function(f) return f.period == "morning" end,
    greet_afternoon = function(f) return f.period == "afternoon" end,
    greet_evening   = function(f) return f.period == "evening" end,
    greet_night     = function(f) return f.period == "night" end,
    streak          = function(f) return f.streak ~= nil and f.streak >= 2 end,
    today           = function(f) return f.today_secs ~= nil and f.today_secs >= 60 end,
}

local function add(critter, situation, cat, mood, text, sub)
    Voices[#Voices + 1] = {
        id = string.format("v_%s_%s", critter, situation), critter = critter, cat = cat,
        mood = mood, when = WHEN[situation], text = text, sub = sub,
    }
end


-- Suey.

add("suey", "greet_morning", "greeting", "happy",
    function() return _("Morning. The sunbeam is mine.") end,
    function() return _("You may read beside it.") end)
add("suey", "greet_afternoon", "greeting", "playful",
    function() return _("Afternoon. Nap or read?") end,
    function() return _("Why not both.") end)
add("suey", "greet_evening", "greeting", "love",
    function() return _("Evening. Lap time.") end,
    function() return _("Bring the book.") end)
add("suey", "greet_night", "greeting", "curious",
    function() return _("Night. I patrol the shelf.") end,
    function() return _("Read quietly.") end)
add("suey", "streak", "streak", "happy",
    function() return _("Streak intact. I'm impressed.") end,
    function() return _("Don't tell anyone.") end)
add("suey", "today", "today", "playful",
    function() return _("Good reading today.") end,
    function() return _("I supervised from the sill.") end)

-- Chonk.

add("chonk", "greet_morning", "greeting", "cheer",
    function() return _("Good morning. I look incredible.") end,
    function() return _("As always.") end)
add("chonk", "greet_afternoon", "greeting", "playful",
    function() return _("Afternoon. Read something worthy.") end,
    function() return _("I'm watching.") end)
add("chonk", "greet_evening", "greeting", "happy",
    function() return _("Evening. Time to be fabulous.") end,
    function() return _("With a book, obviously.") end)
add("chonk", "greet_night", "greeting", "sleepy",
    function() return _("Night. Beauty sleep soon.") end,
    function() return _("Finish your chapter first.") end)
add("chonk", "streak", "streak", "cheer",
    function() return _("A streak! Naturally.") end,
    function() return _("I inspired it.") end)
add("chonk", "today", "today", "playful",
    function() return _("You read today. I'm so proud.") end,
    function() return _("Of me, mostly.") end)

-- Tulu.

add("tulu", "greet_morning", "greeting", "happy",
    function() return _("Dawn tide. Good morning.") end,
    function() return _("The deep stirs.") end)
add("tulu", "greet_afternoon", "greeting", "happy",
    function() return _("Afternoon currents are calm.") end,
    function() return _("Good depth for reading.") end)
add("tulu", "greet_evening", "greeting", "curious",
    function() return _("Evening. The light sinks.") end,
    function() return _("Time to go deeper.") end)
add("tulu", "greet_night", "greeting", "sleepy",
    function() return _("Night. The abyss hums.") end,
    function() return _("Read me a page.") end)
add("tulu", "streak", "streak", "happy",
    function() return _("Your streak runs deep.") end,
    function() return _("Steady as the tide.") end)
add("tulu", "today", "today", "love",
    function() return _("You read today. The deep smiles.") end,
    nil)

-- Frankie.

add("frankie", "greet_morning", "greeting", "cheer",
    function() return _("Good morning! All parts present.") end,
    function() return _("Stitches tight.") end)
add("frankie", "greet_afternoon", "greeting", "happy",
    function() return _("Afternoon! I'm holding together.") end,
    function() return _("Read with me?") end)
add("frankie", "greet_evening", "greeting", "happy",
    function() return _("Evening! Patching up the day.") end,
    function() return _("A chapter helps.") end)
add("frankie", "greet_night", "greeting", "sleepy",
    function() return _("Night! Seams are sleepy.") end,
    function() return _("Zzz. Stitch.") end)
add("frankie", "streak", "streak", "cheer",
    function() return _("Streak! I'm all stitched up.") end,
    function() return _("Don't let it fray.") end)
add("frankie", "today", "today", "party",
    function() return _("You read today! Hooray!") end,
    function() return _("Gold star, hand-sewn.") end)

-- Vlad.

add("vlad", "greet_morning", "greeting", "sleepy",
    function() return _("Morning. The sun is… rude.") end,
    function() return _("Close the curtains. Read.") end)
add("vlad", "greet_afternoon", "greeting", "happy",
    function() return _("Afternoon. I'm hiding indoors.") end,
    function() return _("A book keeps me company.") end)
add("vlad", "greet_evening", "greeting", "happy",
    function() return _("Evening. At last.") end,
    function() return _("My favourite hour.") end)
add("vlad", "greet_night", "greeting", "love",
    function() return _("Night. Now we live.") end,
    function() return _("Read until dawn.") end)
add("vlad", "streak", "streak", "happy",
    function() return _("A streak. How eternal.") end,
    function() return _("I approve of habits.") end)
add("vlad", "today", "today", "love",
    function() return _("Reading done today. Elegant.") end,
    function() return _("I'm almost warm.") end)

-- Sholmes.

add("sholmes", "greet_morning", "greeting", "curious",
    function() return _("Morning. You slept six hours.") end,
    function() return _("A guess. Am I wrong?") end)
add("sholmes", "greet_afternoon", "greeting", "curious",
    function() return _("Afternoon. The case awaits.") end,
    function() return _("Open the book.") end)
add("sholmes", "greet_evening", "greeting", "curious",
    function() return _("Evening. Time for a quiet case.") end,
    function() return _("Of pages.") end)
add("sholmes", "greet_night", "greeting", "surprised",
    function() return _("Night. Why are you awake?") end,
    function() return _("A good book, I deduce.") end)
add("sholmes", "streak", "streak", "happy",
    function() return _("Streak noted. A pattern!") end,
    function() return _("Habits reveal character.") end)
add("sholmes", "today", "today", "happy",
    function() return _("Your bookmark moved. I noticed.") end,
    function() return _("Elementary.") end)

-- Argos.

add("argos", "greet_morning", "greeting", "cheer",
    function() return _("Good morning! Good morning!") end,
    function() return _("Read, then walk?") end)
add("argos", "greet_afternoon", "greeting", "cheer",
    function() return _("Afternoon! Are we reading?") end,
    function() return _("I'm ready!") end)
add("argos", "greet_evening", "greeting", "love",
    function() return _("Evening! Cuddle and read?") end,
    function() return _("I saved you a spot.") end)
add("argos", "greet_night", "greeting", "sleepy",
    function() return _("Night! Sleepy pup here.") end,
    function() return _("Read a little more?") end)
add("argos", "streak", "streak", "party",
    function() return _("Streak! You never skip!") end,
    function() return _("Good friend!") end)
add("argos", "today", "today", "party",
    function() return _("You read today! Yay!") end,
    function() return _("I wagged the whole time.") end)

-- Hazel.

add("hazel", "greet_morning", "greeting", "cheer",
    function() return _("Good morning! A fresh spell awaits.") end,
    function() return _("It's called reading.") end)
add("hazel", "greet_afternoon", "greeting", "happy",
    function() return _("Afternoon! The cauldron's quiet.") end,
    function() return _("Time for a chapter.") end)
add("hazel", "greet_evening", "greeting", "love",
    function() return _("Evening! The stars are early.") end,
    function() return _("Perfect for reading.") end)
add("hazel", "greet_night", "greeting", "sleepy",
    function() return _("Night! My hat's drooping.") end,
    function() return _("One more page, one more spell.") end)
add("hazel", "streak", "streak", "cheer",
    function() return _("Your streak is enchanted.") end,
    function() return _("Don't break the spell.") end)
add("hazel", "today", "today", "playful",
    function() return _("You read today! Spell worked.") end,
    function() return _("I'm good at this.") end)

return Voices
