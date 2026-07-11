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

            HStack(spacing: 10) {
                Button {
                    Task { await connect() }
                } label: {
                    if connecting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(L("gcal.connecting"))
                        }
                    } else {
                        Text(L("gcal.connect"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(connecting || clientID.trimmingCharacters(in: .whitespaces).isEmpty
                          || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)

                Link(L("gcal.setup_guide"),
                     destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    .font(.caption)
            }

            Text(L("gcal.setup_steps"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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
                        Text(L("gcal.sync_now"))
                    }
                }
                .disabled(sync.isSyncing)

                if let last = sync.lastSyncAt {
                    Text(L("gcal.last_synced", DF.hourMinute.string(from: last)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
