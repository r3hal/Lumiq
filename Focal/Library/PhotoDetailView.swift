import SwiftUI

struct PhotoDetailView: View {
    let photo: SavedPhoto
    @EnvironmentObject private var library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var message: String?
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var variant = "Photo"
    @State private var showEditor = false
    @State private var showViewer = false
    @State private var showInsights = false
    @State private var metadata: PhotoMetadata?
    @State private var photosDenied = false
    private var current: SavedPhoto { library.photos.first { $0.id == photo.id } ?? photo }
    private var imageURL: URL {
        if variant == "Wide preview", let wide = library.widePreviewURL(for:current) { return wide }
        if variant == "Scan", let scan = library.scanURL(for: current) { return scan }
        if variant == "Original", let original = library.originalURL(for: current) { return original }
        return library.url(for: current)
    }

    @ViewBuilder
    private var framingSessionDetails: some View {
    if let session = current.framingSession {
        VStack(alignment:.leading,spacing:5) {
            Label("AI framing session",systemImage:"square.stack").font(.caption.weight(.medium)).foregroundStyle(Palette.yellow)
            if variant == "Wide preview" {
                if let resolution = session.previewResolutionLabel { Text(resolution).font(.system(.caption2,design:.monospaced)) }
                Text("An earlier live preview, retained before AI zoom. Lower resolution than the captured photo.")
                if let date = session.widePreviewObservedAt { Text(date,format:.dateTime.hour().minute().second()) }
            } else if variant == "Original" {
                Text("The unedited camera capture at the final zoom.")
            } else if current.widePreviewFilename == nil {
                Text("Wide preview unavailable. Your framed photo is saved.")
            } else { Text("This shot includes an earlier wide preview in the same entry.") }
        }.font(.caption).foregroundStyle(.secondary)
    }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if current.scanFilename != nil || current.originalFilename != nil || current.widePreviewFilename != nil {
                        Picker("Image", selection: $variant) {
                            Text(current.framingSession == nil ? "Photo" : "AI frame").tag("Photo")
                            if photo.scanFilename != nil { Text("Scan").tag("Scan") }
                            if current.originalFilename != nil { Text(current.framingSession == nil ? "Original" : "Source").tag("Original") }
                            if current.widePreviewFilename != nil { Text("Wide preview").tag("Wide preview") }
                        }.pickerStyle(.segmented)
                    }
                    PhotoImage(url: imageURL, maxPixels: 4096)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .onTapGesture { showViewer = true }
                        .accessibilityLabel(photo.isDemo ? "Sample lake and mountain scene" : "Your captured photo")
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Eyebrow(text: photo.isDemo ? "Demo frame" : "Capture details").foregroundStyle(Palette.mint)
                            Text(photo.createdAt, format: .dateTime.month(.wide).day().year())
                                .font(.title2)
                            Text("\(photo.mode) composition · \(photo.createdAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if variant == "Photo", let resolution = current.resolutionLabel {
                                Text(resolution).font(.system(.caption2, design: .monospaced)).foregroundStyle(Palette.mint)
                            }
                            if variant == "Photo", let aspect = photo.aspect { Text("Aspect \(aspect)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { library.toggleFavorite(current) } label: {
                            Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                                .font(.title2).foregroundStyle(Palette.mint).frame(width: 48, height: 48)
                        }
                        .accessibilityLabel(current.isFavorite ? "Remove from favorites" : "Add to favorites")
                    }
                    framingSessionDetails
                    HStack {
                        Button("Edit photo",systemImage: "slider.horizontal.3") { showEditor = true }.disabled(variant != "Photo" || !current.canUsePhoneEditor)
                        Spacer()
                        Button("Full screen",systemImage: "arrow.up.left.and.arrow.down.right") { showViewer = true }
                    }.foregroundStyle(Palette.yellow)
                    Button("Focal Insights",systemImage:"chart.xyaxis.line") { showInsights = true }.foregroundStyle(Palette.yellow).disabled(variant == "Scan")
                    if !current.canUsePhoneEditor { Text("Looks, adjustments, effects and frames are available for iPhone captures.").font(.caption).foregroundStyle(.secondary) }
                    Picker("Collection",selection: Binding(get: { current.collection ?? "" },set: { library.setCollection($0.isEmpty ? nil : $0,for: current) })) {
                        Text("No collection").tag("")
                        ForEach(library.collections,id: \.self) { Text($0).tag($0) }
                    }
                    if let metadata {
                        ForEach(metadata.rows,id: \.0) { row in HStack { Text(row.0); Spacer(); Text(row.1).foregroundStyle(.secondary) }.font(.caption) }
                    }
                    if variant == "Photo", let measured = current.measurements {
                        VStack(alignment: .leading,spacing: 6) {
                            Text(String(format: "Technical measure: %.0f/100",measured.technicalScore)).foregroundStyle(Palette.yellow)
                            Text(String(format: "Brightness %.0f%% · Clipped highlights %.0f%% · Deep shadows %.0f%%",measured.brightness*100,measured.highlightFraction*100,measured.shadowFraction*100))
                            Text("Measured exposure clipping and local contrast, not an AI aesthetic rating. Noise may inflate the detail measure.")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        exporting = true; photosDenied = false
                        Task {
                            do { try await library.saveToPhotos(current, imageURL: imageURL); message = "Saved to your iPhone photo library." }
                            catch {
                                if let libraryError = error as? PhotoLibrary.LibraryError, case .photosDenied = libraryError { photosDenied = true }
                                message = error.localizedDescription
                            }
                            exporting = false
                        }
                    } label: {
                        HStack {
                            if exporting { ProgressView().tint(Palette.ink) }
                            else { Image(systemName: "square.and.arrow.down") }
                            Text(exporting ? "Saving…" : "Save to Photos")
                        }
                    }
                    .buttonStyle(PrimaryButton()).disabled(exporting)
                    if let raw = library.rawURL(for: photo) {
                        Button {
                            shareItems = [raw]
                            showShare = true
                        } label: { Label("Share RAW original", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(12) }
                        .foregroundStyle(Palette.yellow)
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete from Focal", systemImage: "trash").font(.subheadline).frame(maxWidth: .infinity).padding(12)
                    }
                }
                .padding(22)
            }
            .background(Palette.ink)
            .navigationTitle("Your frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareItems = [imageURL]
                        showShare = true
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share photo")
                }
            }
            .sheet(isPresented: $showEditor) { PhotoEditorView(photo: current) }
            .sheet(isPresented:$showInsights) { PhotoInsightsView(url:imageURL,intent:PhotographyIntent(rawValue:current.photographyIntent ?? "") ?? .auto) }
            .fullScreenCover(isPresented: $showViewer) { PhotoViewer(url: imageURL) }
            .task(id: imageURL) {
                let file = imageURL
                let loaded = await Task.detached { PhotoMetadata.read(file) }.value
                guard !Task.isCancelled else { return }
                metadata = loaded
            }
            .confirmationDialog("Delete this photo from Focal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete photo", role: .destructive) {
                    do { try library.delete(current); dismiss() }
                    catch { message = error.localizedDescription }
                }
            } message: { Text("Copies saved to Photos or shared elsewhere will remain.") }
            .alert("Your frame", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
                if photosDenied { Button("Open iPhone Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
            } message: { Text(message ?? "") }
            .sheet(isPresented: $showShare) {
                ActivitySheet(items: shareItems)
            }
        }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
