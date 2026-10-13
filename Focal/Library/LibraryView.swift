import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: PhotoLibrary
    @State private var favoritesOnly = false
    @State private var selected: SavedPhoto?
    @State private var collection = ""
    @State private var newCollection = false
    @State private var collectionName = ""
    @State private var choosingComparison = false
    @State private var comparisonIDs:[UUID] = []
    @State private var showComparison = false
    private var comparisonPhotos:[SavedPhoto] { comparisonIDs.compactMap { id in library.photos.first { $0.id == id } } }
    @Environment(\.dismiss) private var dismiss
    private var visible: [SavedPhoto] { library.photos.filter { (!favoritesOnly || $0.isFavorite) && (collection.isEmpty || $0.collection == collection) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "CAPTURE ARCHIVE").foregroundStyle(Palette.mint)
                        Text("Library").font(.system(size: 30, weight: .bold))
                        Text("\(library.photos.count) \(library.photos.count == 1 ? "frame" : "frames") worth keeping.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    Picker("Show photos", selection: $favoritesOnly) {
                        Text("All shots").tag(false)
                        Text("Favorites").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if choosingComparison {
                        HStack {
                            Text("Select two images · \(comparisonIDs.count)/2").font(.caption)
                            Spacer()
                            Button("Compare") { showComparison = true }.disabled(comparisonPhotos.count != 2)
                            Button("Cancel") { choosingComparison = false; comparisonIDs = [] }
                        }.tint(Palette.yellow)
                    }

                    HStack {
                        Picker("Collection",selection: $collection) {
                            Text("All collections").tag("")
                            ForEach(library.collections,id: \.self) { Text($0).tag($0) }
                        }
                        Spacer()
                        Button { collectionName = ""; newCollection = true } label: { Image(systemName: "folder.badge.plus") }.accessibilityLabel("Create collection")
                    }
                    if visible.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: favoritesOnly ? "heart" : "photo.on.rectangle.angled")
                                .font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Palette.mint)
                            Text(favoritesOnly ? "Keep your favorites close." : "Every collection starts with a frame.")
                                .font(.system(.title2, design: .serif)).multilineTextAlignment(.center)
                            Text(favoritesOnly ? "Open a shot and tap the heart to find it here." : "Take your first photo in Camera. It will be waiting here, just for you.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .padding(30).frame(maxWidth: .infinity).frame(minHeight: 300)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 24))
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 22) {
                            ForEach(visible) { photo in
                                Button { select(photo) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        GeometryReader { geometry in
                                            PhotoImage(url: library.url(for: photo), maxPixels: 600, fill: true)
                                                .frame(width: geometry.size.width, height: geometry.size.height)
                                                .clipped()
                                        }
                                        .aspectRatio(3.0 / 4, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                        .overlay { RoundedRectangle(cornerRadius:16).stroke(comparisonIDs.contains(photo.id) ? Palette.yellow : .clear,lineWidth:2) }
                                        .overlay(alignment: .topTrailing) {
                                            if library.isBestInBurst(photo) { Text("Technical pick").font(.caption2).padding(6).background(.black.opacity(0.65)).foregroundStyle(Palette.yellow) }
                                            if photo.isFavorite {
                                                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.white)
                                                    .padding(9).background(.black.opacity(0.25), in: Circle()).padding(8)
                                            }
                                        }
                                        HStack {
                                            Text(photo.isDemo ? "Demo frame" : photo.mode)
                                                .font(.caption.weight(.medium))
                                            Spacer()
                                            Text(photo.createdAt, format: .dateTime.month(.abbreviated).day())
                                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                        }
                                    }
                                    .foregroundStyle(.white)
                                }
                                .accessibilityLabel("\(photo.isDemo ? "Demo photo" : photo.mode), \(photo.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    }
                    Label("Stored on this iPhone", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .padding(.horizontal, 22)
            }
            .background(Palette.ink)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement:.topBarLeading) { Button("Compare",systemImage:"rectangle.split.2x1") { choosingComparison = true; comparisonIDs = [] }.disabled(library.photos.count < 2) }
            }
            .sheet(item: $selected) { PhotoDetailView(photo: $0) }
            .sheet(isPresented:$showComparison) {
                if comparisonPhotos.count == 2 { PhotoCompareView(first:comparisonPhotos[0],second:comparisonPhotos[1]) }
            }
            .alert("New collection",isPresented: $newCollection) {
                TextField("Name",text: $collectionName)
                Button("Create") { do { try library.createCollection(collectionName) } catch { library.errorMessage = error.localizedDescription } }
                Button("Cancel",role: .cancel) {}
            }
            .alert("Your shots", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("OK") { library.errorMessage = nil }
            } message: { Text(library.errorMessage ?? "") }
        }
    }
    private func select(_ photo:SavedPhoto) {
        if !choosingComparison { selected = photo; return }
        if comparisonIDs.contains(photo.id) { comparisonIDs.removeAll { $0 == photo.id } }
        else if comparisonIDs.count < 2 { comparisonIDs.append(photo.id) }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

struct PhotoImage: View {
    let url: URL
    var maxPixels = 1800
    var fill = false
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                if fill { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(uiImage: image).resizable().scaledToFit() }
            } else if failed {
                ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark")
            } else {
                Rectangle().fill(Palette.panel).overlay { ProgressView() }
            }
        }
        .task(id: url) {
            image = nil; failed = false
            let loaded = await PhotoLoader.load(url: url, maxPixels: maxPixels)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}
