import SwiftUI

/// Floating panel showing recent decode / prefetch / upgrade events with
/// timestamps. Toggled by ⌘⇧L. Auto-scrolls to the newest entry.
struct DebugOverlay: View {
  @ObservedObject var log: LoadLog
  let onClose: () -> Void

  /// Briefly flips to `true` after a successful copy so the button
  /// icon swaps to a checkmark, then resets.
  @State private var justCopied: Bool = false

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider().opacity(0.4)

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(log.entries) { entry in
              row(for: entry)
                .id(entry.id)
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
        }
        .onChange(of: log.entries.last?.id) { _, newID in
          guard let newID else { return }
          withAnimation(.linear(duration: 0.08)) {
            proxy.scrollTo(newID, anchor: .bottom)
          }
        }
      }
    }
    .frame(width: 460, height: 320)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "terminal")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("Load log")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer()
      Text("\(log.entries.count)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      Button {
        copyEntriesToPasteboard()
      } label: {
        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
          .font(.caption)
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(.plain)
      .help("Copy log to clipboard")
      .disabled(log.entries.isEmpty)
      Button {
        log.clear()
      } label: {
        Image(systemName: "trash")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .help("Clear log")
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.plain)
      .help("Close (⌘⇧L)")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  /// Tab-separated, one entry per line: `HH:mm:ss.SSS<TAB>LEVEL<TAB>message`.
  /// Tabs (rather than fixed-width padding) so the result pastes
  /// cleanly into spreadsheets, GitHub issue templates, Slack code
  /// blocks, etc.
  private func copyEntriesToPasteboard() {
    let lines = log.entries.map { entry in
      "\(Self.timeFormatter.string(from: entry.timestamp))\t\(entry.level.rawValue.uppercased())\t\(entry.message)"
    }
    let text = lines.joined(separator: "\n")
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    flashCopied()
  }

  private func flashCopied() {
    withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      withAnimation(.easeIn(duration: 0.2)) { justCopied = false }
    }
  }

  private func row(for entry: LoadLog.Entry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(Self.timeFormatter.string(from: entry.timestamp))
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
      Text(entry.message)
        .font(.caption.monospaced())
        .foregroundStyle(color(for: entry.level))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func color(for level: LoadLog.Level) -> Color {
    switch level {
    case .info: return .primary
    case .warn: return .orange
    case .error: return .red
    }
  }
}
