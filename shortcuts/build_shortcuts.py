"""Generates and signs the Snapshot shortcuts, so they can be imported with one tap.

    python3 shortcuts/build_shortcuts.py

Writes "Snapshot.shortcut" and "Snapshot (Yesterday).shortcut" to shortcuts/signed/ (bundled into the iPhone app), signed with
`shortcuts sign --mode anyone` (needs this Mac signed in to iCloud).

Each shortcut: Open URL → Wait 3s → Take Screenshot → Extract Text from Image →
Submit Screen Time Snapshot (the app's intent). The Snapshot screen prints its date, and the intent
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
    screenshot, extracted, submit = (str(uuid.uuid4()).upper() for _ in range(3))
    actions = [
        {"WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
         "WFWorkflowActionParameters": {"WFInput": text(url), "Show-WFInput": True}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.delay",
         "WFWorkflowActionParameters": {"WFDelayTime": 3}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.takescreenshot",
         "WFWorkflowActionParameters": {"UUID": screenshot}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.extracttextfromimage",
         "WFWorkflowActionParameters": {
             "UUID": extracted,
             "WFImage": {"Value": output_of(screenshot, "Screenshot"), "WFSerializationType": "WFTextTokenAttachment"},
         }},
        {"WFWorkflowActionIdentifier": f"{BUNDLE_ID}.SubmitSnapshotIntent",
         "WFWorkflowActionParameters": {
             "UUID": submit,
             "text": {"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": output_of(extracted, "Text from Image")}},
                      "WFSerializationType": "WFTextTokenString"},
             "AppIntentDescriptor": {
                 "BundleIdentifier": BUNDLE_ID,
                 "Name": "GoalCompanion",
                 "TeamIdentifier": TEAM_ID,
                 "AppIntentIdentifier": "SubmitSnapshotIntent",
                 "ActionRequiresAppInstallation": True,
             },
         }},
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
