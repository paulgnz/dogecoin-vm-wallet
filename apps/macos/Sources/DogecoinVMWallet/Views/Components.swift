import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// One network's balance, in that network's colour.
struct BalanceTile: View {
    let network: Network
    let amount: String?
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("On \(network.name)")
                .font(.headline)
                .foregroundStyle(Theme.ink(for: network))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(amount.map(formatDoge) ?? "…")
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("DOGE").foregroundStyle(Theme.inkSoft)
            }
            Text(note ?? network.speed)
                .font(.callout)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.wash(for: network), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6)
                .fill(Theme.color(for: network))
                .frame(width: 5)
        }
    }
}

extension Network {
    var speed: String { self == .dogecoin ? "A block about every minute" : "Final in about two seconds" }
}

/// The outcome of an action: success in teal, failure in red.
struct ResultLine: View {
    let result: ActionResult?

    var body: some View {
        if let result {
            Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.ok ? Theme.vmInk : Theme.bad)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ActionResult: Equatable {
    let ok: Bool
    let message: String
    static func success(_ m: String) -> ActionResult { .init(ok: true, message: m) }
    static func failure(_ e: Error) -> ActionResult { .init(ok: false, message: e.localizedDescription) }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        }
    }
}

/// A transaction ID, shortened, opening in the explorer.
struct TxLink: View {
    let txid: String
    let network: Network
    let server: URL

    var body: some View {
        Link(destination: url) {
            Text("\(txid.prefix(10))…\(txid.suffix(6))").font(.system(.callout, design: .monospaced))
        }
        .help(txid)
    }

    private var url: URL {
        network == .dogecoin
            ? URL(string: "https://blockchair.com/dogecoin/transaction/\(txid)")!
            : server.appendingPathComponent("/").appending(fragment: "/tx/\(txid)")
    }
}

extension URL {
    func appending(fragment: String) -> URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        c.fragment = fragment
        return c.url!
    }
}

/// A QR code of `text`, drawn sharp at any size.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
        }
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A labelled field in the wallet's forms.
struct Field: View {
    let label: String
    @Binding var text: String
    var monospaced = true
    var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? Theme.mono : .body)
                .autocorrectionDisabled()
        }
    }
}
