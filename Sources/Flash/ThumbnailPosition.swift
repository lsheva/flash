/// Where the thumbnail browser is displayed relative to the main image.
enum ThumbnailPosition: String, CaseIterable, Identifiable {
    case hidden, bottom, trailing
    var id: String {
        rawValue
    }
}
