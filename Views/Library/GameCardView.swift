import SwiftUI
import ImageIO

/// 次世代流体玻璃风格游戏卡片（全面适配横竖屏自适应）
struct GameCardView: View {
    let game: Game
    let onPlay: () -> Void
    
    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    private var isLandscape: Bool { verticalSizeClass == .compact }
    
    var body: some View {
        Button(action: {
            HapticManager.shared.actionBurst()
            onPlay()
        }) {
            VStack(alignment: .leading, spacing: isLandscape ? 8 : 12) {
                // 封面图区域
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let uiImage = thumbnail {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            // 默认抽象几何科技感封面（深浅色自适应）
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [Color(red: 0.12, green: 0.18, blue: 0.32), Color(red: 0.05, green: 0.08, blue: 0.16)]
                                    : [Color(red: 0.92, green: 0.94, blue: 0.98), Color(red: 0.84, green: 0.88, blue: 0.96)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .overlay {
                                Image(systemName: game.engineType.iconName)
                                    .font(.system(size: isLandscape ? 32 : 40, weight: .light))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .indigo],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                        }
                    }
                    .frame(height: isLandscape ? 105 : 135)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(16)
                }
                
                // 游戏标题与状态
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title)
                        .font(.system(size: isLandscape ? 14 : 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    HStack {
                        Text(game.rootDirectoryName)
                            .font(.system(size: isLandscape ? 10 : 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        // 启动图标
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: isLandscape ? 18 : 20))
                            .foregroundStyle(Color.blue)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, isLandscape ? 4 : 6)
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.06), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(ScaleButtonStyle())
        .task(id: CoverThumbnailRequest(path: game.coverImageRelativePath,
                                       bookmark: game.securityBookmarkData,
                                       modified: game.coverImageModifiedAt,
                                       pixels: Int(230 * displayScale))) {
            thumbnail = nil
            let image = await CoverThumbnailCache.shared.load(
                path: game.coverImageRelativePath, bookmark: game.securityBookmarkData,
                maxPixels: Int(230 * displayScale))
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
        .onDisappear { thumbnail = nil }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct CoverThumbnailRequest: Hashable {
    let path: String?
    let bookmark: Data?
    let modified: Date?
    let pixels: Int
}

// ImageIO decodes only a card-sized thumbnail; the serial worker also bounds
// simultaneous decodes. Metadata invalidates changed covers without caching originals.
// Mutable work is confined to queue; NSCache supports concurrent access.
final class CoverThumbnailCache: @unchecked Sendable {
    static let shared = CoverThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "com.emu.cover.thumbnails", qos: .userInitiated)

    private init() { cache.totalCostLimit = 24 * 1024 * 1024 }

    func load(path: String?, bookmark: Data?, maxPixels: Int) async -> UIImage? {
        guard let path else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                var scopedURL: URL?
                if let bookmark {
                    var stale = false
                    guard let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                             relativeTo: nil, bookmarkDataIsStale: &stale),
                          url.startAccessingSecurityScopedResource() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    scopedURL = url
                }
                defer { scopedURL?.stopAccessingSecurityScopedResource() }
                let url = URL(fileURLWithPath: path)
                var result: UIImage?
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
                    let values = try? readable.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let key = "\(path)|\(maxPixels)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)" as NSString
                    if let cached = self.cache.object(forKey: key) { result = cached; return }
                    guard let source = CGImageSourceCreateWithURL(readable as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary),
                          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels)
                          ] as CFDictionary) else { return }
                    let image = UIImage(cgImage: cgImage)
                    self.cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
                    result = image
                }
                continuation.resume(returning: result)
            }
        }
    }
}
