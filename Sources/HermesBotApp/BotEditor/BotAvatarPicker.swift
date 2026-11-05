import AppKit
import HermesGatewayKit
import SwiftUI

/// The avatar a bot sheet has staged (nothing is written before Save / Create).
enum BotAvatarEdit: Equatable {
    case unchanged
    /// A picture: an upload or a generated image (256 px PNG) or a pet frame (as the backend cropped it).
    case set(Data)
    /// No picture: the monogram here (Desktop draws the bot's shape face).
    case remove
    /// A shape face: one of `BotLook.shapes` and a colour (nil = the name's hue).
    case shape(String, color: String?)

    var isShape: Bool { if case .shape = self { return true }; return false }
}

/// A10: the avatar picker shared by New Bot and Edit, Desktop's `AvatarPicker` (`avatar-picker.tsx`, `pet.tsx`):
/// - Shape: Desktop's shapes with a face, its twelve colours or the name's own hue, Randomize, and Monogram.
/// - Upload: a PNG or JPEG (the host checks and resizes it).
/// - Generate: `image.generate`, offered once the availability probe says a backend is configured (a "no" is
///   asked again each time the tab is chosen); an empty description asks for a robot mascot named after the bot.
/// - Pet: the petdex gallery, searchable, 24 at a time; thumbnails come from `pet.thumb` and are kept while the
///   sheet is open.
@MainActor
final class BotAvatarPickerModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case shape = "Shape", upload = "Upload", generate = "Generate", pet = "Pet"
        var id: String { rawValue }
    }
    enum Imagen: Equatable { case unknown, checking, available, unavailable }
    struct Seed: Equatable { var name: String; var title: String; var description: String }

    static let petPage = 24

    @Published var tab: Tab = .shape { didSet { tabChosen() } }
    /// The shape and colour the grid shows (the staged one, else the bot's current look, else Desktop's default).
    @Published private(set) var shape: String
    @Published private(set) var color: String?
    @Published private(set) var imagen: Imagen = .unknown
    @Published var prompt = ""
    @Published private(set) var generating = false
    @Published private(set) var error: String?
    @Published private(set) var pets: [AvatarSources.Pet]?
    @Published private(set) var petsLoading = false
    @Published var petQuery = "" { didSet { petLimit = Self.petPage } }
    @Published var petLimit = petPage
    @Published private(set) var thumbs: [String: Data] = [:]
    @Published private(set) var selectedPet: String?
    @Published private(set) var loadingPet: String?

    private let service: any BotProfileService
    /// Stages an edit on the host sheet.
    let apply: (BotAvatarEdit) -> Void
    /// Monogram (no picture): the host decides what that means for it.
    let monogram: () -> Void
    /// The bot's name, title and description now (the face colour and the generate prompt follow them).
    let seed: () -> Seed
    var randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    private var thumbsInFlight: Set<String> = []

    init(service: any BotProfileService, seed: @escaping () -> Seed, apply: @escaping (BotAvatarEdit) -> Void,
         monogram: @escaping () -> Void) {
        self.service = service
        self.seed = seed
        self.apply = apply
        self.monogram = monogram
        shape = BotLook.defaultShape(for: seed().name)
    }

    /// The face's name seed: the bot's name, `agent` while a new bot has none (Desktop's `pickerName`).
    var faceName: String { seed().name.isEmpty ? "agent" : seed().name }

    /// The bot's current look, read from its `ui_meta` (Edit): the grid starts there.
    func showCurrent(shape: String?, color: String?) {
        if let shape, BotLook.shapes.contains(shape) { self.shape = shape }
        self.color = color
    }

    // MARK: shape

    func chooseShape(_ s: String) { shape = s; apply(.shape(s, color: color)) }
    func chooseColor(_ c: String?) { color = c; apply(.shape(shape, color: c)) }

    /// A random shape and one of the twelve colours.
    func randomize() {
        shape = BotLook.shapes[randomIndex(BotLook.shapes.count)]
        color = BotLook.swatches[randomIndex(BotLook.swatches.count)]
        apply(.shape(shape, color: color))
    }

    // MARK: tabs

    private func tabChosen() {
        error = nil
        switch tab {
        case .generate where imagen == .unknown || imagen == .unavailable: Task { await probe() }
        case .pet where pets == nil && !petsLoading: Task { await loadPets() }
        default: break
        }
    }

    // MARK: generate

    func probe() async {
        guard imagen != .checking else { return }
        imagen = .checking
        imagen = await service.imageGenerationAvailable() ? .available : .unavailable
    }

    func generate() async {
        guard !generating, imagen == .available else { return }
        generating = true
        error = nil
        let s = seed()
        let text = AvatarSources.prompt(custom: prompt, name: s.name.isEmpty ? "agent" : s.name, title: s.title,
                                        description: s.description)
        do {
            let image = try await service.generateImage(prompt: text)
            apply(.set(try ProfileAvatar.normalizeGenerated(image)))
        } catch {
            self.error = "Could not generate an avatar: \(BotManagementText.describe(error))"
        }
        generating = false
    }

    // MARK: pets

    func loadPets() async {
        guard !petsLoading else { return }
        petsLoading = true
        error = nil
        do { pets = try await service.petGallery() } catch {
            self.error = "Could not load the pet gallery: \(BotManagementText.describe(error))"
        }
        petsLoading = false
    }

    var rankedPets: [AvatarSources.Pet] { AvatarSources.ranked(pets ?? [], query: petQuery) }
    var visiblePets: [AvatarSources.Pet] { Array(rankedPets.prefix(petLimit)) }
    func showMorePets() { petLimit = min(petLimit + Self.petPage, rankedPets.count) }

    /// One tile's thumbnail, fetched once (a failure is not kept, so the tile asks again next time).
    func loadThumb(_ pet: AvatarSources.Pet) async {
        guard thumbs[pet.slug] == nil, !thumbsInFlight.contains(pet.slug) else { return }
        thumbsInFlight.insert(pet.slug)
        if let data = await service.petThumb(pet) { thumbs[pet.slug] = data }
        thumbsInFlight.remove(pet.slug)
    }

    /// The pet's first frame becomes the picture (Desktop keeps it as the backend cropped it).
    func pickPet(_ pet: AvatarSources.Pet) async {
        loadingPet = pet.slug
        error = nil
        await loadThumb(pet)
        loadingPet = nil
        guard let data = thumbs[pet.slug] else {
            selectedPet = nil
            error = "Could not load \(pet.label)'s picture. Try again."
            return
        }
        selectedPet = pet.slug
        apply(.set(data))
    }
}

/// A face tile: the shape drawn the way Desktop draws it.
struct BotFaceImage: View {
    let shape: String
    let color: String?
    let name: String
    let size: CGFloat

    var body: some View {
        if let image = BotLook.render(shape: shape, color: color, name: name, edge: Int(size * 2)) {
            Image(decorative: image, scale: 2).frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

struct BotAvatarPickerView: View {
    @ObservedObject var picker: BotAvatarPickerModel
    /// What the host sheet has staged (the grid marks a staged shape).
    let staged: BotAvatarEdit
    let chooseImage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Picker("Avatar source", selection: $picker.tab) {
                ForEach(BotAvatarPickerModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch picker.tab {
            case .shape: shapeTab
            case .upload: uploadTab
            case .generate: generateTab
            case .pet: petTab
            }
            BotEditorErrorLine(text: picker.error)
        }
    }

    // MARK: shape

    private static let tile: CGFloat = 36
    private static let swatch: CGFloat = 20

    private var shapeTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1) {
                ForEach(BotLook.shapes, id: \.self) { s in
                    tileButton(selected: staged == .shape(s, color: picker.color), label: s) { picker.chooseShape(s) } content: {
                        BotFaceImage(shape: s, color: picker.color, name: picker.faceName, size: Self.tile - 6)
                    }
                }
                tileButton(selected: staged == .remove, label: "Monogram") { picker.monogram() } content: {
                    Text("Aa").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.muted)
                }
            }
            HStack(spacing: DS.Space.s1) {
                swatchButton(nil)
                ForEach(BotLook.swatches, id: \.self) { swatchButton($0) }
            }
            HStack(spacing: DS.Space.s2) {
                Button { picker.randomize() } label: { Label("Randomize", systemImage: "dice") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                Text("The first circle follows the bot's name.")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            }
        }
    }

    private func tileButton<C: View>(selected: Bool, label: String, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> C) -> some View {
        Button(action: action) {
            content()
                .frame(width: Self.tile, height: Self.tile)
                .background(selected ? DS.Palette.selected : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(selected ? DS.Palette.ring : .clear, lineWidth: DS.Stroke.hairline * 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(label)
    }

    private func swatchButton(_ css: String?) -> some View {
        let shown = BotLook.color(css, name: picker.faceName)
        let rgb = BotLook.rgb(shown) ?? (0, 0, 0)
        let selected = picker.color == css
        return Button { picker.chooseColor(css) } label: {
            Circle().fill(Color(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255))
                .frame(width: Self.swatch, height: Self.swatch)
                .overlay(Circle().strokeBorder(selected ? DS.Palette.ink : DS.Palette.hairline, lineWidth: selected ? 2 : 1))
                .overlay { if css == nil { Image(systemName: "textformat").font(.system(size: 8)).foregroundStyle(.white) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(css == nil ? "Match the name" : "Colour \(css!)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(css == nil ? "Match the name" : css!)
    }

    // MARK: upload

    private var uploadTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Button("Choose Image…") { chooseImage() }.buttonStyle(DSButtonStyle(kind: .secondary))
            Text("PNG or JPEG, up to 15 MB. Saved as a 256 px square.")
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
        }
    }

    // MARK: generate

    @ViewBuilder private var generateTab: some View {
        switch picker.imagen {
        case .unknown, .checking:
            HStack(spacing: DS.Space.s2) {
                ProgressView().controlSize(.small)
                Text("Checking for an image generator…").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
        case .unavailable:
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text("No image generator is set up in Hermes. Run `hermes tools` to enable one.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
                Button("Check Again") { Task { await picker.probe() } }.buttonStyle(DSButtonStyle(kind: .secondary))
            }
        case .available:
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                TextField("Describe the picture", text: $picker.prompt,
                          prompt: Text("Describe the picture (optional)"), axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder)
                HStack(spacing: DS.Space.s2) {
                    Button(picker.generating ? "Generating…" : "Generate") { Task { await picker.generate() } }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(picker.generating)
                    if picker.generating {
                        ProgressView().controlSize(.small)
                        Text("This can take a minute.").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    } else if picker.prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Empty: a robot mascot named after the bot.").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    }
                }
            }
        }
    }

    // MARK: pet

    private var petTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            if picker.petsLoading {
                HStack(spacing: DS.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("Loading the pet gallery…").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                }
            } else if let pets = picker.pets {
                if pets.isEmpty {
                    Text("No pets in the petdex gallery. Run `hermes pets` to explore.")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                } else {
                    TextField("Search pets", text: $picker.petQuery, prompt: Text("Search \(pets.count) pets"))
                        .textFieldStyle(.roundedBorder)
                    petGrid
                }
            } else {
                Button("Try Again") { Task { await picker.loadPets() } }.buttonStyle(DSButtonStyle(kind: .secondary))
            }
        }
    }

    private var petGrid: some View {
        let ranked = picker.rankedPets
        return VStack(alignment: .leading, spacing: DS.Space.s1) {
            if ranked.isEmpty {
                Text("No pets match.").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s1), count: 6), spacing: DS.Space.s1) {
                        ForEach(picker.visiblePets) { pet in petTile(pet) }
                    }
                    .padding(DS.Space.s1)
                }
                .frame(height: BotAvatarPickerLayout.petGridHeight)
                .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                if picker.petLimit < ranked.count {
                    Button("Show More (\(picker.petLimit) of \(ranked.count))") { picker.showMorePets() }
                        .buttonStyle(.link).font(DS.Typeface.meta)
                }
            }
        }
    }

    private func petTile(_ pet: AvatarSources.Pet) -> some View {
        let selected = picker.selectedPet == pet.slug
        return Button { Task { await picker.pickPet(pet) } } label: {
            VStack(spacing: DS.Space.s0) {
                ZStack {
                    if let data = picker.thumbs[pet.slug], let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.hover)
                    }
                    if picker.loadingPet == pet.slug { ProgressView().controlSize(.small) }
                }
                .frame(width: 40, height: 40)
                Text(pet.label).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(1).truncationMode(.tail)
            }
            .padding(DS.Space.s0)
            .background(selected ? DS.Palette.selected : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pet.label)
        .accessibilityLabel(pet.label)
        .task { await picker.loadThumb(pet) }
    }
}

enum BotAvatarPickerLayout {
    static let petGridHeight: CGFloat = 150
}

/// The preview tile both sheets show: the staged picture or face, else the bot's avatar now, else its monogram.
struct BotAvatarPreview: View {
    let staged: BotAvatarEdit
    let identity: BotIdentity
    /// The profile has a picture now (Edit); false for a new bot.
    let hasCurrentImage: Bool
    let faceName: String
    var size: CGFloat = BotEditorLayout.preview

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.avatar, style: .continuous)
        switch staged {
        case .set(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(shape).accessibilityLabel("New avatar")
            }
        case .shape(let s, let color):
            BotFaceImage(shape: s, color: color, name: faceName, size: size).accessibilityLabel("New avatar")
        case .unchanged where hasCurrentImage:
            AvatarView(identity: identity, size: size)
        case .unchanged, .remove:
            // The monogram the bot shows without an image (a profile key with no stored image).
            AvatarView(identity: BotIdentity(profile: "", title: identity.title, slot: identity.slot,
                                             uniqueMonogram: identity.monogram), size: size)
        }
    }
}
