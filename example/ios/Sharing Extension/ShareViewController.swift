import UIKit
import Social
import MobileCoreServices
import Photos

class ShareViewController: SLComposeServiceViewController {
    let imageContentType = kUTTypeImage as String
    let videoContentType = kUTTypeMovie as String
    let textContentType = kUTTypeText as String
    let urlContentType = kUTTypeURL as String
    let fileURLType = kUTTypeFileURL as String
    
    override func isContentValid() -> Bool {
        return true
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        guard
            let content = extensionContext?.inputItems.first as? NSExtensionItem,
            let attachments = content.attachments
        else {
            return
        }
        
        Task {
           await processAttachments(attachments)
        }
    }

    @MainActor
    func processAttachments(_ items: [NSItemProvider]) async {
        var sharedItems: [SharedItem] = []
        await items.asyncForEach { item in
            do {
                let parsed = try await parseAttachment(item)
                sharedItems.append(parsed)
            } catch {
                Logger.log("Failed to parse attachment: \(error)")
            }
        }
        
        notifyHostApp(sharedItems: sharedItems)
    }
    
    func parseAttachment(_ item: NSItemProvider) async throws -> SharedItem {
        if (item.hasItemConformingToTypeIdentifier(imageContentType)) {
            return try await processImage(item)
        }
        
        if (item.hasItemConformingToTypeIdentifier(videoContentType)) {
            return try await processVideo(item)
        }
        
        if (item.hasItemConformingToTypeIdentifier(fileURLType)) {
            return try await processFile(item)
        }
        
        if (item.hasItemConformingToTypeIdentifier(urlContentType)) {
            return try await processURL(item)
        }
        
        throw ShareError.invalidType
    }
        
        
    override func configurationItems() -> [Any]! {
        // To add configuration options via table cells at the bottom of the sheet, return an array of SLComposeSheetConfigurationItem here.
        return []
    }

    private func processText(_ item: NSItemProvider) async throws -> SharedItem {
        return try await processItem(item, typeIdentifier: textContentType) { data in
            guard let text = data as? String else {
                throw ShareError.invalidType
            }
            
            return .text(text)
        }
    }
    
    private func processURL(_ item: NSItemProvider) async throws -> SharedItem {
        return try await processItem(item, typeIdentifier: urlContentType) { data in
            guard let url = data as? URL else {
                throw ShareError.invalidType
            }
            
            return .url(url)
        }
    }
    
    private func processFile(_ item: NSItemProvider) async throws -> SharedItem {
        return try await processItem(item, typeIdentifier: fileURLType) { data in
            guard let url = data as? URL else {
                throw ShareError.invalidType
            }
            
            guard url.isFileURL else {
                return .url(url)
            }
            let newURL = try FileManager.copyFileToHost(fileURL: url)
            return .file(newURL)
        }
    }
    
    private func processImage(_ item: NSItemProvider) async throws -> SharedItem {
        return try await processItem(item, typeIdentifier: imageContentType) { data in
            guard let url = data as? URL else {
                throw ShareError.invalidType
            }
            
            guard url.isFileURL else {
                return .url(url)
            }
            
            
            let newURL = try FileManager.copyFileToHost(fileURL: url)
            return .image(newURL)
        }
    }
    
    private func processVideo(_ item: NSItemProvider) async throws -> SharedItem {
        return try await processItem(item, typeIdentifier: videoContentType) { data in
            guard let url = data as? URL else {
                throw ShareError.invalidType
            }
            
            guard url.isFileURL else {
                return .url(url)
            }
            
            let newURL = try FileManager.copyFileToHost(fileURL: url)
            let asset = AVAsset(url: newURL)
            let duration = (CMTimeGetSeconds(asset.duration) * 1000).rounded()
            let thumbnail = try self.generateThumbnail(asset: asset)
            return .video(SharedItem.VideoInfo(videoURL: newURL, previewURL: thumbnail, duration: duration))
        }
    }
    
    private func processItem(
        _ item: NSItemProvider,
        typeIdentifier: String,
        operation: @escaping (Any) throws -> SharedItem
    ) async throws -> SharedItem {
        return try await withCheckedThrowingContinuation { continuation in
            item.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                do {
                    let value = try operation(data as Any)
                    continuation.resume(with: .success(value))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    
    private func generateThumbnail(asset: AVAsset) throws -> URL {
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        assetImgGenerate.maximumSize =  CGSize(width: 360, height: 360)
        
        let fileName = "\(UUID().uuidString).png"
        let path = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.\(try! Bundle.main.hostBundleID())")!
            .appendingPathComponent(fileName)
        
        let img = try assetImgGenerate.copyCGImage(at: CMTimeMakeWithSeconds(600, preferredTimescale: Int32(1.0)), actualTime: nil)
        try UIImage.pngData(UIImage(cgImage: img))()?.write(to: path)
        
        return path
    }


    private func dismissWithError() {
        print("[ERROR] Error loading data!")
        let alert = UIAlertController(title: "Error", message: "Error loading data", preferredStyle: .alert)

        let action = UIAlertAction(title: "Error", style: .cancel) { _ in
            self.dismiss(animated: true, completion: nil)
        }

        alert.addAction(action)
        present(alert, animated: true, completion: nil)
        extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    private func notifyHostApp(sharedItems: [SharedItem]) {
        guard
            let hostBundleID = try? Bundle.main.hostBundleID(),
            let url = URL(string: "ShareMedia-\(hostBundleID)://newData")
        else {
            Logger.log("Failed to get host URL. Unable to notify host app.")
            return
        }
        
        guard
            let userDefaults = UserDefaults(suiteName: "group.\(hostBundleID)"),
            let data = try? JSONEncoder().encode(sharedItems)
        else {
            Logger.log("Failed to encode shared items")
            return
        }
        
        userDefaults.set(data, forKey: "sharedItems")
    
        var responder = self as UIResponder?
        let selectorOpenURL = sel_registerName("openURL:")
        while (responder != nil) {
            if (responder?.responds(to: selectorOpenURL))! {
                let _ = responder?.perform(selectorOpenURL, with: url)
            }
            responder = responder!.next
        }
        
        extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
    }
}

enum ShareError: Error {
    case invalidType
    case missingHostBundleID
    case invalidSharePath
}

enum SharedItem: Codable {
    case text(String)
    case image(URL)
    case video(VideoInfo)
    case file(URL)
    case url(URL)
        
    struct VideoInfo: Codable {
        let videoURL: URL
        let previewURL: URL
        let duration: Double
    }
}

/// https://www.swiftbysundell.com/articles/async-and-concurrent-forEach-and-map/
extension Sequence {
    func asyncForEach(
            _ operation: (Element) async throws -> Void
        ) async rethrows {
            for element in self {
                try await operation(element)
            }
        }
}

private struct Logger {
    static let logEnabled = true
    static func log(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        if (logEnabled) {
            print("\(fileID):\(line):\(function) \(message())")
        }
    }
}

extension FileManager {
    static func copyFileToHost(fileURL: URL, fileName: String? = nil) throws -> URL  {
        let hostBundleID = try Bundle.main.hostBundleID()
    
        let name = fileName ?? (fileURL.lastPathComponent.isEmpty ? UUID().uuidString : fileURL.lastPathComponent)
        
        let newURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.\(hostBundleID)")?
            .appendingPathComponent(name)
        
        guard let newURL = newURL else {
            throw ShareError.invalidSharePath
        }
        
        if FileManager.default.fileExists(atPath: newURL.path) {
            try FileManager.default.removeItem(at: newURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: newURL)
        
        return newURL
    }
}

extension Bundle {
    
    func hostBundleID() throws -> String {
        guard
            let bundleIdentifier = self.bundleIdentifier,
            let lastIndex = bundleIdentifier.lastIndex(of: ".")
        else {
            throw ShareError.missingHostBundleID
        }
        
        return String(bundleIdentifier[..<lastIndex])
    }
}
