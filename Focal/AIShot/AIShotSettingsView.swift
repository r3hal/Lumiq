import SwiftUI

/// Connects AI Shot to a free external AI. Either the Lumiq AI server
/// (Cloudflare Worker in /ai-server: Gemini → Groq → Workers AI) or a free
/// Gemini key used directly from the phone.
struct AIShotSettingsView: View {
    @AppStorage(AIShotConfiguration.serverKey) private var server = ""
    @AppStorage(AIShotConfiguration.tokenKey) private var token = ""
    @State private var geminiKey = AIShotConfiguration.personalGeminiKey ?? ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Text("Tap ✦ on the camera. One frame goes to the AI, which marks the best shot. Lumiq then tracks it on your iPhone, guides you, zooms and says Ready.")
                    .font(.footnote)
            }
            Section {
                TextField("https://lumiq-ai.<you>.workers.dev",text:$server)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("App token (APP_TOKEN)",text:$token)
                Button(testing ? "Testing…" : "Test server") { test() }.disabled(testing || server.isEmpty)
            } header: { Text("Lumiq AI server (recommended)") } footer: {
                Text("Free Cloudflare Worker from the ai-server folder. It uses Gemini, Groq or Cloudflare's own free AI, whichever is available.")
            }
            Section {
                SecureField("Gemini API key",text:$geminiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of:geminiKey) { _,value in AIShotKeychain.write(value,account:AIShotConfiguration.geminiKeychainAccount) }
                Link("Get a free key at aistudio.google.com",destination:URL(string:"https://aistudio.google.com/apikey")!)
            } header: { Text("Or: direct Gemini key") } footer: {
                Text(AIShotConfiguration.builtInGeminiKey == nil ? "Used only when no server is set. The key is stored in this iPhone's Keychain." : "This build includes Lumiq's Gemini key, so AI Shot works without setup. A server or a key typed here is used instead. Typed keys are stored in this iPhone's Keychain.")
            }
            if let status { Section { Text(status).font(.footnote) } }
            Section {
                Text("Only the single frame you scan is sent, compressed to 768 px. The video stream and your library never leave the phone.").font(.footnote)
            }
        }
        .navigationTitle("AI Shot")
    }

    private func test() {
        guard let shot = AIShotConfiguration.serverURL,
              var components = URLComponents(url:shot,resolvingAgainstBaseURL:false) else { status = "Enter an https:// address."; return }
        components.path = "/health"
        guard let url = components.url else { return }
        testing = true; status = nil
        Task {
            defer { testing = false }
            do {
                let (data,response) = try await URLSession.shared.data(from:url)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data:data,encoding:.utf8) ?? ""
                status = code == 200 ? "Connected: \(body)" : "Server answered \(code)."
            } catch { status = "Could not reach the server: \(error.localizedDescription)" }
        }
    }
}
