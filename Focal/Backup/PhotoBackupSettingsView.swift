import SwiftUI

struct PhotoBackupSettingsView:View {
    @ObservedObject var backup:PhotoBackupCoordinator
    @State private var server = ""
    @State private var code = ""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if let destination = backup.summary.destination {
                LabeledContent("Connection",value:"Device authorized")
                LabeledContent("Destination",value:destination.label)
                Text(destination.server.host ?? "Owner server").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Owner Google Drive",value:backup.ownerDriveConnected.map{$0 ? "Connected" : "Owner action required"} ?? "Not checked")
                Toggle("Automatic photo backup",isOn:Binding(get:{backup.summary.enabled},set:{value in Task { await backup.setEnabled(value) }}))
                    .disabled(backup.busy)
                LabeledContent("Pending uploads",value:String(backup.summary.pending))
                LabeledContent("Failed uploads",value:String(backup.summary.failed))
                if backup.summary.otherDestinationPending > 0 {
                    Text("\(backup.summary.otherDestinationPending) resources belong to a previous connection. Ask the owner for a recovery invitation to resume them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let date = backup.summary.lastSuccess { LabeledContent("Last successful upload") { Text(date,style:.relative) } }
                else { LabeledContent("Last successful upload",value:"None yet") }
                HStack {
                    Button("Retry now") { Task { await backup.retry() } }
                    Spacer()
                    Button("Disconnect",role:.destructive) { Task { await backup.disconnect() } }
                }.disabled(backup.busy)
                Text("When enabled, new original photos, RAW files and associated resources from this device are sent to this owner's server and Google Drive over Wi-Fi or cellular. Existing photos are not automatically enrolled. Disable backup to stop new enrollment and cancel pending device transfers. Local deletion does not remove copies already accepted by the server or Google Drive.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Disconnected").font(.subheadline)
                Text("Only enroll with a backup owner you trust. After you enable backup, this device's new photos will be shared with that owner automatically. You do not need a Google account.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Owner server · https://backup.example.com",text:$server)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("One-time invitation code",text:$code).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Authorize this device") {
                    let invitation = code;code = ""
                    Task { await backup.connect(serverText:server,code:invitation) }
                }.disabled(backup.busy || server.isEmpty || code.isEmpty)
            }
            if let problem = backup.statusProblem ?? backup.summary.problem {
                Text(problem.explanation).font(.caption).foregroundStyle(Palette.yellow)
            }
            Text("Uploads use original bytes. iOS schedules background transfers; force-quitting Focal can stop them until you reopen it. Google credentials stay on the owner's backend. No per-photo upload notifications are shown.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(15)
    }
}
