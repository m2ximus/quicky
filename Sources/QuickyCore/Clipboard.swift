import AppKit

public enum Clipboard {
    static let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")

    /// Puts the capture on the pasteboard as a file, plus raw GIF data for apps that only accept images.
    public static func copy(_ url: URL, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if url.pathExtension.lowercased() == "gif", let data = try? Data(contentsOf: url) {
            item.setData(data, forType: gifType)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
