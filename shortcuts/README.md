# Snapshot shortcut

Build these in the Shortcuts app on the iPhone, then export them here and share the iCloud link from
onboarding (`ShortcutWalkthrough.shortcutURL`).

## "Snapshot"

1. **Open URLs** → `goaltracker://snapshot`
2. **Wait** → 3 seconds (the report view loads slowly; 1 second can screenshot the wrong screen)
3. **Take Screenshot**
4. **Extract Text from Image** → Screenshot
5. **Submit Screen Time Snapshot** (GolGolGol!!!) → Text: *Text from Image*, Day: Today
6. **Go to Home Screen** (or Open App → the previous app)

Tip: while debugging, add **Show Result** → *Text from Image* after step 4 to see the raw OCR.

## "Snapshot (Yesterday)"

Same, with `goaltracker://snapshot?day=yesterday` in step 1 and Day: Yesterday in step 5. The report
prints its date, and the intent trusts that date over the parameter when OCR reads it.

## Automations

In Shortcuts → Automation → New Automation, with **Run Immediately** and notifications off:

- **Charger → Is Connected** → run *Snapshot* (primary, at night).
- **Time of Day** (e.g. your usual wake time) or **App → Is Opened** for an app you open first thing → run *Snapshot (Yesterday)*.
  The phone must be unlocked with the screen on; if it isn't, the day keeps its threshold range.

Rejected readings (unparseable text, or values lower than an earlier snapshot the same day) appear in
Settings → Screen Time → Snapshot log on the iPhone.
