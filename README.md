# GolGolGol!!!

A Watch-first daily goal tracker for two. Six goals, checked automatically where Apple allows it,
shared with a partner, and wrapped up each night on your wrist.

| Goal | How it's measured | Default |
| --- | --- | --- |
| Steps | HealthKit (Watch and iPhone, de-duplicated) | 10,000 |
| Workout | HealthKit workouts (walks don't count), or exercise minutes | one 20-minute workout |
| Screen time | Screen Time thresholds on the iPhone; exact via a snapshot shortcut | under 2 hours |
| Pickups | Snapshot shortcut, or answered in the nightly questions | under 50 |
| Wake up | HealthKit sleep: the morning's final wake time, on the days you pick | by 6:00, weekdays |
| Over-eating | Answered in the nightly questions | none |

## What it does

- **Watch app**, four swipeable pages:
  - **Today:** your goals, with the nightly questions at the top when they're due.
  - **History:** day, week and month grids with perfect-day stars.
  - **Partner:** your partner's goals, read-only.
  - **Settings:** targets.

  Tap any goal on any day for its page: what happened (step chart, workouts, wake time) and a place to correct the result.
- **iPhone app:** onboarding, Screen Time monitoring, the same Today, History, Partner and Settings, and one-tap snapshot buttons.
- **Complications and widgets:**
  - all six goals as colored rings;
  - goals completed today;
  - the goal closest to done;
  - a Smart Stack card at recap time.
- **Reminders:**
  - 30 minutes before the screen time limit;
  - 10 pickups before the pickups limit (when a snapshot runs);
  - 6pm if steps or the workout aren't done;
  - the nightly recap, with over-eating answerable from the notification.
- **Partner sharing:** exchange an invite code, and each of you sees the other's goals live.
- **Challenges:** pick a date range and track completion % and per-day averages for each goal.

## How it's built

```
apps/
  project.yml            XcodeGen spec (cd apps && xcodegen)
  GoalWatch/             watchOS app
  GoalWatchWidgets/      complications and Smart Stack widget
  GoalCompanion/         iOS app: onboarding, Screen Time, snapshot shortcut hand-off
  ActivityMonitor/       DeviceActivityMonitor extension: threshold crossings, reminders
  ActivityReport/        DeviceActivityReport extension: the OCR-friendly snapshot view
  AppCore/               shared by the iPhone and Watch apps (model, HealthKit, UI)
packages/GoalKit/        models, goal evaluation, wake-up detection, snapshot parsing,
                         local store and sync engine, Cognito + AppSync client (with tests)
backend/                 AWS Amplify Gen 2: Cognito, AppSync, DynamoDB, share-aware resolvers
shortcuts/               the signed Snapshot shortcuts and the script that builds them
```

- **Evaluation:** each device records raw readings (Metrics), turns each day's readings into a result per goal (DaySummaries), and syncs both to AWS. Evaluation is the same code on both devices, so they agree.
- **Offline first:** a local JSON store with an upload queue in an App Group.
- **Sign-in:** the iPhone signs in (Cognito) and hands the session to the Watch over WatchConnectivity.
- **Partner access:** checked by the server's resolvers, not the client.
- **Screen Time:** Apple doesn't let apps read Screen Time directly. The app registers "passed X minutes" thresholds (a range), and a Shortcuts automation screenshots Apple's report view and OCRs the exact numbers.

## Running it

Needs Xcode 26+, a paid Apple Developer account, and a real iPhone and Apple Watch (Screen Time and
HealthKit don't work in the Simulator).

```sh
brew install xcodegen
cd packages/GoalKit && swift test --scratch-path /tmp/goalkit-build

# Backend (optional; without it the apps run local-only)
cd backend && npm install && npm run sandbox    # writes backend/amplify_outputs.json

# Apps
cd apps && xcodegen && open GoalTracker.xcodeproj
```

- **Before building:** set `DEVELOPMENT_TEAM` and the bundle ID prefix in `apps/project.yml`, and the App Group in `apps/Common/AppGroup.swift`, to your own.
- **Sign in with Apple** is off by default. To turn it on, set the `SIWA_*` secrets and deploy with `SIWA=1` (see `backend/amplify/auth/resource.ts`).

## Notes

- Internal identifiers (bundle IDs, the Xcode project, the backend stack) still use the original `goaltracker` name; changing them would orphan existing installs and data.
- In an iCloud-synced folder, run SwiftPM tests with `--scratch-path` outside it: iCloud adds file metadata that code signing rejects.
