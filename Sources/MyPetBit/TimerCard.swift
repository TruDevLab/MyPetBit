import AppKit
import SwiftUI

/// Состояние карточки таймера. Своё `ObservableObject`, а не `@State`: под Command Line Tools макросов SwiftUI нет.
@MainActor
final class TimerCardModel: ObservableObject {
    @Published var title = ""
    @Published var name = "" {
        didSet { onName?(name) }
    }
    @Published var coffee = false {
        didSet { onCoffee?(coffee) }
    }
    var onName: ((String) -> Void)?
    var onCoffee: ((Bool) -> Void)?
    var onDone: (() -> Void)?
    /// Курсор над карточкой или в ней печатают — сама не закрывается.
    var touched: (() -> Void)?
}

final class TimerCardPanel: NSPanel {
    // Не активирует приложение (стиль .nonactivatingPanel), но принимает ввод в поле названия.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Таймер уже идёт; карточка рядом с Битом предлагает название и кофе-режим на время таймера.
/// Всё по желанию: не трогать — через 10 секунд исчезнет сама.
@MainActor
final class TimerCard {
    static let size = NSSize(width: 270, height: 124)
    let model = TimerCardModel()
    private let panel: TimerCardPanel
    private var closeTimer: Timer?
    private var monitors: [Any] = []
    private(set) var isOpen = false

    init() {
        panel = TimerCardPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: TimerCardView(model: model))
        model.touched = { [weak self] in self?.scheduleClose(after: 20) }
    }

    /// Слева от Бита на уровне экрана; слева нет места — справа.
    func show(title: String, near anchor: NSRect) {
        model.title = title
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = Self.size
        var x = anchor.minX + anchor.width * 0.18 - size.width
        if x < screen.minX + 4 { x = anchor.maxX - anchor.width * 0.18 }
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        let y = min(max(anchor.midY - size.height / 2 + 10, screen.minY + 4), screen.maxY - size.height - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }, completionHandler: {
            MainActor.assumeIsolated { self.panel.alphaValue = 1 }
        })
        isOpen = true
        scheduleClose(after: 10)
        // Щелчок мимо карточки — готово.
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.close() }
            }
            return event
        }) { monitors.append(local) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        closeTimer?.invalidate()
        closeTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func scheduleClose(after seconds: TimeInterval) {
        guard isOpen else { return }
        closeTimer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        RunLoop.main.add(t, forMode: .common)
        closeTimer = t
    }
}

private struct TimerCardView: View {
    @ObservedObject var model: TimerCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "timer").foregroundStyle(Palette.glow)
                Text(model.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Button {
                    model.onDone?()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)
            }
            TextField(L("Название — по желанию"), text: $model.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(red: 0x2E / 255, green: 0x35 / 255, blue: 0x46 / 255)))
                .onSubmit { model.onDone?() }
                .onChange(of: model.name) { model.touched?() }
            HStack(spacing: 8) {
                Toggle("", isOn: $model.coffee).toggleStyle(BitToggle()).labelsHidden()
                Text(L("Кофе-режим, пока идёт таймер")).font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.dim)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: TimerCard.size.width, height: TimerCard.size.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.ink)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.glow.opacity(0.45), lineWidth: 1))
        )
        .onHover { if $0 { model.touched?() } }
        .onExitCommand { model.onDone?() }
        .focusEffectDisabled()
    }
}
