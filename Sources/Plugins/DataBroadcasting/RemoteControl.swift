// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

/// The remote control of a TV, in a small floating panel that never takes the focus from the video.
final class RemoteControlPanel: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: true)

    init(press: @escaping (RemoteKey) -> Void) {
        super.init()
        panel.title = "リモコン"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        // also over the video in full screen
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: RemoteControlView(press: press))
        panel.setFrameAutosaveName("DataBroadcastingRemote")
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFront(nil)
    }

    func close() {
        panel.delegate = nil
        panel.close()
        panel.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private struct RemoteControlView: View {
    let press: (RemoteKey) -> Void

    var body: some View {
        VStack(spacing: 12) {
            button(.dataButton, width: 148) {
                Label("データ", systemImage: "d.square")
            }
            .help("データ放送の画面を出す・消す (G)")
            HStack(spacing: 4) {
                color(.blue, "青", Color(red: 0, green: 0.447, blue: 0.839), "F1")
                color(.red, "赤", Color(red: 0.788, green: 0, blue: 0), "F2")
                color(.green, "緑", Color(red: 0.106, green: 0.529, blue: 0), "F3")
                color(.yellow, "黄", Color(red: 0.89, green: 0.698, blue: 0), "F4")
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    arrow(.up, "chevron.up", "上")
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
                GridRow {
                    arrow(.left, "chevron.left", "左")
                    button(.enter, width: 46) { Text("決定").font(.callout) }
                    arrow(.right, "chevron.right", "右")
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    arrow(.down, "chevron.down", "下")
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            button(.back, width: 148) {
                Label("戻る", systemImage: "arrow.uturn.backward")
            }
            .help("戻る (delete)")
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<4, id: \.self) { row in
                    GridRow {
                        ForEach(1...3, id: \.self) { column in digit(row * 3 + column) }
                    }
                }
            }
            digit(0)
        }
        .padding(12)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func button<Label: View>(_ key: RemoteKey, width: CGFloat, @ViewBuilder label: () -> Label) -> some View {
        Button { press(key) } label: { label().frame(width: width - 16) }
    }

    private func arrow(_ key: RemoteKey, _ symbol: String, _ name: String) -> some View {
        button(key, width: 46) { Image(systemName: symbol) }
            .accessibilityLabel(name)
    }

    private func digit(_ number: Int) -> some View {
        button(RemoteKey.digit(number)!, width: 46) { Text("\(number)").monospacedDigit() }
    }

    private func color(_ key: RemoteKey, _ name: String, _ color: Color, _ shortcut: String) -> some View {
        Button { press(key) } label: {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 18, height: 14)
        }
        .accessibilityLabel(name)
        .help("\(name) (\(shortcut))")
    }
}
