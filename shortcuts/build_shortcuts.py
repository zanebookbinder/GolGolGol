"""Generates and signs the Snapshot shortcuts, so they can be imported with one tap.

    python3 shortcuts/build_shortcuts.py

Writes "Snapshot.shortcut" and "Snapshot (Yesterday).shortcut" to shortcuts/signed/ (bundled into the iPhone app), signed with
`shortcuts sign --mode anyone` (needs this Mac signed in to iCloud).

Each shortcut: Open URL, then repeat (wait 0.7s → Take Screenshot → Extract Text from Image →
if it contains "SCREEN": Submit Screen Time Snapshot and stop). The Snapshot screen prints its date, and the intent
uses that date, so the yesterday version only differs in the URL.
"""
import plistlib
import subprocess
import sys
import uuid
from pathlib import Path

BUNDLE_ID = "com.zanebookbinder.goaltracker"
TEAM_ID = "XFNCN2MARQ"
OUT = Path(__file__).parent / "signed"


def text(value):
    return {"Value": {"string": value, "attachmentsByRange": {}}, "WFSerializationType": "WFTextTokenString"}


def output_of(action_uuid, name):
    return {"OutputUUID": action_uuid, "Type": "ActionOutput", "OutputName": name}


def workflow(url):
    """Open the Snapshot screen, then up to 8 times: wait 0.7s, screenshot, read the text, and as soon
    as it shows the report ("SCREEN TIME"), submit it and stop. The app closes the screen on submit."""
    screenshot, extracted, submit = (str(uuid.uuid4()).upper() for _ in range(3))
    repeat_group, if_group = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    text_from_image = output_of(extracted, "Text from Image")
    actions = [
        {"WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
         "WFWorkflowActionParameters": {"WFInput": text(url), "Show-WFInput": True}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.repeat.count",
         "WFWorkflowActionParameters": {"GroupingIdentifier": repeat_group, "WFControlFlowMode": 0, "WFRepeatCount": 8}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.delay",
         "WFWorkflowActionParameters": {"WFDelayTime": 0.7}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.takescreenshot",
         "WFWorkflowActionParameters": {"UUID": screenshot}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.extracttextfromimage",
         "WFWorkflowActionParameters": {
             "UUID": extracted,
             "WFImage": {"Value": output_of(screenshot, "Screenshot"), "WFSerializationType": "WFTextTokenAttachment"},
         }},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
         "WFWorkflowActionParameters": {
             "GroupingIdentifier": if_group, "WFControlFlowMode": 0,
             "WFInput": {"Type": "Variable", "Variable": {"Value": text_from_image, "WFSerializationType": "WFTextTokenAttachment"}},
             "WFCondition": 99,  # contains
             "WFConditionalActionString": "SCREEN",
         }},
        {"WFWorkflowActionIdentifier": f"{BUNDLE_ID}.SubmitSnapshotIntent",
         "WFWorkflowActionParameters": {
             "UUID": submit,
             "text": {"Value": {"string": "\ufffc", "attachmentsByRange": {"{0, 1}": text_from_image}},
                      "WFSerializationType": "WFTextTokenString"},
             "AppIntentDescriptor": {
                 "BundleIdentifier": BUNDLE_ID,
                 "Name": "GoalCompanion",
                 "TeamIdentifier": TEAM_ID,
                 "AppIntentIdentifier": "SubmitSnapshotIntent",
                 "ActionRequiresAppInstallation": True,
             },
         }},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.exit", "WFWorkflowActionParameters": {}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
         "WFWorkflowActionParameters": {"GroupingIdentifier": if_group, "WFControlFlowMode": 2}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.repeat.count",
         "WFWorkflowActionParameters": {"GroupingIdentifier": repeat_group, "WFControlFlowMode": 2}},
    ]
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2607.0.2",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
        "WFQuickActionSurfaces": [],
    }


def main():
    OUT.mkdir(exist_ok=True)
    for name, url in [("Snapshot", "goaltracker://snapshot"),
                      ("Snapshot (Yesterday)", "goaltracker://snapshot?day=yesterday")]:
        unsigned = OUT / f"{name}.unsigned.shortcut"
        signed = OUT / f"{name}.shortcut"
        with unsigned.open("wb") as f:
            plistlib.dump(workflow(url), f, fmt=plistlib.FMT_BINARY)
        result = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(unsigned), "--output", str(signed)],
                                capture_output=True, text=True)
        if result.returncode != 0 or not signed.exists():
            sys.exit(f"Signing {name} failed: {result.stderr or result.stdout}")
        unsigned.unlink()
        print(f"signed {signed}")


if __name__ == "__main__":
    main()
