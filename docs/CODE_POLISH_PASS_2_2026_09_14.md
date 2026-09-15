# Stocked iOS — second code and polish pass

September 14, 2026. This is a separate **20 code improvements + 10 polish improvements** batch. It does not recount Kitchen Math or the earlier Toolbox/search changes. Existing dirty changes were retained. No simulator, device installation, service deployment, paid integration, or AI request was performed.

## Twenty code improvements

| # | Concrete correction | Source evidence |
|---|---|---|
| C01 | Duration parsing reuses one compiled regular expression and rejects instruction text above 32,768 characters rather than repeatedly compiling/searching unbounded strings. | `Stocked/CookingTimerPolicy.swift` — `pattern`, `detectSeconds` |
| C02 | Unicode, mixed and slash fractions now produce the intended duration: `1½ hours` → 5,400 seconds, `1/4 hour` → 900. Zero denominators and excessive values fail closed. | `CookingTimerPolicy.number` |
| C03 | A duration range uses the longer endpoint (`10–15 minutes` → 900 seconds), with a matching pre-start explanation. | `CookingTimerPolicy.detectSeconds` |
| C04 | Adjacent descending units form one duration; unrelated later instructions do not silently lengthen it (`1 hour 30 minutes` combines, `bake 30 minutes, cool 10 minutes` does not). | `CookingTimerPolicy.detectSeconds` |
| C05 | The observable countdown model explicitly belongs to the main actor; only its own methods mutate running, finished, remaining and deadline state. | New `Stocked/StepTimer.swift` |
| C06 | Repeated Start calls on an active/finished timer return without creating another countdown task or changing its deadline. | `StepTimer.start` |
| C07 | Countdown state derives from an absolute deadline rather than decrementing once per wakeup, recovering elapsed time after delayed task execution. | `StepTimer.refresh`, `CookingTimerPolicy.remaining` |
| C08 | Pause and export refresh elapsed time before saving; restore preserves the saved fractional deadline instead of adding the rounded remainder to now. | `StepTimer.pause/start`, `StepTimerEngine.exportStates/restore` |
| C09 | Countdown tasks weakly capture their owner, use a run token, cancel on pause/reset/deinit and cannot retain an abandoned timer or complete an old run. | `StepTimer.start/pause/deinit` |
| C10 | Session restoration cancels prior engine work, caps restored timers at 128, validates step/duration values, rejects duplicate steps and bounds remaining time before integer conversion. | `Stocked/StepTimerEngine.swift` — `restore` |
| C11 | Each notification run has its own UUID identifier, carried in the optional local snapshot field. Different recipes and late prior runs no longer share `step_timer_N` IDs. | `StepTimerEngine.scheduleNotification/restore`, `CookSessionPersistence.swift` |
| C12 | Notification authorization/add callbacks recheck run identity, cancellation and the captured deadline. Scheduling uses the time still remaining after authorization, and late canceled adds remove only their own ID. | `StepTimerEngine.scheduleNotification/cancelNotification` |
| C13 | Denied permission and notification-add failures become observable feedback while the local timer stays usable. | `StepTimerEngine.notificationStatus` |
| C14 | Live Activity selection follows the soonest running timer, with stable step ties. Pausing another timer keeps the next timer visible; unchanged selections do not restart the activity. | `StepTimerEngine.updateLiveActivity` |
| C15 | Live Activity termination is scoped to the initiating engine's owner token, so one cooking surface cannot end a different engine's active timer. | `Stocked/LiveActivityManager.swift` — `start/end(owner:)` |
| C16 | Display conversion and quantity conversion share one unit normalizer/factor registry. Plurals, punctuation and whitespace now agree (`litres`, `kilograms`, `fl. oz.`). | `Stocked/UnitMath.swift`, `Stocked/UnitConverter.swift` |
| C17 | Unit conversion rejects nonfinite/negative input and overflow, including same-unit passthrough. Multiplying by the final factor ratio avoids unnecessary intermediate overflow; mass/volume still requires known density. | `UnitMath.convert`, `UnitConverter.convert` |
| C18 | Reminder clock values are bounded, an explicitly stored midnight stays midnight, overnight choices are not overruled by learned daytime timing, and permission callbacks recheck the enabled preference. | `DailyBriefNotificationManager.swift`, `ReminderClockPolicy` |
| C19 | Expiry reminder replacement is serialized and cancellation-aware. A prior asynchronous removal can no longer delete a just-added replacement batch. | `DailyBriefNotificationManager.replaceExpiryRequests` |
| C20 | Community price refresh reserves its task synchronously. Two immediate taps cannot both enter before the asynchronous body sets its visible refreshing item. | `CommunityPriceWatchStore.refresh` |

## Ten polish improvements

| # | Visible or accessible improvement | Source evidence |
|---|---|---|
| P01 | Recipe detail and active cooking use the same timer control, eliminating two separate layouts and interaction implementations. | `RecipeTextSize.StepTimerChip`, `CookingFlow.CookingStepRow` |
| P02 | Timer controls use one themed rounded surface, semantic accent contrast and a minimum 44-point height, with an outlined running state and natural label wrapping. | `StepTimerChip.body` |
| P03 | Start, Pause, Resume and Reset are named actions with matching state glyphs; a reset timer correctly returns to Ready/Start. Finished state includes a checkmark. | `StepTimerChip.actionLabel/stateLabel/symbol` |
| P04 | VoiceOver gets the step, state, spoken remaining time, action hint and a named Reset action; Reset is also available in the context menu. | `StepTimerChip` accessibility modifiers |
| P05 | Long timers display `h:mm:ss`; shorter timers retain `m:ss`. Monospaced digits keep the clock width stable. | `CookingTimerPolicy.display`, `StepTimerChip` |
| P06 | The cooking step badge no longer squeezes a 9-point countdown into its small circle. An active timer glyph leads to the full readable timer control. | `CookingFlow.CookingStepRow` |
| P07 | The timer states its range assumption before starting and explains background-alert permission/failure beside the running control. | `StepTimerChip` supporting text |
| P08 | Read-aloud actions have 44-point targets, semantic active contrast and a Stop-reading accessibility label while speaking. | `TimedStepRow`, `CookingFlow.CookingStepRow` |
| P09 | Reminder times use a shared native time picker, support every minute and follow the device's localized 12/24-hour presentation instead of separate quarter-hour menus. | `DailyBriefNotificationSettingsView.timeRow`, manager `timeLabel` |
| P10 | Reminder toggles have explicit accessible names; Open Settings is clearly labeled; permission copy qualifies Focus/summary behavior and saved feedback describes a saved preference rather than promising delivery. Feedback cancellation prevents an older save from clearing a new confirmation. | `DailyBriefNotificationSettingsView` |

## Ownership, persistence and compatibility

Stocked iOS owns this batch. Recipe detail, active cooking and local session restore produce timer state; the shared timer control, local notification center and existing Live Activity consume it. `CookSessionTimerState.notificationID` is an optional additive local field. Old snapshots decode with no ID and use their exact legacy step identifier for cancellation before a new run receives a UUID. New snapshots preserve the scoped identifier across relaunch. Older apps ignore this field, but do not understand the new notification identifiers when canceling timers after a downgrade; cancel timers on the newer build before rolling back if their pending alerts matter.

No household timer synchronization was added. No Worker route, shared household schema, Live Activity attribute schema, extension payload, account or credential changed. Existing local cooking/session files remain authoritative. Timer instructions and notification content stay on device/Apple's existing local presentation surfaces. Rollout consists of the app update; there is no server migration or publication dependency.

`UnitMath` remains the authority for unit aliases and base factors; `UnitConverter` is its presentation/density consumer. Unknown density stays unknown, and count units are not guessed into volume or mass. Reminder preferences remain device-local UserDefaults. No inventory, recipe, household or grocery records are rewritten by these changes.

## Verification

- **89 native cooking reliability checks passed**: numeric/fraction/range/compound parsing, bounded input, malformed values, delayed/duplicate/pause/reset/restore timer behavior, real one-second task completion and weak-owner cleanup, shared unit aliases, finite/overflow guards and reminder clock bounds. Source: `scripts/CookingReliabilityChecks.swift`.
- Existing **26 Free Kitchen**, **31 Community Price Watch** and **4 theme contrast** checks passed.
- Changed Swift files passed frontend parsing, and `git diff --check` passed.
- Final generic iOS compilation succeeded with no reported warnings/errors; app, share extension and widget each contain marketing version **5**, build **247**. Log: `/tmp/stocked-code-polish-pass2-final-build.log`.
- Build uses the existing external cache at `/Volumes/Macintosh SSD/MacStorage/Developer/DerivedData/Stocked-Polish-20260914`; no simulator/runtime was installed.

Reproduce the new native checks from the repository root:

```sh
xcrun swiftc Stocked/CookingTimerPolicy.swift Stocked/StepTimer.swift Stocked/UnitMath.swift Stocked/UnitConverter.swift scripts/CookingReliabilityChecks.swift -o /tmp/stocked-cooking-reliability
/tmp/stocked-cooking-reliability
```

## Limits and follow-up on device

Native fixtures and compilation are not device interaction or notification-delivery proof. VoiceOver, large text, system DatePicker presentation, notification authorization races and Live Activity transitions need device review. OS notification limits, Focus and background execution remain platform-controlled; the UI does not guarantee delivery. Leaving a cooking surface preserves already registered timer alerts, but cancels an unfinished permission/scheduling request. A range uses its longer endpoint, not a food-safety estimate. English duration parsing remains intentionally limited; days, arbitrary prose numbers and all possible recipe-language formats are not supported.
