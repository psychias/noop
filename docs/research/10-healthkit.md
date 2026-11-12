# 10 — Apple Health (HealthKit) mapping, with Health Connect parity

Documentation research (Phase 1, topic 10 of `RESEARCH_BRIEF.md`), written 2026-11-10 on branch
`research/metrics-literature` from the tree at `2a1de760`. This is a *documentation* topic: every claim
about Apple or Google behaviour below cites a URL fetched in this session (§7) and quotes the sentence it
rests on. Apple's developer pages render client-side, so each was fetched through the JSON endpoint that
backs the page (`developer.apple.com/tutorials/data/documentation/healthkit/<path>.json`); the human URL
is what §7 lists. Anything that could not be fetched is in §8 and is not relied on.

The owner's situation frames the priorities: a WHOOP 5.0 bonded only to NOOP, no official app, metrics
read **mainly in Apple Health** on an iPhone running iOS 27 (per the on-device note in
`HealthKitBridge.writeDenied`). So the Health app, not NOOP's own screens, is the primary reader of what
this topic covers.

**Headline findings**

1. **HealthKit now has an RMSSD type.** Apple's `HKQuantityTypeIdentifier` index lists
   `heartRateVariabilityRMSSD` (availability iOS 27.0 / watchOS 27.0, page has no description text yet)
   beside `heartRateVariabilitySDNN`. The brief's premise "HealthKit uses SDNN only" is true for iOS ≤ 26.
   NOOP's readiness RMSSD (`avgHrv`) has a native home on iOS 27 — *if* third parties may share it, which
   the page does not say and which must be probed on a device behind the `writeDenied` defence (§3 (a),
   §6 item 1).
2. The iOS vitals export is semantically right (SDNN index under the SDNN type, no RMSSD fallback, #2264)
   but structurally thin: zero-duration samples, no `HKDevice`, no time zone, delete-then-save instead of
   Apple's `HKMetadataKeySyncIdentifier`/`SyncVersion` upsert.
3. The **Shortcuts path labels RMSSD as "HRV"**, and the only HealthKit HRV type a Shortcut could have
   targeted until iOS 27 is SDNN. The setup guide the UI points to ("the project wiki on GitHub") does not
   exist (the wiki has one page, FAQ, which 404s), so nothing tells the user which type to pick.
4. Android writes RMSSD (correct: Health Connect has an RMSSD record and no SDNN record) stamped at **noon**;
   iOS writes SDNN stamped at **wake**. Two platforms, two statistics, two clocks.
5. Android's `Metadata(clientRecordId:, clientRecordVersion:)` carries no `Device` and no recording method.
   Google made both mandatory from `connect-client` 1.1.0-alpha12 (the pin is `1.1.0-alpha07`, so it still
   compiles; the next SDK bump breaks the writer).

---

## 1. What NOOP does today

### 1.1 iOS — `StrandiOS/Health/HealthKitBridge.swift` (1,952 lines; `writeBack` at ~L820–1420)

| Concern | What is written | Timestamp | Dedup key / mechanism | Metadata |
|---|---|---|---|---|
| Nightly vitals (`writeVitals`) | `.restingHeartRate` (count/min) from `DailyMetric.restingHr`; `.heartRateVariabilitySDNN` (ms) from `avgSdnn` **only** (no `avgHrv` fallback, #2264; a day without SDNN *retracts* any earlier sample); `.oxygenSaturation` (`spo2Pct/100`, percent); `.respiratoryRate` (count/min) from `respRateBpm`. | Zero-length sample (`start == end`) at the day's **wake instant** (`wakeByDay`), noon fallback. | `HKMetadataKeyExternalUUID = noop:<HKQuantityTypeIdentifier.rawValue>:<yyyy-MM-dd>` (`HealthWriteback.appleHealthVitalKey`); `deleteObjects` by `HKSource.default()` ∧ key, then `save`. | External UUID only. No `HKDevice`, no `HKMetadataKeyTimeZone`, no `HKMetadataKeyWasUserEntered`. |
| Sleep (`writeSleep`) | One `.inBed` sample per **bridged night** (`SleepStageTotals.bridgedNightGroups` → `HealthWriteback.mergedSleepPlan`) plus one category sample per stage interval: `wake/awake → .awake`, `light → .asleepCore`, `deep → .asleepDeep`, `rem → .asleepREM`, no-timing fragment → `.asleepUnspecified`; inter-fragment seams → `.awake`. | Interval samples; `inBed` spans earliest edited onset → latest wake. | `noop:sleep:<startTs of earliest fragment>`; delete carries every fragment key. Open nights held back (`nightIsStillOpen`). | External UUID only. |
| Heart rate (`writeHeartRate`) | 1-minute mean buckets (`repo.hrBuckets(bucketSeconds: 60)`), measured-first/PPG-fallback — the same series the charts plot. | 60-s interval samples, clamped to `now`. | Forward cursor (`hkHRWriteCursor.v1.<deviceId>`) + 48 h rewrite window; **range delete** by source ∧ date, then save in 5,000-sample chunks. | None at all (no external UUID, no motion context, no device). |
| Workouts (`writeWorkouts`) | `HKWorkoutBuilder(healthStore:configuration:device: .local())` per strap/manual row (source `apple-health` excluded); `activeEnergyBurned` sample spanning the whole workout when `energyKcal > 0`; `distanceWalkingRunning` / `distanceCycling` sample for the four distance sports; optional `HKWorkoutRouteBuilder` (#2340). | Workout start/end. | `noop:workout:<startTs>` via `builder.addMetadata`; delete-then-build; orphan reconciliation reads the window back and deletes only keys of ours no longer in the store (#2210). | External UUID on the workout; attached samples carry nothing. `device: .local()` = the iPhone. |
| Not written | Steps (#249), whole-day `activeKcalEst`, basal energy, skin temperature (`skinTempC` / `skinTempDevC`), VO₂ max (read-only on iOS), RMSSD. | | | |

Authorization: `quantityWriteIds` = RHR, SDNN, SpO₂, resp; `highResQuantityWriteIds` = HR, active energy, the
two distances; plus sleep, workout, workout route. `writeDenied = [.appleSleepingWristTemperature]` is
filtered out of every share set because asking to *share* it raised an uncatchable
`NSInvalidArgumentException` ("Authorization to share the following types is disallowed") on device (#1366).
Reads include `.bodyTemperature` but not `.appleSleepingWristTemperature`.

Pure helpers (`Packages/StrandImport/Sources/StrandImport/HealthWriteback.swift`, tests in
`HealthWritebackTests.swift`): `stageIntervals`, `mergedSleepPlan`, `appleHealthVitalKey` /
`appleHealthSleepKey` / `appleHealthWorkoutKey` (`noop:<kind>:<identity>`, no device-id segment since #1503),
`nightIsStillOpen` (20-min margin, 2-h max hold), the #1503 per-type sweep bookkeeping.

Merge rule (`Strand/Health/HealthExportMerge.swift`): imported row wins field-for-field, except a computed
`avgSdnn` is carried across when the import (a CSV, which carries no R-R) has none.

SDNN source (`Packages/StrandAnalytics/.../AnalyticsEngine.swift` ~L803): `avgSdnn` = Task Force **5-min SDNN
index** (`HRVAnalyzer.sdnnIndex(inBed, segmentSec: 300)`), mean of per-5-min-segment SDNN over in-bed R-R of
the physiology sessions; chosen "window-comparable" to Apple Watch's short-window samples because a
whole-night SD "reads 2-3× high". Kotlin twin `HrvAnalyzer.sdnnIndex` (`AnalyticsEngine.kt:680`).

### 1.2 iOS sideload path — `Strand/Data/ShortcutHealthExport.swift` (#155)

Writes `Documents/noop_sync.txt`, one line per epoch-aligned 15-minute window, `HR,HRV,Steps,yyyy-MM-dd
HH:mm` (local time, no header, no trailing newline). `HR` = rounded mean bpm; **`HRV` = RMSSD** over the
window's R-R via `HRVAnalyzer.analyze(rawRR:).rmssd` (nil below 20 clean beats); `Steps` = wrap-corrected
u16 counter deltas (NOT calibrated by `stepTicksPerStep`). Strictly differential (watermark, file truncated
when nothing new, #167) because "the Shortcut has no dedup". The user's own Shortcut does the HealthKit
write. UI copy (`StrandiOS/App/ShortcutExportSettingsView.swift`): "one line per 15 minutes of heart rate,
HRV and steps … The setup guide and the pre-built Shortcut live in the project wiki on GitHub." No such
guide was found (§7: wiki home lists only `FAQ`, which returned HTTP 404). `docs/PRIVACY_SECURITY.md` §1.3
and `DISCLAIMER.md` §5.3 describe the path but not the Health types.

### 1.3 Android — `android/app/src/main/java/com/noop/ingest/HealthConnectWriter.kt`

| Record | Value | Timestamp | Metadata |
|---|---|---|---|
| `RestingHeartRateRecord` | `restingHr` | local **noon** of the day, with zone offset | `Metadata(clientRecordId = "noop-rhr-<day>", clientRecordVersion = write-time epoch s)` |
| `HeartRateVariabilityRmssdRecord` | `avgHrv` (**RMSSD**) | noon | `noop-hrv-<day>` |
| `OxygenSaturationRecord` | `spo2Pct` | noon | `noop-spo2-<day>` |
| `RespiratoryRateRecord` | `respRateBpm` | noon | `noop-resp-<day>` |
| `HeartRateRecord` | series chunks: full-res inside workout/sleep windows, ~1/30 s elsewhere (`HealthExportPlan.heartRate`) | sample times | per-chunk `clientId`, version = write time |
| `SleepSessionRecord` | bridged nights with `Stage`s (`AWAKE / SLEEPING / LIGHT / DEEP / REM`) | session start/end with offsets | `noop-sleep-<startTs>`, version = `endSec`; absorbed/stale ids deleted via ledger (#364, #1677) |
| `Vo2MaxRecord` | weekly `vo2max_est`, `MEASUREMENT_METHOD_OTHER` | noon | `noop-vo2max-<day>` |
| `ExerciseSessionRecord` + `DistanceRecord` | opt-in per workout | start/end | `noop-workout-<startTs>`, `-dist-` |
| Not written | steps, active calories (#528: "would double-count"), skin temperature (`SkinTemperatureRecord` exists in HC; only the *importer* references it), SDNN (no HC type) | | |

Every `Metadata(...)` is the plain constructor with id + version: **no `Device`, no recording method**.
SDK pin: `androidx.health.connect:connect-client:1.1.0-alpha07` (`android/app/build.gradle.kts:293`).

---

## 2. Correct types, units and semantics per Apple's documentation

Quotes are verbatim from the fetched pages (§7). "Agg." = `HKQuantityAggregationStyle`: discrete types
"support average, minimum, and maximum queries. Cumulative types support only sum queries."

| Identifier | Unit / agg. | What Apple says it means (quoted) | NOOP today | Verdict |
|---|---|---|---|---|
| `HKQuantityTypeIdentifier.heartRate` | count/time, discrete | "Heart rate samples may include motion context information, which is stored as metadata using the `HKMetadataKeyHeartRateMotionContext` key." Apple Watch: "If the user has been still for at least 5 minutes prior to the sample, the context is set to the sedentary value." "You can add motion context to the metadata of any heart rate samples that you create." "Sample data may be condensed and/or coalesced by HealthKit." | 1-min interval means, no metadata | OK. Motion context is optional and NOOP has the inputs (`stepSample.activityClass`, gravity) to set `.sedentary`/`.active`. |
| `.restingHeartRate` | count/time, discrete | "It is an estimation of the user's lowest heart rate during periods of rest … the system estimates the resting heart rate by analyzing sedentary heart rate samples throughout the day." "Because the resting heart rate estimates become more accurate as the day progresses, the system may delete earlier samples and replace them with better estimates. Apple Watch replaces only the samples written by the watch for the current or previous day." | One sample at wake | Third parties can share it (NOOP does, successfully). Apple's own value is a *daytime* estimate from sedentary samples, revised through the day; NOOP's is a *sleep* 5-min floor. Same type, different definition — see topic 02; the Health "Resting Heart Rate" chart will mix them if a Watch is also present. |
| `.heartRateVariabilitySDNN` | time (ms), discrete | "HealthKit uses SDNN heart rate variability, which uses the standard deviation of the inter-beat (RR) intervals between normal heartbeats (typically measured in milliseconds). The system automatically records samples on Apple Watch." Support page: "HRV is sampled while you're still, so the number of measurements you see will vary according to your activity level." | 5-min SDNN **index** (mean of windows), one zero-length sample at wake | Statistic matches (short-window SDNN). Shape differs: Apple writes several short-window samples; NOOP writes one nightly mean. See §3 (a). |
| `.heartRateVariabilityRMSSD` | *page carries no description* | Declared `static let heartRateVariabilityRMSSD: HKQuantityTypeIdentifier`, availability "iOS 27.0, iPadOS 27.0, Mac Catalyst 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0". Listed under "Type Properties" (not yet in the "Vital signs" group). | Not written | **New.** Natural home for `avgHrv`. Share-ability for third parties unknown (§8). |
| `.respiratoryRate` | count/time, discrete | "The system automatically records samples on Apple Watch." Support: "View your Heart Rate and Respiratory Rate in relation to your time spent asleep." | One nightly mean at wake | OK as a nightly summary; Apple's are per-sleep samples. |
| `.oxygenSaturation` | percent (0–1), discrete | "Oxygen saturation samples measure the percentage of oxygen in the bloodstream." `HKMetadataKeyBarometricPressure`: "This key takes an HKQuantity value that measures the barometric pressure in units of pressure" (iOS 14). | `spo2Pct/100` — nil for every WHOOP 5.0 strap row, so only imported CSV values are ever written | Unit handling correct. Barometric key is optional and irrelevant (no sensor). |
| `.appleSleepingWristTemperature` | temperature, discrete | "A supported watch measures temperature from both sensors every five seconds overnight during sleep. The watch then aggregates this data to a single `appleSleepingWristTemperature` sample. It corrects this sample for environmental bias and calculates a single value that represents the wrist temperature over the entire night." "Apple Watch records the absolute wrist temperature value; however, Health displays this data as a relative value, based on a person's baseline. Health needs to calculate this baseline, so it won't display the wrist temperature until it has gathered about five nights of data." | Share-denied (`writeDenied`), not read either | The page does **not** say "read-only for third parties"; the exception text is documented in the repo (#1366, on device) and the identical exception for clinical types has an Apple engineer answer "can only be read, they cannot be written" (§7, forum 694311). Treat as read-only. Note Apple's *display* model (deviation from a ~5-night baseline) is exactly NOOP's `skinTempDevC` model — the semantics match, the API door is shut. |
| `.bodyTemperature` | temperature, discrete | "A quantity sample type that measures the user's body temperature." Metadata key `HKMetadataKeyBodyTemperatureSensorLocation`. | Read only | Not a fit for a wrist skin value (~33 °C absolute) nor for a ±0.3 °C deviation; writing either would put a fever-chart-wrong number into "Body Temperature". Recommend against (§3 (c)). |
| `.stepCount` | count, cumulative | "The system automatically records samples on iPhone and Apple Watch." Saving guidance: "For less intensive activity, like daily step counts, samples of an hour or less often work best." Health priority (support 108779): "If multiple sources contribute the same data type, the data source at the top will take priority over others." Default order: manual → "Data from your iPhone, iPad, and Apple Watch" → "Data from apps and Bluetooth devices"; but "New apps or devices that you add are listed at the top automatically, above your iPhone or iPad." | Not written via HealthKit; **is** written via the Shortcut file (raw counter deltas) | Dedup is per source *priority*, not by summing — Health totals do not double count; they pick the top source. #249's "double counting" worry is about the user's perception, not Health's arithmetic. See §3 (d). |
| `.activeEnergyBurned` | energy (kcal), cumulative | "These samples should not include the resting energy burned during the sample's duration." "Workout objects automatically contribute to both the Move and Exercise rings … the Move ring increases by the number of calories in the associated active energy burned samples." | Only inside workouts (one sample spanning the workout) | Correct use. Whole-day `activeKcalEst` is not exported (§3 (e)). |
| `.basalEnergyBurned` | energy, cumulative | "Resting energy is the energy that the user's body burns to maintain its normal, resting state." | Not written | NOOP computes no BMR series; nothing to export. |
| `.vo2Max` | ml/kg/min, discrete | "You can also create and save your own vo2Max samples … use the `HKMetadataKeyVO2MaxTestType` metadata key to specify the type of test." Watch range "14-60 ml/kg/min". | Read only on iOS; Android writes `vo2max_est` | Cross-platform gap (iOS could write with `HKVO2MaxTestType` = predictionNonExercise/… — enum values not fetched, §8). |
| `HKCategoryTypeIdentifier.sleepAnalysis` + `HKCategoryValueSleepAnalysis` | category | "Each sleep analysis sample can have only one value. To track both the amount of time a person spends in bed and the quality and quantity of their sleep, use samples with overlapping times." "One set of samples tracks the amount of time the user spent in bed. Then, you can partition the in-bed time into a more-detailed set of samples … The detailed samples overlap the in-bed sample, but they don't overlap each other." "By comparing the start and end times of these samples, apps can calculate secondary statistics. For example: the amount of time it took for the user to fall asleep, the percentage of sleep time spent in deep sleep, the number of times the user woke while in bed, and the total amount of time spent both in bed and asleep." `sleepAnalysis`: "it's recommended that you use `HKMetadataKeyTimeZone` to store time zone metadata with your sleep sample data." Values: `inBed` (iOS 8), `awake` (iOS 10), `asleep` (deprecated iOS 16), `asleepUnspecified` / `asleepCore` / `asleepDeep` / `asleepREM` (iOS 16). `asleepCore` "corresponds to stage N2 … also includes stage N1"; `asleepDeep` "stage N3". | Exactly this shape (one `inBed` + non-overlapping stage samples incl. `.awake` seams) | Model is right. Missing `HKMetadataKeyTimeZone`. `light → asleepCore` is the documented mapping. |
| `HKWorkout` / `HKWorkoutBuilder` / `HKWorkoutActivityType` | — | Builder: "Incrementally collect samples and events associated with a workout. When the workout ends, call `finishWorkout(completion:)` … For watchOS, use an HKWorkoutSession and an HKLiveWorkoutBuilder instead." `finishWorkout` "returns nil if finishing the workout succeeded but the workout sample is not available because the device is locked." `HKWorkout`: "If a workout has summary information, it also needs a set of associated samples that add up to the summary's total." "adding associated samples leads to some duplication between the workout's properties and these samples." `HKWorkoutSession` availability iOS 17.0 (session is a Watch concept; on iPhone "Collecting heart rate data on iPhone or iPad requires pairing with an external heart rate sensor"). | `HKWorkoutBuilder` on iOS, samples via `addSamples`, `device: .local()` | Correct API. `finishWorkout` returning nil (locked device) is handled (`if let workout`). HR samples are **not** attached to the workout, so Health's workout detail has no HR chart for NOOP workouts (§3 (o)). |
| `HKDevice` | — | "Devices include Apple Watch, iPhone, and any other health or fitness peripherals that produce the sample data stored in HealthKit. Device objects are immutable." `localIdentifier`: "Bluetooth peripherals that store data directly into HealthKit use the peripheral's CoreBluetooth UUID … Device objects with different local identifiers appear as separate devices in the HealthKit Store." `udiDeviceIdentifier`: "The device identifier portion of the US Food and Drug Administration's Unique Device Identifier (UDI)." `HKDevice.local()`: "A device object representing the hardware (iPhone, iPod Touch, or Apple Watch) that is running the app." `HKQuantitySample.init(type:quantity:start:end:device:metadata:)` and `HKCategorySample.init(type:value:start:end:device:metadata:)` exist. Health app: "Users can view the data by type, by app, or by device." | No device on vitals/sleep/HR; `.local()` (the phone) on workouts | Attribution gap (§3 (h)). |
| `HKSource` / `HKSourceRevision` | — | "Sources include apps and devices that save data to the HealthKit store. Currently, HealthKit supports only the direct import of data from Bluetooth LE heart rate monitors. All other devices need a companion app." `HKSourceRevision` "adding information about the source's version, operating system, and product type … When the object is saved to the HealthKit store, HealthKit assigns a new source revision." | Source = the NOOP app, automatic | Nothing to do; source is automatic. |
| `HKMetadataKeyExternalUUID` | string | "This value is independent of the UUID assigned to the object by the HealthKit store … You typically use the UUID from the corresponding data entry on your server. This lets you create multiple copies of that data across multiple devices." | Used as the dedup key | It is an *identity label*, not an upsert mechanism; HealthKit does nothing with it on save. |
| `HKMetadataKeySyncIdentifier` + `HKMetadataKeySyncVersion` (iOS 11) | string + NSNumber | "If you add this key to an object's metadata, you must also add the `HKMetadataKeySyncVersion` key." "When you save an HKObject with a sync identifier, the system looks for any existing objects with the same sync identifier. If it finds a match, the system compares the objects' `HKMetadataKeySyncVersion` values. If the new object has a greater sync version, the system replaces the old object with the new one. If the old object is associated with a workout or part of a correlation, the system also replaces the old object in the workout or correlation." | Not used | **Apple's official upsert**, the exact twin of Health Connect's `clientRecordId`/`clientRecordVersion`. See §3 (g). |
| `HKMetadataKeyWasUserEntered` | bool | "Set this key's value to true if the sample was entered by the user; otherwise, set it to false." | Not set | Set `false` on strap-derived samples; `true` on manual workouts. Low value, no risk. |
| `HKMetadataKeyTimeZone` | string (NSTimeZone name) | "For best results when analyzing sleep samples, it's recommended that you store time zone metadata with your sleep sample data." | Not set | Add to sleep samples (S). |
| `deleteObjects(of:predicate:)` | — | "Your app can delete only those objects that it has previously saved to the HealthKit store." "When deleting multiple objects, if any object cannot be deleted, none of them are deleted." "If your app has been denied permission to share an object's data type, it fails with an errorAuthorizationDenied error." | Used before every write, errors swallowed (`try?`) | A silently failed delete followed by a successful save = a duplicate. Sync identifiers remove this window. |
| `authorizationStatus(for:)` | — | "your app cannot determine whether or not a user has granted permission to read data … If your app is given share permission but not read permission, you see only the data that your app has written to the store." | Relied on for share status | Correct; also why the #2210 read-back works even without read permission (own samples are always readable). |
| Sample duration guidance | — | "you should avoid saving samples that are 24 hours long or longer." "Most sample types have restrictions on duration. If you attempt to save a sample that doesn't meet those restrictions, it fails to save." | Vitals zero-length; sleep ≤ a night; HR 60 s | Fine. A night-spanning vitals sample (§3 (f) option) is well under 24 h. |

---

## 3. Mismatch list (NOOP vs Apple/Google documentation) with impact

Impact is on what the **Health app reader** sees, rated high / medium / low.

**(a) SDNN semantics and timestamp — medium.** The *statistic* is right (short-window SDNN, not whole-night SD)
and the #2264 "no RMSSD under SDNN" rule is right. The *shape* is not Apple's: Apple Watch writes several
discrete SDNN samples per day "while you're still"; NOOP writes one zero-duration sample at the wake instant
carrying the mean of ~60–100 five-minute windows. Consequences: (1) a Health reader averaging SDNN per day gets
NOOP's index — fine; one computing min/max/count gets a degenerate single point; (2) the Health chart shows a
dot at wake time, not a night-time band; (3) if the owner ever also wears a Watch, NOOP's one sample and the
Watch's several are averaged together per day with equal weight per sample, so the Watch dominates. Options:
write each 5-min window's SDNN as its own interval sample (`start/end` = the window), which gives the Health app
the same per-day mean (arithmetic mean of equal windows = the index) and a real night-time distribution; or keep
one sample but span it `[sleep onset, wake]`. Either way the daily average Health computes equals today's. With
the iOS 27 `heartRateVariabilityRMSSD` type, `avgHrv` can additionally be written where readers expect RMSSD —
**without** touching the SDNN series.

**(b) RMSSD leaking into SDNN via the Shortcut path — high for a sideloaded reader.** `noop_sync.txt` column
2 is RMSSD per 15 min, named "HRV" in the file contract, the UI copy and the test file. The only HealthKit HRV
type reachable from Shortcuts before iOS 27 is `heartRateVariabilitySDNN` ("Heart Rate Variability" in Health).
A user following the (missing) guide will log RMSSD under SDNN: a different statistic at a different magnitude,
precisely the mislabel #2264 removed from the HealthKit path. No repository doc names the target type. Fix is
small: emit the window **SDNN** (`HRVAnalyzer` already computes it; `HrvAnalyzer.sdnnIndex` per window) in the
HRV column, or add a fourth column so the Shortcut can choose; and state the Health type in the UI copy and in
`docs/IOS.md`. Note also that the Shortcut path exports **raw counter deltas** as steps, uncalibrated by
`stepTicksPerStep`, and that it exports steps at all while the HealthKit path refuses to (#249) — the two
iOS paths disagree on policy.

**(c) Skin temperature not exported — medium (the owner's illness/cycle signal is invisible in Health).**
Apple's wrist type is share-denied for third parties (repo-verified crash, Apple engineer precedent for the
same exception text). `.bodyTemperature` is semantically wrong for both the absolute wrist value and the
deviation. There is no correct HealthKit destination; the honest position is "not exportable on iOS", stated in
the UI. On Android, Health Connect's `SkinTemperatureRecord` is a precise fit: `deltas` ("If `baseline` is set,
these values are expected to be relative to it"), optional `baseline` ("Valid range: 0-100 Celsius degrees"),
`Delta.delta` "Valid range: -30 to 30 Celsius degrees", `MEASUREMENT_LOCATION_WRIST = 3`, feature-gated by
`HealthConnectFeatures.FEATURE_SKIN_TEMPERATURE`. NOOP's `skinTempDevC` (delta) + `skinTempC`/EWMA baseline
map onto it directly — a real parity item (§6 item 7).

**(d) Steps not exported (HealthKit) — low/medium.** Apple's dedup is by **source priority**, not summation:
"the data source at the top will take priority over others". So a NOOP step source cannot double count in the
Health *totals*; what it can do is **outrank the iPhone by default** ("New apps or devices that you add are
listed at the top automatically, above your iPhone or iPad"), which for a phone-in-pocket owner without a Watch
may even be desirable, and for a Watch owner is a surprise. Export should be opt-in, hourly cumulative samples
("samples of an hour or less often work best"), and only once the step estimate is validated (topic 09). Health
Connect: `StepsRecord` "Captures the number of steps taken since the last reading. Each step is only reported
once so records shouldn't have overlapping time"; count "Valid range: 1-1000000"; Activity and Sleep types are
the ones Health Connect dedups by user priority ("Only the Activity and Sleep data types are deduped by Health
Connect"). Google's write guidance also forbids zero rows: "Only write zero values when it reflects true
inactivity while the user was wearing the device."

**(e) Active energy only inside workouts — low.** Correct per Apple (workout kcal belongs in attached
`activeEnergyBurned` samples; "the Move ring increases by the number of calories in the associated active energy
burned samples"). The whole-day `activeKcalEst` (HR-only) has no validation behind it (topic 05); exporting it
would make NOOP the top Active Energy source by default and move the Move ring. Leave out until validated;
if ever written, as ≤1-h cumulative samples excluding workout spans (which are already attached), never as one
24-h sample ("avoid saving samples that are 24 hours long or longer").

**(f) Nightly vitals as single zero-duration samples at wake — low (iOS) / medium (cross-platform).** Apple
documents no required shape for third-party RHR/resp samples; Google's write guidance explicitly expects
"RestingHeartRate … Single daily value (expected first thing in the morning)" and the same for
OxygenSaturation. So wake-time is the right instant and iOS already does it; **Android stamps noon**, which
contradicts Google's own guidance and makes the two platforms disagree on when the "same" nightly value
happened. For respiratory rate and SDNN, an interval `[sleep onset, wake]` (or per-window samples, (a)) would
tell a reader *which* night the value describes instead of relying on the wake stamp.

**(g) Dedup by ExternalUUID + delete-then-save vs SyncIdentifier/SyncVersion — medium (robustness).**
`HKMetadataKeyExternalUUID` is a label HealthKit ignores on save; the dedup is a two-step client protocol whose
first step's failure is swallowed. Apple's `HKMetadataKeySyncIdentifier` + `SyncVersion` is an atomic
server-side upsert ("the system replaces the old object with the new one … If the old object is associated with
a workout or part of a correlation, the system also replaces the old object in the workout or correlation"),
i.e. exactly Health Connect's `clientRecordId` + `clientRecordVersion` ("Data with the highest
`clientRecordVersion` takes precedence. `clientRecordVersion` starts with 0"). Adopting it makes iOS and Android
structurally identical, removes the delete window, and — for workouts — replaces the workout *and* its attached
samples in one operation, which is the very assumption #2210 flags as unverified for the delete path. Caveats:
a save with an **equal or lower** version is ignored (Health Connect: "Otherwise, the process ignores the
change"), so the version must strictly increase whenever content changes (write-time epoch seconds, as Android
does, or `endTs` for sleep as Android does — note Android's sleep version = `endSec` cannot move when only the
*stages* change for the same wake; write-time is safer); and existing ExternalUUID-only samples need one
migration sweep (delete by `predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues:)`,
which already exists), the same pattern as #1503.

**(h) No `HKDevice` — low/medium (attribution; "view by device").** Vitals, sleep and HR carry no device;
workouts say the iPhone made them (`.local()`). Apple's model wants the peripheral: `localIdentifier` = "the
peripheral's CoreBluetooth UUID" (NOOP has it), `name`/`manufacturer`/`model`/`hardwareVersion`/
`firmwareVersion` as strings (NOOP's registry has model and firmware), `udiDeviceIdentifier` nil (not a
registered medical device; Google says the same: "only populate the UDI-DI portion" and only for medical
devices). A device object changes nothing about dedup. Policy check for maintainers: naming the manufacturer in
a string is a fact about hardware the user owns, not an asset; `AGENTS.md` bars logos/assets, not facts.

**(i) `inBed` + stage overlap convention — none (correct).** NOOP's shape is Apple's. Two refinements: add
`HKMetadataKeyTimeZone` (recommended by Apple for sleep); and consider whether HR-only nights
(`sleepHrOnly`, sparse 5.0 motion, #345) should export `.asleepUnspecified` rather than a full hypnogram, since
Health will render those stages with the same authority as a Watch's. A default-off "export stages for HR-only
nights" toggle keeps the hypnogram for people who want it (brief rule 8, no medical claims).

**(j) Respiratory rate per night — low.** Same as (f). WHOOP 5.0 has no respiration channel; the value is RSA
from sparse R-R (`SleepStager.respRateFromRR`), gated by `beatAccurateFraction`. When the gate refuses, nothing
is written — good. If per-window values exist later, Google's expected cadence is "every 1 minute"; Apple
documents none.

**(k) Android RMSSD vs iOS SDNN — none (both correct), but undocumented.** Health Connect has
`HeartRateVariabilityRmssdRecord` ("root mean square of successive differences (RMSSD) between normal
heartbeats", "Valid Range: 1-200" ms) and no SDNN record; HealthKit has SDNN (all versions) and RMSSD (iOS 27).
So: Android writes `avgHrv`; iOS writes `avgSdnn` and, on iOS 27+, could add `avgHrv` under the RMSSD type.
`docs/CROSS_PLATFORM.md` should say this in one line, because the parity contract otherwise reads "byte-identical
stored data" and a reviewer will flag the divergence.

**(l) Android timestamps at noon vs iOS at wake — medium.** See (f). Align Android to the wake instant
(`HealthExportPlan` has the sessions) with the zone offset at that instant.

**(m) Android `Metadata` without `Device`/recording method — high at the next SDK bump.** Google: "As of
version 1.1.0-rc01, RecordingMethod and DeviceType are mandatory"; the metadata guide: "Metadata can no longer be
directly instantiated, so use one of the factory methods … The factory methods verify that device information is
provided when a device or sensor was used to record the data", and `RECORDING_METHOD_AUTOMATICALLY_RECORDED`
"device() must be specified". At `1.1.0-alpha07` the plain constructor still compiles; the port is
`Metadata.autoRecorded(device = Device(type = Device.TYPE_FITNESS_BAND, manufacturer = …, model = …),
clientRecordId = …, clientRecordVersion = …)` for strap data and `Metadata.manualEntry(...)` for manual workouts.
`TYPE_FITNESS_BAND = 6` is the honest type for a screenless strap (`TYPE_WATCH = 1`, `TYPE_CHEST_STRAP = 7`).

**(n) Heart-rate samples: no motion context, range delete — low.** Optional `HKMetadataKeyHeartRateMotionContext`
(`.sedentary` = "still for at least 5 minutes prior") would let Apple's own RHR estimator and third-party
readers treat NOOP's night HR as sedentary. The 48-h range delete is cheap and correct for an instantaneous
type; it would also delete any HR samples attached to NOOP workouts if (o) is adopted, so (o) must exclude
attached samples from the range or key them.

**(o) Workouts carry no HR — medium for the Health workout page.** Health's per-workout detail draws HR from
samples *associated* with the workout ("You can associate any number of samples with a workout … heart rate,
energy burned, distance traveled"). NOOP's HR stream is written separately, so a NOOP workout shows energy and
distance but no HR curve. Attaching the window's 1-min buckets via `builder.addSamples` fixes that; then the
separate stream must skip workout spans (or Health shows both — the stream and the attached copy — as two
NOOP samples per minute).

**(p) SpO₂ — none.** `spo2Pct` is nil for every WHOOP 5.0 computed row, so nothing is written for the owner;
only WHOOP-CSV-imported SpO₂ is ever exported, which is the WHOOP app's number, not NOOP's.

**(q) Source priority side effect — informational.** On first write-back NOOP becomes the top-priority source
for RHR, HRV, respiratory rate and sleep ("New apps or devices that you add are listed at the top
automatically"). For a Watch owner this silently changes the headline numbers in Health. Worth one sentence in
the Apple Health screen.

---

## 4. Which exports are impossible or partial on WHOOP 5.0 data

| Export | Status on a 5.0 bonded to NOOP | Reason (from `docs/research/00-inventory.md` §1) | Graceful behaviour today |
|---|---|---|---|
| SpO₂ (`.oxygenSaturation`) | **Impossible** | Time-multiplexed optical; `spo2Pct` nil; `spo2_candidate_82` diagnostic-only | Nothing written (correct). |
| Skin temperature | **No HealthKit destination** (and firmware-dependent input) | `.appleSleepingWristTemperature` share-denied; byte-73 "not consistent across firmware" | Not written; Health Connect could carry it (§3 (c)). |
| HRV SDNN | **Partial**: nights without enough beat-accurate R-R export nothing | ≤ 4 R-R words/s, filler beats, `beatAccurateFraction` gate | `avgSdnn` nil → sample retracted (#2264). Correct. |
| HRV RMSSD | **Partial**, and no type before iOS 27 | same | Not written on iOS; Shortcut path writes window RMSSD even for thin windows (≥ 20 beats) — 15-min windows on sparse R-R are the least reliable HRV NOOP produces (topic 01's 30-beat floor). |
| Respiratory rate | **Partial** (RSA from sparse R-R; 4.0's respiration channel is absent on 5.0) | `respSample` WHOOP 4.0 only | nil → nothing written. Correct. |
| Sleep stages | **Partial honesty**: HR-only nights still export a full hypnogram | gravity sparse → `hrOnly` / `sleepHrOnly`; #345 | Stages written regardless (§3 (i)). |
| Resting HR | Available | HR with PPG filler | Written. Definition differs from Apple's daytime estimate (topic 02). |
| Steps | Available but uncalibrated | u16 tick counter, per-user `stepTicksPerStep` | HealthKit: not written. Shortcut: raw deltas written. |
| Active energy (day) | Available, unvalidated | HR-only estimate | Not written (workout kcal only). |
| VO₂ max | Available (weekly estimator) | — | iOS not written; Android written. |
| Workout HR | Available | — | Not attached to the workout (§3 (o)). |

---

## 5. How to verify writes on a device

HealthKit has no unit-test seam (`HealthWriteback` exists precisely so the *plan* is tested without it), and
the repo notes the bridge is "unverifiable off-device" (`HealthKitBridge.swift` ~L333). The checks below are
what a PR touching the writer should report, in `AGENTS.md`'s "show your verification" spirit.

1. **Health app inspection (Apple's own suggestion).** "you can also use the Health app to view the data your
   app is saving to the HealthKit store. This can be particularly useful during early testing, to verify that
   your app is saving everything as expected." Browse → Heart → Heart Rate Variability → *Show All Data*: each
   row shows its source (NOOP) and, with (h) done, its device. Expect **one** row per night for SDNN/RHR/resp,
   stamped at wake. Sleep → *Show All Data*: one In Bed row per bridged night plus stage rows that partition it;
   Health's "Time Asleep" for the night must equal the sum of the `asleep*` rows and "In Bed" the `inBed` span.
   Browse → … → **Data Sources & Access** shows where NOOP sits in the priority list (§3 (q)).
2. **Read-back test inside NOOP (Test Centre, gated).** An `HKSampleQuery` per written type with
   `HKQuery.predicateForObjects(from: HKSource.default())` ∧ the day's date range, grouped by
   `HKMetadataKeyExternalUUID` (or sync identifier): assert count == 1 per key, value equals the `DailyMetric`
   field to the unit's precision, `startDate` equals the wake instant, `device?.localIdentifier` equals the
   strap's CB UUID once (h) lands. This works **without read permission** ("If your app is given share permission
   but not read permission, you see only the data that your app has written") — the same fact #2210 relies on.
3. **Duplicate check after re-sync.** Run `sync` twice (foreground, then background wake), and once after a
   strap offload that back-fills a night; re-run (2). With the current delete-then-save, also force a failing
   delete (revoke share for one type in Settings mid-run) and confirm no duplicate appears — this is the
   window §3 (g) closes.
4. **Export-file audit.** Health → profile → *Export All Health Data*; the macOS `AppleHealthImporter` already
   stream-parses `export.xml`. A short `Tools/` script counting `<Record type="…" sourceName="NOOP" …>` per
   `(type, day)` gives the duplicate census for the whole history and is how a field reporter can show a bug
   without a debugger (`docs/VALIDATION_PROTOCOL.md` R3: numbers ship with their regenerating command).
5. **Statistics sanity.** `HKStatisticsQuery(.discreteAverage)` over a day for SDNN with
   `.separateBySource` ("calculates the specified statistics separately for each source") must return NOOP's
   index for the NOOP source — and with per-window samples (§3 (a) option) must return the *same* number as the
   single-sample design did.
6. **Workout page.** Open the NOOP workout in Health/Fitness: energy and distance present; with (o), an HR chart.
   Delete the workout in NOOP, re-sync, confirm the Health copy and its attached samples are gone (this is the
   unverified #2210 assumption; with sync identifiers it is Apple-documented behaviour).
7. **Shortcut path.** Run the Shortcut on a known `noop_sync.txt`; in Health → Heart Rate Variability → Show All
   Data confirm the source is *Shortcuts* and the values match column 2 — and that column 2 is the statistic the
   type expects (SDNN) after §6 item 4.
8. **Android.** Health Connect app → Data and access → NOOP: per-type record counts; re-run the exporter and
   confirm counts do not grow (upsert); after the SDK bump (§6 item 8) confirm the app name *and* device appear
   under each record's details.

---

## 6. Implementation sketch (effort S/M/L, risk)

Ordered by value to a Health-first WHOOP 5.0 owner.

1. **RMSSD on iOS 27 (`.heartRateVariabilityRMSSD`) — M, risk: share may be Apple-only.**
   - Probe first, never ship blind: the share request for a disallowed type is an uncatchable ObjC exception
     (#1366). Add the id to a `probeShareIds` list that is requested **only** from a Test Centre button on a
     device running `#available(iOS 27, *)`, after writing a UserDefaults "probe armed" flag so a crash on launch
     cannot repeat (clear the flag on success). If the request returns, promote the id into
     `highResQuantityWriteIds` behind `#available`; if it throws the exception, add it to `writeDenied` and
     document.
   - Write `avgHrv` with the same key scheme (`noop:HKQuantityTypeIdentifierHeartRateVariabilityRMSSD:<day>`),
     same wake stamp (or window shape, item 2), `.secondUnit(with: .milli)`. Unit for the new type is not
     documented (§8); assume ms like SDNN and verify by read-back.
   - Keep the SDNN series untouched; never fall back across the two types.
2. **Nightly vitals shape — S.** Option A: span the SDNN/resp sample `[onset, wake]` (one line each in
   `writeVitals`). Option B (preferred for SDNN): one sample per 5-min window from `HRVAnalyzer.sdnnIndex`'s
   segmentation (expose the per-window list), keyed `noop:<type>:<windowStartTs>`, which needs the sync-id
   scheme (item 3) to stay cheap. Oracle-test the Health-side mean equals `avgSdnn` (equal windows ⇒ equal).
3. **Sync identifiers — M.** Replace `HKMetadataKeyExternalUUID` with `HKMetadataKeySyncIdentifier` (same
   string) + `HKMetadataKeySyncVersion` (write-time epoch seconds, as Android) on vitals, sleep, workouts; drop
   the pre-save `deleteObjects` for those; keep a one-off sweep deleting our ExternalUUID-keyed samples (same
   per-type bookkeeping as #1503). Keep the HR range delete (no keys at that volume) or key HR per bucket if (o)
   is done. Keep the retraction path (`retract(...)`) as an explicit delete — sync ids replace, they do not remove.
4. **Shortcut path correctness — S.** Change column 2 to window **SDNN** (or add a column), rename the field
   in the file contract/tests, and write the Health type names into the UI copy and `docs/IOS.md` ("Heart Rate
   Variability = SDNN"; on iOS 27 "Heart Rate Variability (RMSSD)" if Shortcuts exposes it — §8). Calibrate
   steps with `stepTicksPerStep` or drop the column until topic 09 lands. Create the wiki/doc page the UI
   promises, or point the copy at `docs/IOS.md`.
5. **`HKDevice` + metadata — S.** Build one `HKDevice(name: "<registry model label>", manufacturer: "WHOOP",
   model: "<family>", hardwareVersion: nil, firmwareVersion: "<registry firmware>", softwareVersion: NOOP version,
   localIdentifier: "<CB peripheral UUID>", udiDeviceIdentifier: nil)` per active strap (resolve through
   `DeviceFamily.forRegistryModel`, never a string compare, per `AGENTS.md`), pass it to every sample init and
   to `HKWorkoutBuilder(device:)`; add `HKMetadataKeyTimeZone` to sleep samples and `HKMetadataKeyWasUserEntered`
   (`false`, `true` for manual workouts). Maintainer sign-off on the manufacturer string.
6. **Workout HR attachment — M.** In `writeWorkouts`, `addSamples` the 1-min buckets inside `[start, end]`
   (same `repo.hrBuckets`), and make `writeHeartRate` skip spans covered by exported workouts; or accept the
   duplicate and document. Test: Health workout page shows HR; read-back per minute finds one NOOP sample.
7. **Android skin temperature — M.** `SkinTemperatureRecord(startTime = onset, endTime = wake, deltas =
   [Delta(time = wake, delta = TemperatureDelta.celsius(skinTempDevC))], baseline =
   Temperature.celsius(skinTempC - skinTempDevC) when both exist, measurementLocation =
   MEASUREMENT_LOCATION_WRIST)`, gated on `FEATURE_SKIN_TEMPERATURE`, own permission + own insert attempt (the
   #1525 pattern), `clientRecordId = "noop-skintemp-<day>"`. On iOS, state in the Apple Health screen that wrist
   temperature cannot be written by third parties.
8. **Android metadata/device + timestamps — S (bump) / M (with SDK upgrade).** Switch to
   `Metadata.autoRecorded(device = Device(type = TYPE_FITNESS_BAND, manufacturer, model), clientRecordId,
   clientRecordVersion)` everywhere, `manualEntry` for manual workouts; move the daily records from noon to the
   wake instant (offset at that instant). Do it before the `connect-client` bump that makes it mandatory.
9. **Steps / daily active energy (both platforms) — S each, gated on topics 05/09.** Default-off toggles,
   hourly cumulative samples / `StepsRecord` per hour with non-overlapping intervals, never zero rows, with the
   "this will become your top-priority source" sentence in the UI.
10. **Docs — S.** `docs/CROSS_PLATFORM.md`: one table row "HRV export: iOS SDNN (+RMSSD on iOS 27), Android
    RMSSD; timestamps = wake instant on both". `docs/IOS.md` HealthKit section: list the exact types written and
    the three that cannot be (wrist temperature, SpO₂ on 5.0, steps by policy).

Risk notes: items 1 and 3 touch authorization and dedup — the two places a bug produces duplicates or a launch
crash in the user's Health store, which NOOP "cannot read back, manage, or delete" once the user revokes access
(`docs/PRIVACY_SECURITY.md` §1.3). Both must be verified per §5 on a device before merge; CI cannot see them.

---

## 7. Sources (fetched this session)

Apple developer documentation (human URL; fetched via the `/tutorials/data/documentation/healthkit/….json`
endpoint that backs each page, 2026-11-10):

- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier — index; lists both
  `heartRateVariabilitySDNN` (Vital signs) and `heartRateVariabilityRMSSD` (Type Properties).
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilityrmssd —
  declaration + availability iOS 27.0 / watchOS 27.0; no description text.
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn — SDNN
  definition, ms, "The system automatically records samples on Apple Watch."
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/restingheartrate — RHR estimate
  from sedentary samples, watch replaces its own samples for current/previous day.
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartrate — motion-context
  metadata; https://developer.apple.com/documentation/healthkit/hkmetadatakeyheartratemotioncontext;
  https://developer.apple.com/documentation/healthkit/hkheartratemotioncontext/sedentary.
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/respiratoryrate
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/oxygensaturation;
  https://developer.apple.com/documentation/healthkit/hkmetadatakeybarometricpressure
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature —
  5-s sampling, one nightly sample, relative display after ~5 nights.
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/bodytemperature
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/stepcount
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/activeenergyburned;
  https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/basalenergyburned
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/vo2max;
  https://developer.apple.com/documentation/healthkit/hkmetadatakeyvo2maxtesttype
- https://developer.apple.com/documentation/healthkit/hkcategorytypeidentifier/sleepanalysis — time-zone
  recommendation.
- https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis — overlap rules; and the
  cases `/inbed`, `/asleep` (deprecated iOS 16), `/awake`, `/asleepunspecified`, `/asleepcore` (N1+N2),
  `/asleepdeep` (N3), `/asleeprem`.
- https://developer.apple.com/documentation/healthkit/hkcategorysample — "Samples with different values may have
  overlapping time intervals."
- https://developer.apple.com/documentation/healthkit/hkworkout — associated samples, rings;
  https://developer.apple.com/documentation/healthkit/hkworkoutbuilder;
  https://developer.apple.com/documentation/healthkit/hkworkoutbuilder/init(healthstore:configuration:device:);
  https://developer.apple.com/documentation/healthkit/hkworkoutbuilder/add(_:completion:);
  https://developer.apple.com/documentation/healthkit/hkworkoutbuilder/addmetadata(_:completion:);
  https://developer.apple.com/documentation/healthkit/hkworkoutbuilder/finishworkout(completion:);
  https://developer.apple.com/documentation/healthkit/hkworkoutsession (iOS 17 availability);
  https://developer.apple.com/documentation/healthkit/adding-samples-to-a-workout;
  https://developer.apple.com/documentation/healthkit/accessing-condensed-workout-samples.
- https://developer.apple.com/documentation/healthkit/hkdevice and its properties `/name`, `/manufacturer`,
  `/model`, `/hardwareversion`, `/firmwareversion`, `/softwareversion`, `/localidentifier`,
  `/udideviceidentifier`, `/local()`; https://developer.apple.com/documentation/healthkit/hkobject/device;
  https://developer.apple.com/documentation/healthkit/hkquantitysample/init(type:quantity:start:end:device:metadata:).
- https://developer.apple.com/documentation/healthkit/hksource;
  https://developer.apple.com/documentation/healthkit/hksourcerevision.
- https://developer.apple.com/documentation/healthkit/hkmetadatakeyexternaluuid;
  https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier;
  https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncversion;
  https://developer.apple.com/documentation/healthkit/hkmetadatakeywasuserentered;
  https://developer.apple.com/documentation/healthkit/hkmetadatakeytimezone.
- https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization(toshare:read:completion:);
  https://developer.apple.com/documentation/healthkit/hkhealthstore/authorizationstatus(for:);
  https://developer.apple.com/documentation/healthkit/hkhealthstore/deleteobjects(of:predicate:withcompletion:);
  https://developer.apple.com/documentation/healthkit/hkobjecttype/requiresperobjectauthorization();
  https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data.
- https://developer.apple.com/documentation/healthkit/saving-data-to-healthkit — sample-duration guidance,
  "view the data by type, by app, or by device".
- https://developer.apple.com/documentation/healthkit/hkstatisticsquery;
  https://developer.apple.com/documentation/healthkit/hkstatisticsoptions/separatebysource;
  https://developer.apple.com/documentation/healthkit/hkquantityaggregationstyle (+ `/discretearithmetic`,
  `/discretetemporallyweighted`); https://developer.apple.com/documentation/healthkit/executing-statistical-queries;
  https://developer.apple.com/documentation/healthkit/hksamplequery.
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/appleexercisetime (context only).

Apple support and forums:

- https://support.apple.com/en-us/108779 "Manage Health data on your iPhone, iPad, or Apple Watch" — source
  priority order and the "Data Sources & Access" procedure (quoted in §2/§3).
- https://support.apple.com/en-us/120277 — Apple Watch heart rate page: "HRV is sampled while you're still";
  "Recovery HRV" on Apple Watch Series 12 / Ultra 4.
- https://support.apple.com/en-us/108906 "Track your sleep on Apple Watch and use Sleep on iPhone" — stages
  "Awake or in REM, Core, or Deep sleep", "Sleep Goal and Time Asleep", respiratory rate "in relation to your
  time spent asleep", wrist temperature on Series 8+/Ultra.
- https://developer.apple.com/forums/thread/694311 — the identical "Authorization to share the following types is
  disallowed" exception for `HKClinicalTypeIdentifierImmunizationRecord`, Apple engineer: "Clinical records can
  only be read, they cannot be written."

Android / Health Connect (developer.android.com, fetched 2026-11-10):

- https://developer.android.com/reference/androidx/health/connect/client/records/HeartRateVariabilityRmssdRecord
- https://developer.android.com/reference/androidx/health/connect/client/records/SkinTemperatureRecord and
  https://developer.android.com/reference/androidx/health/connect/client/records/SkinTemperatureRecord.Delta
- https://developer.android.com/reference/androidx/health/connect/client/records/SleepSessionRecord
- https://developer.android.com/reference/androidx/health/connect/client/records/RestingHeartRateRecord
- https://developer.android.com/reference/androidx/health/connect/client/records/RespiratoryRateRecord
- https://developer.android.com/reference/androidx/health/connect/client/records/StepsRecord
- https://developer.android.com/reference/androidx/health/connect/client/records/ActiveCaloriesBurnedRecord
- https://developer.android.com/reference/androidx/health/connect/client/records/HeartRateRecord
- https://developer.android.com/reference/androidx/health/connect/client/records/metadata/Metadata
- https://developer.android.com/reference/androidx/health/connect/client/records/metadata/Device
- https://developer.android.com/health-and-fitness/guides/health-connect/develop/write-data — upsert semantics,
  write cadence table (RHR/SpO₂ "Single daily value (expected first thing in the morning)"), zero-value rule,
  "As of version 1.1.0-rc01, RecordingMethod and DeviceType are mandatory".
- https://developer.android.com/health-and-fitness/health-connect/metadata — mandatory recording method and
  device type from 1.1.0-alpha12; UDI-DI only.
- https://developer.android.com/health-and-fitness/guides/health-connect/develop/aggregate-data — priority-based
  dedup for Activity and Sleep only.
- https://support.google.com/android/answer/12990553 — "the data from the app higher on the list will be given
  priority".

Other:

- https://github.com/ryanbr/noop/wiki — only `FAQ` is linked; https://github.com/ryanbr/noop/wiki/FAQ returned
  HTTP 404. No Shortcut setup guide exists at the location the UI names.
- https://matthewcassinelli.com/actions/log-health-sample/ (third-party) — the Shortcuts action "Adds a data point
  into the Health app", parameters Type and Date; the page lists no types.

Repository files read: `RESEARCH_BRIEF.md`, `docs/research/00-inventory.md` (§0, §1, §2.1, §2.8, §2.10),
`DISCLAIMER.md` §5.3, `docs/PRIVACY_SECURITY.md` §1.3, `docs/IOS.md` (HealthKit section), `docs/FEATURES.md`,
`StrandiOS/Health/HealthKitBridge.swift`, `Packages/StrandImport/Sources/StrandImport/HealthWriteback.swift`,
`Strand/Health/HealthExportMerge.swift`, `Strand/Data/ShortcutHealthExport.swift`,
`StrandTests/ShortcutHealthExportTests.swift`, `StrandiOS/App/ShortcutExportSettingsView.swift`,
`Strand/Screens/AppleHealthView.swift` (strings), `Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift`,
`Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift` (SDNN index),
`android/app/src/main/java/com/noop/ingest/HealthConnectWriter.kt`, `HealthExportPlan.kt` (greps),
`HealthConnectImporter.kt` (L822–835), `android/app/build.gradle.kts` (SDK pin).

---

## 8. Unverified leads (not relied on above)

- **Whether third parties may share `heartRateVariabilityRMSSD`.** Apple's page has no description, no
  "system automatically records" sentence and no read-only note. The "Recovery HRV" feature on Series 12/Ultra 4
  (support 120277) is the likely producer; if it is Apple-reserved like wrist temperature, a share request will
  raise the #1366 exception. Device probe required (§6 item 1). Its unit is also undocumented (assumed ms).
- **`.appleSleepingWristTemperature` is read-only for third parties.** Not stated on Apple's page; inferred from
  the repo's on-device crash (#1366) and the engineer answer for clinical types on an identical exception.
- **How the Health app's HRV chart aggregates** (daily mean of samples vs. latest). Apple documents that discrete
  types "support average, minimum, and maximum queries"; the Health *UI*'s choice is not documented. Verify in §5
  step 1 by comparing the chart's daily figure with the read-back mean.
- **"Time Asleep" / "In Bed" arithmetic in the Health app.** The developer page says apps *can* compute totals
  from the overlapping samples; the support page names "Time Asleep" but not "Time in Bed"; the Health app's exact
  handling of a night where stage samples do not cover the whole `inBed` span was not found.
- **Shortcuts "Log Health Sample" type list** (whether it exposes "Heart Rate Variability" and, on iOS 27, an
  RMSSD entry). No Apple page was found; the third-party page lists only Type/Date. Must be checked in the
  Shortcuts app on the owner's phone.
- **Deleting an `HKWorkout` deletes samples added through `HKWorkoutBuilder`** (#2210's open assumption). No
  Apple page fetched states it; the sync-identifier page does document replacement of associated samples on
  *replace*, which is the recommended route around the question.
- **`HKBodyTemperatureSensorLocation` enumeration** (whether a wrist location exists). Not fetched; would not
  change the recommendation against writing skin temperature as body temperature.
- **`HKVO2MaxTestType` values** for an iOS VO₂ max write-back; not fetched.
- **Apple developer forum thread 764078** (search snippet only: an Apple DTS reply that Apple Watch collects
  `.respiratoryRate` and `.appleSleepingWristTemperature` only during sleep). Not fetched; consistent with
  support 108906.
- **Apple Watch user guide "Track your sleep" (apd830528336)** — the fetch returned the sleep-schedule setup
  page, not the stage description; support 108906 was used instead.
- **Health Connect `SkinTemperatureRecord` availability on the user's device** — feature-gated by
  `FEATURE_SKIN_TEMPERATURE`; which Health Connect module versions ship it was not fetched.
