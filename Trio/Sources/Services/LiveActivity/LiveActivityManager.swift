import ActivityKit
import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import WidgetKit

@available(iOS 16.2, *) private struct ActiveActivity {
    let activity: Activity<LiveActivityAttributes>

    /// Determines if the current activity needs to be recreated.
    ///
    /// - Returns: `true` if the activity is dismissed, ended, stale, or has been active for more than 60 minutes; otherwise,
    /// `false`.
    func needsRecreation() -> Bool {
        switch activity.activityState {
        case .dismissed,
             .ended,
             .stale:
            return true
        case .active:
            break
        @unknown default:
            return true
        }
        return -activity.attributes.startDate.timeIntervalSinceNow > TimeInterval(60 * 60)
    }
}

final class LiveActivityData: ObservableObject {
    /// Determination data used to update live activity state.
    @Published var determination: DeterminationData?
    /// The most recent IoB data
    @Published var iob: Decimal?
    /// Array of glucose readings fetched from persistent storage.
    @Published var glucoseFromPersistence: [GlucoseData]?
    /// The current override data (if any).
    @Published var override: OverrideData?
    /// The current temp target data (if any).
    @Published var tempTarget: TempTargetData?
    /// The widget items displayed within the live activity.
    @Published var widgetItems: [LiveActivityAttributes.LiveActivityItem]?
}

/// A service managing live activity updates and state management.
///
/// This class handles the creation, update, and termination of live activities based on various data sources
/// (e.g. Core Data notifications, glucose updates, settings changes). It integrates with system notifications,
/// dependency injection, and user defaults to ensure that the live activity reflects the current app state.
///
/// Additionally, it supports a restart functionality (via `restartActivityFromLiveActivityIntent()`)
/// via iOS shortcuts, similar to other iOS apps like xDrip4iOS or Sweet Dreams.
@available(iOS 16.2, *) final class LiveActivityManager: Injectable, ObservableObject, SettingsObserver {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var storage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var iobService: IOBService!

    private let activityAuthorizationInfo = ActivityAuthorizationInfo()
    /// Indicates whether system live activities are enabled.
    @Published private(set) var systemEnabled: Bool

    /// Returns the current Trio settings.
    private var settings: TrioSettings {
        settingsManager.settings
    }

    /// The current active live activity.
    private var currentActivity: ActiveActivity?

    private var data = LiveActivityData()

    // Read-only Home Screen widget snapshot state; never used for pump commands.
    private var lastHomeWidgetReload: Date = .distantPast
    private var lastHomeWidgetGlucoseDate: Date?

    /// A dispatch queue for handling Core Data change notifications.
    private let queue = DispatchQueue(label: "LiveActivityBridge.queue", qos: .userInitiated)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Initializes a new instance of `LiveActivityBridge` and sets up observers, subscribers, and notifications.
    ///
    /// - Parameter resolver: The dependency injection resolver.
    init(resolver: Resolver) {
        coreDataPublisher =
            CoreDataStack.shared.entityChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        systemEnabled = activityAuthorizationInfo.areActivitiesEnabled
        injectServices(resolver)
        setupNotifications()
        registerHandler()
        monitorForLiveActivityAuthorizationChanges()
        broadcaster.register(SettingsObserver.self, observer: self)
        data.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                // by the time this runs, the object change is done, so we see the new data here
                await self?.pushCurrentContent()
            }
        }.store(in: &subscriptions)
        loadInitialData()
    }

    /// Sets up application notifications that trigger live activity updates when the app state changes.
    private func setupNotifications() {
        let notificationCenter = Foundation.NotificationCenter.default
        notificationCenter
            .addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    // Final reload on backgrounding is the recommended best-effort
                    // refresh when WidgetKit throttles frequent foreground updates.
                    await self?.pushCurrentContent(forceWidgetReload: true)
                }
            }
        notificationCenter
            .addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    // The glucose cache can lag while Trio was suspended.
                    // Re-read Core Data before publishing the widget state.
                    await self?.loadGlucose(forceWidgetReload: true)
                }
            }
        notificationCenter.addObserver(
            self,
            selector: #selector(loadWidgetItems),
            name: .liveActivityOrderDidChange,
            object: nil
        )
    }

    /// Called when the app settings change.
    ///
    /// This method triggers an update to the live activity content state based on the new settings.
    /// - Parameter _: The updated `TrioSettings`.
    func settingsDidChange(_: TrioSettings) {
        Task { @MainActor in
            await self.pushCurrentContent()
        }
    }

    /// Registers handlers for Core Data changes related to overrides, glucose readings, and determinations.
    private func registerHandler() {
        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { [weak self] _ in
            Task { await self?.loadOverrides() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { [weak self] _ in
            Task { await self?.loadTempTarget() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            Task { await self?.loadGlucose() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OrefDetermination")
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                Task { await self?.loadDetermination() }
            }.store(in: &subscriptions)

        iobService.iobPublisher
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                self?.data.iob = self?.iobService.currentIOB
            }.store(in: &subscriptions)
    }

    /// Fetches and maps new determination data and updates the live activity content state.
    private func loadDetermination() async {
        do {
            data.determination = try await fetchAndMapDetermination()
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map determination: \(error)"
            )
        }
    }

    /// Fetches and maps override data and updates the live activity content state.
    private func loadOverrides() async {
        do {
            data.override = try await fetchAndMapOverride()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map override: \(error)")
        }
    }

    /// Fetches and maps temp target data and updates the live activity content state.
    private func loadTempTarget() async {
        do {
            data.tempTarget = try await fetchAndMapTempTarget()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map temp target: \(error)")
        }
    }

    /// Handles changes to the live activity order.
    ///
    /// Loads widget items from user defaults and triggers an update to the live activity order.
    @objc private func loadWidgetItems() {
        data.widgetItems = UserDefaults.standard.loadLiveActivityOrderFromUserDefaults() ?? LiveActivityAttributes
            .LiveActivityItem.defaultItems
    }

    /// Sets up the array of glucose data from persistent storage and triggers an update to the live activity.
    private func loadGlucose(forceWidgetReload: Bool = false) async {
        do {
            let latest = try await fetchAndMapGlucose()
            data.glucoseFromPersistence = latest
            // Explicitly publish after the fetch, independent of the
            // asynchronous Combine notification used for other state changes.
            await pushCurrentContent(forceWidgetReload: forceWidgetReload)
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch glucose with error: \(error)"
            )
        }
    }

    private func loadInitialData() {
        Task {
            await self.loadGlucose()
            await self.loadOverrides()
            await self.loadTempTarget()
            await self.loadDetermination()
            self.data.iob = self.iobService.currentIOB
            self.loadWidgetItems()
        }
    }

    /// Monitors live activity authorization changes and updates the `systemEnabled` flag.
    private func monitorForLiveActivityAuthorizationChanges() {
        Task {
            for await activityState in activityAuthorizationInfo.activityEnablementUpdates {
                if activityState != systemEnabled {
                    await MainActor.run {
                        systemEnabled = activityState
                    }
                }
            }
        }
    }

    /// Copies display-only data into the existing Trio App Group so the iPhone
    /// Home Screen widget can show the last known values without opening Trio.
    /// No data leaves the device and the widget never initiates insulin delivery.
    @MainActor private func persistHomeWidgetSnapshot(
        _ content: LiveActivityAttributes.ContentState,
        glucoseDate: Date,
        forceReload: Bool = false
    ) {
        guard let suite = Bundle.main.appGroupSuiteName,
              let shared = UserDefaults(suiteName: suite),
              let snapshot = try? JSONEncoder().encode(content)
        else { return }

        // Atomic App Group file avoids cross-process UserDefaults timing races.
        // Keep UserDefaults as fallback for prior widget builds.
        if let sharedDirectory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suite) {
            let snapshotFile = sharedDirectory.appendingPathComponent("LoKeyTrioMediumContentState.v1.json")
            do {
                try snapshot.write(to: snapshotFile, options: .atomic)
            } catch {
                debug(.default, "[LoKeyTrioWidget] Unable to save snapshot: \(error)")
            }
        }
        shared.set(snapshot, forKey: "lokeyTrio.medium.contentState.v1")
        shared.set(data.iob != nil, forKey: "lokeyTrio.medium.hasIOB.v1")
        shared.set(data.determination != nil, forKey: "lokeyTrio.medium.hasCOB.v1")

        // Forecast bounds are sourced from the actual Oref determination,
        // irrespective of whether forecasts are displayed in Live Activities.
        // Missing determinations clear earlier forecasts rather than retaining
        // obsolete predictions.
        shared.set(data.determination?.minForecast ?? [], forKey: "lokeyTrio.medium.forecastMin.v1")
        shared.set(data.determination?.maxForecast ?? [], forKey: "lokeyTrio.medium.forecastMax.v1")
        shared.set(data.determination?.date?.timeIntervalSince1970 ?? 0,
                   forKey: "lokeyTrio.medium.forecastDate.v1")

        // Green widget chart is a *measured IOB history* and is labelled IOB;
        // it does not pretend to be a record of delivered insulin.
        let now = Date()
        var history = (shared.array(forKey: "lokeyTrio.medium.iobHistory.v1") as? [[String: Double]] ?? [])
            .filter { (now.timeIntervalSince1970 - ($0["time"] ?? 0)) < 2 * 60 * 60 }
        if let iob = data.iob {
            let units = NSDecimalNumber(decimal: iob).doubleValue
            let lastSample = history.last?["time"] ?? 0
            if units.isFinite, now.timeIntervalSince1970 - lastSample >= 150 {
                history.append(["time": now.timeIntervalSince1970, "units": units])
            }
        }
        shared.set(history, forKey: "lokeyTrio.medium.iobHistory.v1")

        // WidgetKit chooses its own update timing; these are best-effort hints.
        // Refresh on new CGM readings, or periodically for changed IOB/COB.
        if forceReload || lastHomeWidgetGlucoseDate != glucoseDate ||
            now.timeIntervalSince(lastHomeWidgetReload) >= 10 * 60
        {
            lastHomeWidgetGlucoseDate = glucoseDate
            lastHomeWidgetReload = now
            WidgetCenter.shared.reloadTimelines(ofKind: "LoKeyTrioMedium")
        }
    }

    /// Pushes an update to the live activity with the specified content state.
    ///
    /// If an existing activity requires recreation or is outdated, this method ends it and starts a new one.
    /// Otherwise, it updates the current live activity.
    ///
    /// - Parameter state: The new content state to push to the live activity.
    @MainActor private func pushUpdate(_ state: LiveActivityAttributes.ContentState) async {
        if !settings.useLiveActivity || !systemEnabled {
            await endActivity()
            return
        }

        if currentActivity == nil {
            // try to restore an existing activity
            currentActivity = Activity<LiveActivityAttributes>.activities
                .max { $0.attributes.startDate < $1.attributes.startDate }.map {
                    ActiveActivity(activity: $0)
                }

            if let currentActivity {
                debug(.default, "[LiveActivityManager] Restored live activity: \(currentActivity.activity.id)")
            }
        }

        // End all unknown activities except the current one
        for unknownActivity in Activity<LiveActivityAttributes>.activities
            .filter({ self.currentActivity?.activity.id != $0.id })
        {
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        if let currentActivity {
            if currentActivity.needsRecreation(), UIApplication.shared.applicationState == .active {
                debug(.default, "[LiveActivityManager] Ending current activity for recreation: \(currentActivity.activity.id)")
                await endActivity()
                // After endActivity(), currentActivity is guaranteed to be nil
                // No recursive task, but explicitly restart
                debug(.default, "[LiveActivityManager] Re-pushing update after recreation.")
                await pushUpdate(state)
            } else {
                let content = ActivityContent(
                    state: state,
                    staleDate: min(state.date ?? Date.now, Date.now).addingTimeInterval(360)
                )
                // Before the update, check if currentActivity is still valid
                if let stillCurrent = self.currentActivity, stillCurrent.activity.id == currentActivity.activity.id {
                    debug(.default, "[LiveActivityManager] Updating current activity: \(stillCurrent.activity.id)")
                    await stillCurrent.activity.update(content)
                } else {
                    debug(.default, "[LiveActivityManager] Skipped update: currentActivity changed during pushUpdate.")
                }
            }
        } else {
            // ... Activity is newly created ...
            do {
                let expired = ActivityContent(
                    state: LiveActivityAttributes
                        .ContentState(
                            unit: settings.units.rawValue,
                            bg: "--",
                            direction: nil,
                            change: "--",
                            date: Date.now,
                            highGlucose: settings.high,
                            lowGlucose: settings.low,
                            target: data.determination?.target ?? 100 as Decimal,
                            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
                            useDetailedViewIOS: false,
                            useDetailedViewWatchOS: false,
                            detailedViewState: LiveActivityAttributes.ContentAdditionalState(
                                chart: [],
                                rotationDegrees: 0,
                                cob: 0,
                                iob: 0,
                                tdd: 0,
                                isOverrideActive: false,
                                overrideName: "",
                                overrideDate: Date.now,
                                overrideDuration: 0,
                                overrideTarget: 0,
                                isTempTargetActive: false,
                                tempTargetName: "",
                                tempTargetDate: Date.now,
                                tempTargetDuration: 0,
                                tempTargetTarget: 0,
                                widgetItems: [],
                                minForecast: [],
                                maxForecast: [],
                                forecastLines: [],
                                forecastDisplayType: ForecastDisplayType.cone.rawValue
                            ),
                            isInitialState: true
                        ),
                    staleDate: Date.now.addingTimeInterval(60)
                )

                let activity = try Activity.request(
                    attributes: LiveActivityAttributes(startDate: Date.now),
                    content: expired,
                    pushType: nil
                )
                currentActivity = ActiveActivity(activity: activity)
                debug(.default, "[LiveActivityManager] Created new activity: \(activity.id)")

                // Update the newly created activity with actual data
                let updateContent = ActivityContent(
                    state: state,
                    staleDate: Date.now.addingTimeInterval(5 * 60)
                )
                await activity.update(updateContent)
                debug(.default, "[LiveActivityManager] Set initial content for new activity: \(activity.id)")
            } catch {
                debug(
                    .default,
                    "[LiveActivityManager]: Error creating new activity: \(error)"
                )
                // Reset currentActivity on error to allow retry on next update
                currentActivity = nil
            }
        }
    }

    /// Ends the current live activity and ensures that all unknown activities are terminated.
    private func endActivity() async {
        debug(.default, "[LiveActivityManager] Ending all live activities...")

        if let currentActivity {
            debug(.default, "[LiveActivityManager] Ending current activity: \(currentActivity.activity.id)")
            await currentActivity.activity.end(nil, dismissalPolicy: .immediate)
            self.currentActivity = nil
        }

        for unknownActivity in Activity<LiveActivityAttributes>.activities {
            debug(.default, "[LiveActivityManager] Ending unknown activity: \(unknownActivity.id)")
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        debug(.default, "[LiveActivityManager] All live activities ended.")
    }

    /// Restarts the live activity from a Live Activity Intent.
    ///
    /// This method mimics xdrip's `restartActivityFromLiveActivityIntent()` behavior by verifying that a valid content state
    /// exists,
    /// ending the current live activity, and starting a new one using the current state.
    @MainActor func restartActivityFromLiveActivityIntent() async {
        await endActivity()

        while (currentActivity != nil && currentActivity!.activity.activityState != .ended) || Activity<LiveActivityAttributes>
            .activities.contains(where: { $0.activityState != .ended })
        {
            debug(.default, "[LiveActivityManager] Waiting for Live Activity to end...")
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s sleep
        }

        // Add additional delay to ensure iOS has fully cleaned up the previous activity
        debug(.default, "[LiveActivityManager] Waiting additional time for iOS to clean up...")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s additional delay

        await pushCurrentContent()

        debug(.default, "[LiveActivityManager] Restarted Live Activity from LiveActivityIntent (via iOS Shortcut)")
    }
}

@available(iOS 16.2, *) extension LiveActivityManager {
    @MainActor func pushCurrentContent(forceWidgetReload: Bool = false) async {
        guard let glucose = data.glucoseFromPersistence, let bg = glucose.first else {
            debug(.default, "[LiveActivityManager] pushCurrentContent: no current glucose data available")
            return
        }
        let prevGlucose = data.glucoseFromPersistence?.dropFirst().first

        let content = LiveActivityAttributes.ContentState(
            new: bg,
            prev: prevGlucose,
            units: settings.units,
            chart: glucose,
            settings: settings,
            determination: data.determination,
            iob: data.iob,
            override: data.override,
            tempTarget: data.tempTarget,
            widgetItems: data.widgetItems
        )

        // The Home Screen widget can show glucose even before the user has
        // configured a pump or generated an Oref determination.
        persistHomeWidgetSnapshot(content, glucoseDate: bg.date, forceReload: forceWidgetReload)

        // Keep the existing Live Activity startup requirement unchanged.
        guard data.determination != nil else {
            debug(.default, "[LiveActivityManager] pushCurrentContent: no determination available")
            return
        }

        await pushUpdate(content)
    }
}
