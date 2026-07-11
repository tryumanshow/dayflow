import SwiftUI

/// The Google Calendar tab in Settings.
///
/// Its own `View` rather than another slice of `SettingsView` because it owns
/// live state (connecting, syncing, the fetched calendar list) that the rest of
/// Settings has no reason to re-render for.
@MainActor
struct GoogleCalendarSettings: View {
    // Deliberately no `@Environment(DayflowStore.self)`. Settings is its own
    // scene and the store was never injected into it — reading it here traps
    // on a force-unwrap the moment the tab is first drawn. The sync coordinator
    // already holds its own reference to the store from `bootstrap`, which is
    // the only place this view needs one.
    @State private var sync = GoogleCalendarSync.shared
    @State private var clientID: String = GoogleCredentials.clientID
    @State private var clientSecret: String = ""
    @State private var connecting = false
    @State private var showSetupGuide = false
    @State private var selected: Set<String> = Set(GoogleCalendarPreference.selectedCalendars)

    private var isConnected: Bool { GoogleCredentials.isConnected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                intro
                Divider()
                if isConnected {
                    connectedBody
                } else {
                    credentialsForm
                }
                if let err = sync.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .task {
            if isConnected, sync.calendars.isEmpty {
                await sync.refreshCalendarList()
            }
        }
    }

    // MARK: - pieces

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("gcal.title"))
                .font(.headline)
            Text(L("gcal.blurb"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The user brings their own OAuth client. See `GoogleCredentials` for why
    /// Dayflow can't ship one.
    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(label: L("gcal.client_id"), hint: L("gcal.client_id.hint")) {
                TextField("", text: $clientID, prompt: Text("xxxxx.apps.googleusercontent.com"))
                    .textFieldStyle(.roundedBorder)
            }
            field(label: L("gcal.client_secret"), hint: L("gcal.client_secret.hint")) {
                SecureField("", text: $clientSecret, prompt: Text("GOCSPX-…"))
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task { await connect() }
                } label: {
                    if connecting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(L("gcal.connecting"))
                        }
                    } else {
                        Label(L("gcal.connect"), systemImage: "safari")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(connecting || clientID.trimmingCharacters(in: .whitespaces).isEmpty
                          || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)

                // Pressing this throws you out to a browser with no warning,
                // which is exactly the thing nobody expects from a Settings
                // pane. Say so before it happens.
                Text(L("gcal.connect.hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Five lines of grey prose is a wall nobody reads. It's needed
            // exactly once, so it hides until asked for.
            DisclosureGroup(isExpanded: $showSetupGuide) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(Self.setupSteps.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color.dfAccent)
                                .frame(width: 14, alignment: .trailing)
                            Text(L(step))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Link(L("gcal.setup_guide"),
                         destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        .font(.caption)
                        .padding(.top, 2)
                    Text(L("gcal.byo_reason"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(.top, 8)
            } label: {
                Text(L("gcal.setup_title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let setupSteps = [
        "gcal.step.project",
        "gcal.step.enable_api",
        "gcal.step.create_client",
        "gcal.step.paste",
        "gcal.step.connect",
    ]

    private var connectedBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L("gcal.connected"))
                    .font(.subheadline)
                Spacer()
                Button(L("gcal.disconnect"), role: .destructive) {
                    sync.disconnect()
                    clientSecret = ""
                    selected = []
                }
                .controlSize(.small)
            }

            field(label: L("gcal.calendars"), hint: L("gcal.calendars.hint")) {
                VStack(alignment: .leading, spacing: 4) {
                    if sync.calendars.isEmpty {
                        Text(L("gcal.calendars.loading"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(sync.calendars) { cal in
                        Toggle(isOn: binding(for: cal)) {
                            HStack(spacing: 6) {
                                Text(cal.summary).lineLimit(1)
                                if cal.primary {
                                    Text(L("gcal.primary"))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        if sync.isSyncing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L("gcal.syncing"))
                            }
                        } else {
                            Label(L("gcal.sync_now"), systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(sync.isSyncing)

                    if let last = sync.lastSyncAt {
                        Text(L("gcal.last_synced", DF.hourMinute.string(from: last)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // "Connected" alone doesn't tell you whether anything actually
                // came across. The count does.
                if sync.lastSyncAt != nil {
                    Text(L("gcal.imported_count", sync.importedCount))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(L("gcal.readonly_note"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - actions

    private func connect() async {
        connecting = true
        defer { connecting = false }
        GoogleCredentials.clientID = clientID
        GoogleCredentials.clientSecret = clientSecret
        await sync.connect()
        if GoogleCredentials.isConnected {
            // Nothing selected yet means "primary only"; reflect that in the
            // checkbox list so what's shown matches what actually syncs.
            selected = Set(GoogleCalendarPreference.selectedCalendars)
            if selected.isEmpty, let primary = sync.calendars.first(where: \.primary) {
                selected = [primary.id]
                GoogleCalendarPreference.selectedCalendars = [primary.id]
            }
        }
    }

    private func binding(for cal: GoogleCalendarInfo) -> Binding<Bool> {
        Binding(
            get: { selected.contains(cal.id) },
            set: { on in
                if on { selected.insert(cal.id) } else { selected.remove(cal.id) }
                GoogleCalendarPreference.selectedCalendars = Array(selected)
                // Un-ticking a calendar has to actually remove its events, and
                // the sync is what prunes them — a stale mirror would keep
                // showing a calendar the user just switched off.
                Task { await sync.syncNow() }
            }
        )
    }

    @ViewBuilder
    private func field<Content: View>(
        label: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
