import SwiftUI
import Vision
import AVKit
import CoreML
import Combine

// MARK: - LiquidGlass View Extensions

extension View {
    func liquidGlass(cornerRadius: CGFloat = 12) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
    }

    func glassButton(cornerRadius: CGFloat = 10) -> some View {
        self
            .frame(width: 34, height: 34)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}

struct TrackedPlate {
    var center: CGPoint
    var history: [String]
    var lastSeen: TimeInterval
    var firstSeen: TimeInterval
    var isLocked: Bool = false    // Once confirmed, OCR never fires again for this plate

    // Majority vote — only returns text once 3 reads agree.
    var bestText: String {
        let counts = history.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value }),
              best.value >= 3 else { return "" }
        return best.key
    }
}

// MARK: - Window Aspect Ratio Enforcer

struct AspectRatioEnforcer: NSViewRepresentable {
    let videoSize: CGSize
    let sidebarWidth: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }


func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        // Defer window geometry changes out of the layout pass to break the update loop.
        // Direct calls here trigger SwiftUI → AppKit → SwiftUI re-entry which crashes
        // when animations (like overlay dismiss) are in flight.
        DispatchQueue.main.async {
            if self.videoSize.width > 0 && self.videoSize.height > 0 {
                let ratio = CGSize(width: self.videoSize.width + self.sidebarWidth,
                                   height: self.videoSize.height)
                window.aspectRatio = ratio
                window.minSize = CGSize(width: 480 + self.sidebarWidth, height: 270)
            } else {
                window.resizeIncrements = NSSize(width: 1, height: 1)
                window.minSize = CGSize(width: 600, height: 400)
            }
        }
    }
}

// MARK: - Draggable Sidebar Divider

struct SidebarDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var isDragging = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isDragging ? Color.cyan.opacity(0.5) : Color.white.opacity(0.12))
                .frame(width: isDragging ? 2 : 1)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .cursor(.resizeLeftRight)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isDragging = true
                    let newWidth = width + value.translation.width
                    width = min(maxWidth, max(minWidth, newWidth))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var controller = TrafficController()
    @State private var showSidebar      = false
    @State private var showSettings     = false
    @State private var selectedLog: LogEntry? = nil
    @State private var selectedLogIndex: Int? = nil
    @State private var sidebarWidth: CGFloat  = 220

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        ZStack {
            Button("Open File") { importVideo() }
                .keyboardShortcut("o", modifiers: .command)
                .hidden()

            Button("Back5")  { controller.seek(by: -5) }
                .keyboardShortcut(.leftArrow,  modifiers: []).opacity(0).frame(width:0,height:0)
            Button("Fwd5")   { controller.seek(by: +5) }
                .keyboardShortcut(.rightArrow, modifiers: []).opacity(0).frame(width:0,height:0)

            AspectRatioEnforcer(
                videoSize:    controller.videoSize,
                sidebarWidth: showSidebar ? sidebarWidth : 0
            )
            .frame(width: 0, height: 0)

            VStack(spacing: 0) {
                HStack(spacing: 0) {

                    // ── Sidebar Log (LEFT) ───────────────────────────────────
                    if showSidebar {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(controller.isProcessing ? Color.green : Color.gray)
                                        .frame(width: 7, height: 7)
                                    Text("EVENTS")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(controller.isProcessing ? .green : .gray)
                                }
                                Spacer()
                                Text("\(controller.logs.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.gray.opacity(0.6))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial)
                            .overlay(
                                Rectangle().frame(height: 0.5)
                                    .foregroundColor(Color.white.opacity(0.15)),
                                alignment: .bottom
                            )

                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(controller.logs.enumerated()), id: \.element.id) { idx, log in
                                        LogEntryView(log: log, compact: sidebarWidth < 180)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(selectedLogIndex == idx
                                                ? Color.cyan.opacity(0.10)
                                                : Color.clear)
                                            .onTapGesture {
                                                selectedLogIndex = idx
                                                withAnimation { selectedLog = log }
                                            }
                                        Divider().background(Color.white.opacity(0.07))
                                    }
                                }
                            }
                        }
                        .frame(width: sidebarWidth)
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .leading))

                        SidebarDivider(width: $sidebarWidth, minWidth: 130, maxWidth: 360)
                    }

                    // ── Main Video Area ──────────────────────────────────────
                    ZStack {
                        Color.black

                            if let player = controller.player {
                                        VideoPlayer(player: player) {
                                            // This overlay sits BETWEEN the out-of-sync native video and the native controls.
                                            GeometryReader { geometry in
                                                ZStack {
                                                    // 1. A solid black background to "blindfold" the async video track
                                                    Color.black
                                                    
                                                    // 2. Our butter-smooth, perfectly synchronized ML frame
                                                    if let frame = controller.currentFrame {
                                                        Image(nsImage: frame)
                                                            .resizable()
                                                            .aspectRatio(contentMode: .fit)
                                                    }
                                                    
                                                    // 3. Our synchronized YOLO26 bounding boxes
                                                    BoundingBoxOverlay(
                                                        detections:    controller.detections,
                                                        containerSize: geometry.size,
                                                        videoSize:     controller.videoSize,
                                                        showConfidence: controller.showConfidenceLabels
                                                    )
                                                }
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            }
                                        }
                                    } else {
                                    VStack(spacing: 30) {
                                Image(systemName: "car.fill")
                                    .font(.system(size: 100))
                                    .foregroundColor(.cyan)
                                    .shadow(color: .cyan.opacity(0.6), radius: 20)

                                VStack(spacing: 10) {
                                    Text("iTrafficCam Pro")
                                        .font(.largeTitle)
                                        .fontWeight(.bold)
                                    Text("v\(appVersion)")
                                        .font(.headline)
                                        .foregroundColor(.cyan.opacity(0.8))
                                }

                                Button(action: { importVideo() }) {
                                    HStack {
                                        Image(systemName: "folder.fill")
                                        Text("Open Video File")
                                    }
                                    .font(.headline)
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 12)
                                    .foregroundColor(.cyan)
                                }
                                .buttonStyle(.plain)
                                .liquidGlass(cornerRadius: 10)
                                .contentShape(Rectangle())
                            }
                        }

                        VStack {
                            HStack(spacing: 8) {
                                Button(action: { withAnimation { showSidebar.toggle() } }) {
                                    Image(systemName: "sidebar.left")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                .glassButton()
                                .contentShape(Rectangle())
                                .keyboardShortcut("d", modifiers: [])

                                Button(action: { showSettings.toggle() }) {
                                    Image(systemName: "gearshape")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                .glassButton()
                                .contentShape(Rectangle())
                                .keyboardShortcut(",", modifiers: .command)
                                .popover(isPresented: $showSettings) {
                                    SettingsView(controller: controller)
                                }

                                Spacer()
                            }
                            .padding(12)
                            Spacer()
                        }
                    }
                    .frame(minWidth: 480, minHeight: 270)
                    .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
                        _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                            if let url = url { DispatchQueue.main.async { controller.loadVideo(url: url) } }
                        }
                        return true
                    }
                }
            }
            .onReceive(controller.$triggerSidebarShow) { show in
                if show && !showSidebar { withAnimation { showSidebar = true } }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenVideoFile"))) { _ in
                importVideo()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSNotification.Name("ToggleSidebar"))
            ) { _ in withAnimation { showSidebar.toggle() } }
            .onDisappear { controller.cleanup() }
            .background(TabKeyHandler(onTab: { withAnimation { showSidebar.toggle() } },
                                                  onSpace: { controller.togglePlayPause() }))
            
            // ── Expanded Log Overlay ─────────────────────────────────────────
            if let log = selectedLog {
                ZStack {
                    Color.black.opacity(0.85)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture { closeOverlay() }

                    Button("Dismiss") { closeOverlay() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0).frame(width: 0, height: 0)
                    Button("Prev") { navigateLog(by: -1) }
                        .keyboardShortcut(.upArrow, modifiers: [])
                        .opacity(0).frame(width: 0, height: 0)
                    Button("Next") { navigateLog(by: +1) }
                        .keyboardShortcut(.downArrow, modifiers: [])
                        .opacity(0).frame(width: 0, height: 0)

                    VStack(spacing: 20) {
                        HStack {
                            Spacer()
                            if !controller.logs.isEmpty {
                                Text("\((selectedLogIndex ?? 0) + 1) / \(controller.logs.count)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .padding(.trailing, 20)
                            }
                        }

                        ZStack {
                            Color.clear
                            
                            if let image = log.image {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .cornerRadius(12)
                                    .shadow(color: .cyan.opacity(0.3), radius: 25)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                    )
                                    .contextMenu {
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.writeObjects([image])
                                        } label: {
                                            Label("Copy Image", systemImage: "doc.on.doc")
                                        }
                                    }
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 80))
                                        .foregroundColor(.yellow)
                                    Text("Image Unavailable").foregroundColor(.gray)
                                }
                            }
                        }
                        .frame(maxWidth: 900, maxHeight: 600)
                        
                        
                        VStack(spacing: 8) {
                            Text(log.label.uppercased())
                                .font(.title)
                                .fontWeight(.black)
                                .foregroundColor(.cyan)
                            
                            // Show OCR plate text prominently if available
                            if let plate = log.plateText {
                                Text(plate)
                                    .font(.system(size: 36, weight: .black, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4), lineWidth: 1))
                            }

                            HStack(spacing: 20) {
                                Label("\(Int(log.confidence * 100))% Confidence", systemImage: "target")
                                Label(log.timestamp.formatted(date: .omitted, time: .standard), systemImage: "clock")
                            }
                            .foregroundColor(.white.opacity(0.8))
                            .font(.headline)
                        }
                        
                        HStack(spacing: 16) {
                        // Copy image to clipboard
                        if let image = log.image {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.writeObjects([image])
                            }) {
                                Label("Copy Image", systemImage: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .liquidGlass(cornerRadius: 8)
                            .contentShape(Rectangle())
                        }
                    }
                    
                    Text("↑ ↓ navigate  •  Esc or click to close")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.5))
                        .padding(.top, 2)
                    }
                    .padding()
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        
        .background(TabKeyHandler(onTab: { withAnimation { showSidebar.toggle() } },
                                          onSpace: { controller.togglePlayPause() }))
        .background(
                    Group {
                        Button("") { controller.stepFrame(forward: true) }
                            .keyboardShortcut("=", modifiers: [])
                        
                        Button("") { controller.stepFrame(forward: false) }
                            .keyboardShortcut("-", modifiers: [])
                    }
                    .opacity(0) // Keeps them completely hidden
                )
        
    }
    
    

    func closeOverlay() {
            // No animation on dismiss — animated overlay teardown while the ML pipeline
            // is publishing new state every 33ms causes layout pass overflow and crashes.
            selectedLog = nil
            selectedLogIndex = nil
        }
    
    func navigateLog(by delta: Int) {
        guard !controller.logs.isEmpty else { return }
        let current = selectedLogIndex ?? 0
        let next = max(0, min(controller.logs.count - 1, current + delta))
        selectedLogIndex = next
        selectedLog = controller.logs[next]
    }

    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, let url = panel.url {
            controller.loadVideo(url: url)
        }
    }
}

// MARK: - Tab Key Handler

struct TabKeyHandler: NSViewRepresentable {
    let onTab:   () -> Void
    var onSpace: (() -> Void)? = nil

    func makeNSView(context: Context) -> TabCatcherView {
        let view = TabCatcherView()
        view.onTab   = onTab
        view.onSpace = onSpace
        return view
    }
    func updateNSView(_ nsView: TabCatcherView, context: Context) {
        nsView.onTab   = onTab
        nsView.onSpace = onSpace
    }
}

class TabCatcherView: NSView {
    var onTab:   (() -> Void)?
    var onSpace: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 48: self?.onTab?();   return nil  // Tab
            case 49: self?.onSpace?(); return nil  // Space
            default: return event
            }
        }
    }
    deinit { if let monitor = monitor { NSEvent.removeMonitor(monitor) } }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var controller: TrafficController

    // ── Helper for perfectly aligned rows ──
    private func filterRow(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24, alignment: .center)
                .foregroundColor(.cyan)
            Text(title)
                .font(.body)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(height: 28)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            
            // ── Model Selection ──
            VStack(alignment: .leading, spacing: 12) {
                Text("Object Detection Model").font(.headline).foregroundColor(.gray)
                Picker("", selection: $controller.selectedModel) {
                    Text("off").tag("")
                    Text("Nano").tag("Nano")
                    Text("Small").tag("Small")
                    Text("Medium").tag("Medium")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            
            Divider()
            
            // ── Filters ──
            Text("Filters").font(.headline).foregroundColor(.gray)
            VStack(spacing: 8) {
                filterRow(title: "Vehicles",       icon: "car.fill",           isOn: $controller.filterVehicles)
                filterRow(title: "Bikes",          icon: "motorcycle.fill",    isOn: $controller.filterCycles)
                filterRow(title: "People",         icon: "person.2.fill",      isOn: $controller.filterPersons)
                filterRow(title: "Signs & lights", icon: "wrongwaysign",       isOn: $controller.filterSigns)
                filterRow(title: "Plate",          icon: "licenseplate",       isOn: $controller.filterPlates)
                filterRow(title: "Boats",          icon: "sailboat.fill",      isOn: $controller.filterBoats)
                filterRow(title: "Aircraft",       icon: "airplane",           isOn: $controller.filterAircraft)
            }
            
            Divider()
            
            // ── Settings & Sliders ──
            Text("Settings").font(.headline).foregroundColor(.gray)
            VStack(spacing: 15) {
                
                // Show Confidence Toggle
                HStack {
                    Text("Show Confidence % on Boxes")
                    Spacer()
                    Toggle("", isOn: $controller.showConfidenceLabels)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                
                // Slider 1: Visual Confidence
                VStack(alignment: .leading, spacing: 4) {
                    Text("Visual Confidence: \(Int(controller.confidenceThreshold * 100))%")
                        .font(.caption)
                    Slider(value: $controller.confidenceThreshold, in: 0.05...0.95)
                        .tint(.cyan)
                }
                
                // Slider 2: Log Confidence
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log Confidence: \(Int(controller.logConfidenceThreshold * 100))%")
                        .font(.caption)
                    Slider(value: $controller.logConfidenceThreshold, in: 0.05...0.95)
                        .tint(.cyan)
                }
                
                // Slider 3: Target Resolution
                VStack(alignment: .leading, spacing: 4) {
                    Text("Min Target Size: \(Int(controller.minDetailSize))px")
                        .font(.caption)
                    Slider(value: $controller.minDetailSize, in: 20...200)
                        .tint(.cyan)
                }
            }
            Divider()
            
            // ── Clear Logs Button ──
            Button(action: {
                withAnimation {
                    controller.logs.removeAll()
                }
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "trash")
                    Text("Clear Logs")
                    Spacer()
                }
                .font(.headline)
                .foregroundColor(.red)
                .padding(.vertical, 5)
            }
        }
        
        .padding(20)
        .frame(width: 320)
        
        .task {
            // Task.yield() suspends this task, letting the macOS Main Run Loop
            // finish its current layout/render pass.
            // The moment the UI is done drawing, this task automatically resumes!
            await Task.yield()
            controller.objectWillChange.send()
        }
    }
}


// MARK: - Log Entry View

struct LogEntryView: View {
    let log: LogEntry
    var compact: Bool = false
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let image = log.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: compact ? 44 : 58, height: compact ? 32 : 42)
                    .cornerRadius(4)
                    .clipped()
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(.ultraThinMaterial)
                    Image(systemName: "photo").foregroundColor(.gray).font(.system(size: 10))
                }
                .frame(width: compact ? 44 : 58, height: compact ? 32 : 42)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    if let plate = log.plateText {
                        Text(plate)
                            .font(.system(size: compact ? 10 : 12, weight: .black, design: .monospaced))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    } else {
                        Text(log.label.uppercased())
                            .font(.system(size: compact ? 9 : 11, weight: .bold))
                            .foregroundColor(log.label == "Plate" ? .orange : .cyan)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Text("\(Int(log.confidence * 100))%")
                        .font(.system(size: compact ? 9 : 10, weight: .bold, design: .monospaced))
                        .foregroundColor(log.confidence > 0.8 ? .green : .yellow)
                }

                Text(log.timestamp, style: .time)
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundColor(.gray)
                if !compact {
                    Text(isHovering ? "Click to expand" : String(log.id.uuidString.prefix(6)))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(isHovering ? .white : .gray.opacity(0.4))
                }
            }
        }
        .scaleEffect(isHovering ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .contentShape(Rectangle())
        .onHover { hover in isHovering = hover }
    }
}

// MARK: - Video Player

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if let layer = nsView.layer as? AVPlayerLayer { layer.frame = nsView.bounds }
    }
}

class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.videoGravity = .resizeAspect
        self.layer = playerLayer
        self.wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        playerLayer.frame = self.bounds
    }
}

// MARK: - Helper Structs

struct Detection: Identifiable {
    let id: UUID
    let rect: CGRect
    let label: String
    let confidence: Float
    var plateText: String? = nil
}

struct LogEntry: Identifiable {
    let id        = UUID()
    let timestamp = Date()
    let label:      String
    let confidence: Float
    var image:      NSImage? = nil
    var plateText:  String?  = nil   // OCR result when this is a plate entry
    var isComposite: Bool    = false // True = car crop with plate bbox drawn on it
    var plateRect:  CGRect?  = nil   // Normalized plate rect within the vehicle crop
}

// MARK: - Bounding Box Overlay

struct BoundingBoxOverlay: View {
    let detections:    [Detection]
    let containerSize: CGSize
    let videoSize:     CGSize
    let showConfidence: Bool
    
    var videoRect: CGRect {
        AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: containerSize))
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(detections) { det in
                let x = videoRect.minX + det.rect.origin.x * videoRect.width
                let y = videoRect.minY + det.rect.origin.y * videoRect.height
                
                // Safely calculate width and height to prevent negative or NaN crashes
                let rawW = det.rect.width  * videoRect.width
                let rawH = det.rect.height * videoRect.height
                let w = rawW.isFinite ? max(0, rawW) : 0
                let h = rawH.isFinite ? max(0, rawH) : 0
                
                let boxColor = det.label == "Plate" ? Color.orange : Color.cyan
                
                
                
                let isPlateRead = det.plateText != nil
                let displayText = det.plateText ?? det.label
                let fontSize: CGFloat = isPlateRead ? 18 : 10
                
                // Only show text if it's NOT a plate, OR if we have successfully read the plate text
                let shouldShowText = isPlateRead || det.label != "Plate"
                
                // ── BULLETPROOF UI: Absolute Paths (Impossible to stretch) ──
                ZStack(alignment: .topLeading) {
                    
                    Path { path in path.addRect(CGRect(x: x, y: y, width: w, height: h)) }
                        .fill(boxColor.opacity(0.20))
                    
                    Path { path in path.addRect(CGRect(x: x, y: y, width: w, height: h)) }
                        .stroke(boxColor, lineWidth: 2)
                    
                    // 3. The Text Label (Now hidden until OCR succeeds)
                    if shouldShowText {
                        Text(showConfidence ? "\(displayText) \(Int(det.confidence * 100))%" : displayText)
                            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4).stroke(boxColor.opacity(0.6), lineWidth: 0.5)
                            )
                            .fixedSize()
                            .position(x: x + (w / 2), y: y - (isPlateRead ? 18 : 14))
                    }
                }
            }
        }
    }
}

// MARK: - Extensions

extension View {
    func border(width: CGFloat, edges: [Edge], color: Color) -> some View {
        overlay(EdgeBorder(width: width, edges: edges).foregroundColor(color))
    }
}

struct EdgeBorder: Shape {
    var width: CGFloat
    var edges: [Edge]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
            switch edge {
            case .top:      x=0; y=0;                 w=rect.width;  h=width
            case .bottom:   x=0; y=rect.height-width; w=rect.width;  h=width
            case .leading:  x=0; y=0;                 w=width;       h=rect.height
            case .trailing: x=rect.width-width; y=0;  w=width;       h=rect.height
            }
            path.addRect(CGRect(x: x, y: y, width: w, height: h))
        }
        return path
    }
}

// MARK: - Traffic Controller



class TrafficController: NSObject, ObservableObject {
    @Published var player:       AVPlayer?
    @Published var currentFrame: NSImage?    = nil
    @Published var detections:   [Detection] = []
    @Published var logs:         [LogEntry]  = []

    @Published var selectedModel = "Medium"
    @Published var enablePlateDetector = true

    @Published var confidenceThreshold:    Float   = 0.20
    @Published var logConfidenceThreshold: Float   = 0.30
    @Published var minDetailSize:          CGFloat = 60.0

    @Published var showConfidenceLabels: Bool = false
    
    @Published var filterVehicles = true
    @Published var filterCycles   = true
    @Published var filterPersons  = true
    @Published var filterSigns    = true
    @Published var filterPlates   = true
    @Published var filterBoats    = false  // Disabled by default — rare in traffic footage
    @Published var filterAircraft = false  // Disabled by default — drone/aerial use only

    @Published var isPlaying     = false
    @Published var isProcessing  = false
    @Published var currentTime:  Double = 0.0
    @Published var duration:     Double = 1.0
    @Published var videoSize:    CGSize = .zero
    @Published var triggerSidebarShow = false
    private var isProcessingFrame = false
    private var trackedPlates: [TrackedPlate] = []

    var isScrubbing = false
    var lastLogTime: [String: Date] = [:]
    var hasAutoShownSidebar = false

    private var currentBuffer: CVPixelBuffer?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
    ])
    
    private var visionRequest:  VNCoreMLRequest?
    private var plateRequest:   VNCoreMLRequest?
    private var inferenceTimer: DispatchSourceTimer?
    private let visionQueue = DispatchQueue(label: "com.traffic.vision", qos: .userInitiated)
    private let ocrQueue      = DispatchQueue(label: "com.traffic.ocr",     qos: .utility)
    private let trackerQueue  = DispatchQueue(label: "com.traffic.tracker", qos: .userInitiated)
    private var ocrPending    = false
    
    // Temporary storage to merge detections from multiple models running simultaneously
    private var currentFrameDetections: [Detection] = []
    private var currentFrameLogs: [LogEntry] = []
    private var currentFrameDetectedSomething = false

    let classLabels: [Int: String] = [
        0: "Person", 1: "Bicycle", 2: "Car", 3: "Motorcycle",
        5: "Bus", 7: "Truck", 8: "Boat", 9: "Traffic Light", 11: "Stop Sign",
        4: "Airplane"
    ]

    private var cancellables = Set<AnyCancellable>()

        override init() {
            super.init()
            setupVision()
            
            // Re-init vision pipeline whenever the user picks a different model
            $selectedModel
                .dropFirst()
                .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.switchModel() }
                .store(in: &cancellables)
        }
    
    
    func setupVision() {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            
            // ── 1. CREATE OCR REQUEST TRULY ONCE ──
            // This sits outside the frame loop. It completely stops the GB memory leak,
            // allowing us to safely use the highly precise .accurate mode!
            let ocrRequest = VNRecognizeTextRequest()
            ocrRequest.recognitionLevel = .accurate
            ocrRequest.usesLanguageCorrection = false
            // -- THE NEW ALPR HACKS --
        
        
        
            // Bias the engine toward all 80 Serbian city codes
            ocrRequest.customWords = [
                    "AL", "AR", "AC", "BB", "BG", "BO", "BP", "BT", "BU", "BĆ", "VA", "VB", "VL", "VP", "VR", "VS", "VU", "GL", "GM", "DE", "ĐA", "ZA", "ZR", "IN", "IC", "JA", "KA", "KC", "KV", "KG", "KŽ", "KI", "KL", "KM", "KO", "KR", "KS", "KU", "LB", "LE", "LO", "LU", "NV", "NI", "NP", "NS", "PA", "PB", "PE", "PI", "PK", "PN", "PO", "PP", "PR", "PT", "PZ", "RA", "RU", "SA", "SM", "SD", "SJ", "SO", "SP", "ST", "SU", "TO", "TS", "TT", "ĆU", "UB", "UE", "UR", "UŽ", "ČA", "ŠA", "ŠI"
                ]
    

            // ── 2. Setup General Object Detection Model ──
            if selectedModel != "" && selectedModel != "Off" {
                let modelName: String
                switch selectedModel {
                case "Nano":   modelName = "yolo26n"
                case "Small":  modelName = "yolo26s"
                case "Medium": modelName = "yolo26m"
                default: modelName = "yolo26n"
                }

                if let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc"),
                   let coreMLModel = try? MLModel(contentsOf: modelURL, configuration: config),
                   let visionModel = try? VNCoreMLModel(for: coreMLModel) {
                    
                    visionRequest = VNCoreMLRequest(model: visionModel) { [weak self] request, _ in
                        guard let self = self,
                              let results = request.results as? [VNCoreMLFeatureValueObservation],
                              let multiArray = results.first?.featureValue.multiArrayValue else { return }
                        
                        // NO OCR HERE! We just decode and append the general objects.
                        var (dets, logs, found) = self.decodeOutput(multiArray, buffer: self.currentBuffer, isPlateDetector: false)
                                            
                        // Prevent Double-Boxing: If Plate Detector is on, strip plates from the General Model
                        if self.enablePlateDetector {
                            dets.removeAll(where: { $0.label == "Plate" })
                        }
                        
                        self.currentFrameDetections.append(contentsOf: dets)
                        self.currentFrameLogs.append(contentsOf: logs) // <--- THIS WAS MISSING
                        if found { self.currentFrameDetectedSomething = true } // <--- THIS WAS MISSING

                    }
                    visionRequest?.imageCropAndScaleOption = .scaleFill
                } else { print("General Model not found: \(modelName)") }
            } else {
                visionRequest = nil
            }
            
            // ── 3. Setup License Plate Detector Model ──
            if enablePlateDetector {
                if let plateURL = Bundle.main.url(forResource: "PlateDetector", withExtension: "mlmodelc"),
                   let plateCoreML = try? MLModel(contentsOf: plateURL, configuration: config),
                   let plateVision = try? VNCoreMLModel(for: plateCoreML) {
                    
                    plateRequest = VNCoreMLRequest(model: plateVision) { [weak self] request, _ in
                        guard let self = self,
                              let results = request.results as? [VNCoreMLFeatureValueObservation],
                              let multiArray = results.first?.featureValue.multiArrayValue else { return }
                        
                        var (dets, logs, found) = self.decodeOutput(multiArray, buffer: self.currentBuffer, isPlateDetector: true)
                        
                        // ── Apple Vision OCR — LOCKED + ASYNC ──
                        // Locked plates skip OCR entirely (zero CPU cost).
                        // Unlocked plates fire OCR on a separate queue so YOLO never waits.
                        if let validBuffer = self.currentBuffer {
                            for i in 0..<dets.count {
                                guard dets[i].label == "Plate" else { continue }

                                let currentCenter = CGPoint(x: dets[i].rect.midX, y: dets[i].rect.midY)
                                let currentTime   = CACurrentMediaTime()

                                // ── LOCK CHECK: serve cached text, skip OCR entirely ──
                                // trackerQueue.sync so reads are safe from visionQueue
                                let lockResult: (isLocked: Bool, bestText: String, matchIndex: Int?) =
                                    self.trackerQueue.sync {
                                        guard let idx = self.trackedPlates.firstIndex(where: {
                                            hypot($0.center.x - currentCenter.x, $0.center.y - currentCenter.y) < 0.15
                                        }) else { return (false, "", nil) }
                                        self.trackedPlates[idx].center   = currentCenter
                                        self.trackedPlates[idx].lastSeen = currentTime
                                        return (self.trackedPlates[idx].isLocked,
                                                self.trackedPlates[idx].bestText,
                                                idx)
                                    }

                                if lockResult.isLocked {
                                    dets[i].plateText = lockResult.bestText.isEmpty ? nil : lockResult.bestText
                                    continue
                                }
                                
                                
                                // ── SIZE GUARD: skip tiny plates ──
                                let rawX = dets[i].rect.origin.x
                                let rawY = dets[i].rect.origin.y
                                let rawW = dets[i].rect.width
                                let rawH = dets[i].rect.height
                                let platePixelW = rawW * self.videoSize.width
                                let platePixelH = rawH * self.videoSize.height
                                guard platePixelW >= self.minDetailSize * 1.5,
                                      platePixelH >= self.minDetailSize * 0.4 else { continue }

                                // ── OCR GATE: atomic check+set on trackerQueue ──
                                let canRun: Bool = self.trackerQueue.sync {
                                    guard !self.ocrPending else { return false }
                                    self.ocrPending = true
                                    return true
                                }
                                guard canRun else { continue }

                                
                                // Snapshot the rect values and buffer for the async closure
                                // No padding — the plate detector box already covers the glyphs.
                                // Expanding would include holder frame and promo text, adding OCR noise.
                                let flippedY = 1.0 - rawY - rawH
                                let clampedX = max(0.0, rawX)
                                let clampedY = max(0.0, flippedY)
                                let clampedW = min(rawW, 1.0 - clampedX)
                                let clampedH = min(rawH, 1.0 - clampedY)

                                guard clampedW > 0.02, clampedH > 0.01 else {
                                    self.ocrPending = false
                                    continue
                                }

                                let capturedCenter = currentCenter
                                let capturedTime   = currentTime

                                // ── FIRE OCR ASYNC — visionQueue is now free immediately ──
                                self.ocrQueue.async { [weak self] in
                                                                    guard let self = self else { return }
                                                                    defer { self.trackerQueue.async { self.ocrPending = false } }
                                    
                                    autoreleasepool {
                                        ocrRequest.regionOfInterest = CGRect(x: clampedX, y: clampedY,
                                                                              width: clampedW, height: clampedH)
                                        try? VNImageRequestHandler(cvPixelBuffer: validBuffer, options: [:]).perform([ocrRequest])

                                        guard let top = ocrRequest.results?.first?.topCandidates(1).first?.string else { return }

                                        if true {  // scope wrapper to match original brace structure
                                                                                    // ── THE PATTERN SCANNER ──
                                            // Strip non-alphanumeric, uppercase
                                            var alphanumeric = top.uppercased().replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)
                                            
                                            // Drop leading SRB sticker
                                            if alphanumeric.hasPrefix("SRB") {
                                                alphanumeric = String(alphanumeric.dropFirst(3))
                                            }
                                            
                                            var foundValidPlate = false
                                            var finalString = ""
                                            
                                            let validCities = ["AL", "AR", "AC", "BB", "BG", "BO", "BP", "BT", "BU", "BĆ", "VA", "VB", "VL", "VP", "VR", "VS", "VU", "GL", "GM", "DE", "ĐA", "ZA", "ZR", "IN", "IC", "JA", "KA", "KC", "KV", "KG", "KŽ", "KI", "KL", "KM", "KO", "KR", "KS", "KU", "LB", "LE", "LO", "LU", "NV", "NI", "NP", "NS", "PA", "PB", "PE", "PI", "PK", "PN", "PO", "PP", "PR", "PT", "PZ", "RA", "RU", "SA", "SM", "SD", "SJ", "SO", "SP", "ST", "SU", "TO", "TS", "TT", "ĆU", "UB", "UE", "UR", "UŽ", "ČA", "ŠA", "ŠI"]
                                            
                                            // ── POSITION-AWARE CORRECTION ──
                                            // Key insight: Serbian plates are always CITY(2) + NUMBERS(3-5) + TAIL(2).
                                            // We slice by position FIRST, then apply corrections only within each zone.
                                            // This prevents cross-zone corruption (e.g. "5" in the tail being kept as "5"
                                            // instead of being forced to "S", or "S" in the middle staying as "S"
                                            // instead of being forced to "5").
                                            
                                            // Zone corrections — applied ONLY to their correct zone, never globally
                                            let fixLetterZone = { (s: String) -> String in
                                                // Digits that look like letters — fix for city/tail zones only
                                                var r = s
                                                r = r.replacingOccurrences(of: "0", with: "O")
                                                r = r.replacingOccurrences(of: "1", with: "I")
                                                r = r.replacingOccurrences(of: "5", with: "S")
                                                r = r.replacingOccurrences(of: "8", with: "B")
                                                // Deliberately NOT: 2→Z (too aggressive, breaks real plates)
                                                return r
                                            }
                                            
                                            let fixDigitZone = { (s: String) -> String in
                                                // Letters that look like digits — fix for middle zone only
                                                var r = s
                                                r = r.replacingOccurrences(of: "O", with: "0")
                                                r = r.replacingOccurrences(of: "I", with: "1")
                                                r = r.replacingOccurrences(of: "S", with: "5")
                                                r = r.replacingOccurrences(of: "B", with: "8")
                                                r = r.replacingOccurrences(of: "Q", with: "0")
                                                // Deliberately NOT: Z→2, G→6 (too aggressive)
                                                // Strip anything still non-numeric (kills Coat of Arms residue)
                                                r = r.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
                                                return r
                                            }
                                            
                                            // ── SLIDING WINDOW SCANNER ──
                                            // Rules:
                                            // 1. City = first 2 chars always.
                                            // 2. Coat of Arms debris may insert 0-3 junk chars after city.
                                            // 3. Middle = 3, 4, or 5 digits.
                                            // 4. Tail = 2 letters immediately after middle.
                                            // 5. PREFER LONGEST valid middle — never stop at shortest.
                                            //    BG1941SV: middle=1941 (score 40) beats middle=194 (score 30).
                                            let chars = Array(alphanumeric)
                                            let totalChars = chars.count
                                            var bestMatch: (city: String, numbers: String, tail: String, score: Int)? = nil
                                            
                                            for skip in 0...3 {
                                                let middleStart = 2 + skip
                                                guard middleStart < totalChars else { break }
                                                
                                                for middleLen in 3...5 {
                                                    let tailStart = middleStart + middleLen
                                                    let tailEnd   = tailStart + 2
                                                    guard tailEnd <= totalChars else { continue }
                                                    
                                                    let citySlice   = String(chars.prefix(2))
                                                    let middleSlice = String(chars[middleStart..<tailStart])
                                                    let tailSlice   = String(chars[tailStart..<tailEnd])
                                                    
                                                    let cityFinal = fixLetterZone(citySlice)
                                                    let numbers   = fixDigitZone(middleSlice)
                                                    let tail      = fixLetterZone(tailSlice)
                                                    
                                                    guard validCities.contains(cityFinal) else { continue }
                                                    guard numbers.count >= 3 && numbers.count <= 5 else { continue }
                                                    guard tail.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { continue }
                                                    
                                                    // Score: more digits = better. Less junk skipped = better.
                                                    let score = numbers.count * 10 - skip
                                                    if bestMatch == nil || score > bestMatch!.score {
                                                        bestMatch = (cityFinal, numbers, tail, score)
                                                    }
                                                }
                                            }
                                            
                                            if let best = bestMatch {
                                                finalString = "\(best.city) \(best.numbers) \(best.tail)"
                                                foundValidPlate = true
                                            }
                                            
                                            
                                            // All tracker writes happen on trackerQueue — no data races
                                            self.trackerQueue.async {
                                                if let matchIndex = self.trackedPlates.firstIndex(where: {
                                                    hypot($0.center.x - capturedCenter.x, $0.center.y - capturedCenter.y) < 0.15
                                                }) {
                                                    if foundValidPlate {
                                                        self.trackedPlates[matchIndex].history.append(finalString)
                                                        if self.trackedPlates[matchIndex].history.count > 15 {
                                                            self.trackedPlates[matchIndex].history.removeFirst()
                                                        }
                                                    }

                                                    // Lock once confirmed
                                                    let best = self.trackedPlates[matchIndex].bestText
                                                    if !best.isEmpty {
                                                        self.trackedPlates[matchIndex].isLocked = true
                                                    }

                                                } else if foundValidPlate {
                                                    let newPlate = TrackedPlate(
                                                        center: capturedCenter,
                                                        history: [finalString],
                                                        lastSeen: capturedTime,
                                                        firstSeen: capturedTime
                                                    )
                                                    self.trackedPlates.append(newPlate)
                                                }

                                                // Expire stale plates
                                                self.trackedPlates.removeAll(where: {
                                                    CACurrentMediaTime() - $0.lastSeen > 0.4
                                                })
                                            }
                                            
                                            
                                        } // end if let top
                                    } // end autoreleasepool
                                } // end ocrQueue.async
                            } // end for i in dets
                        } // end if let validBuffer
                        
                        
                        self.currentFrameDetections.append(contentsOf: dets)
                                                
                        // Stamp confirmed plate text onto individual plate log entries
                        var stampedLogs = logs
                        for j in 0..<stampedLogs.count {
                            if stampedLogs[j].label == "Plate" {
                                let matchingPlate = dets.first(where: { $0.label == "Plate" && $0.plateText != nil })
                                stampedLogs[j].plateText = matchingPlate?.plateText
                            }
                        }
                        self.currentFrameLogs.append(contentsOf: stampedLogs)
                        
                        // ── COMPOSITE LOG: car crop + plate bbox + OCR text ──
                        // for-where on structs with optional binding requires a regular for+guard pattern
                        for plateDet in dets {
                            guard plateDet.label == "Plate", let plateText = plateDet.plateText else { continue }
                            
                            let vehicleDet = self.currentFrameDetections.first(where: { det in
                                let isVehicle = ["Car","Truck","Bus","Motorcycle","Bicycle"].contains(det.label)
                                guard isVehicle else { return false }
                                let expanded = det.rect.insetBy(dx: -0.05, dy: -0.05)
                                return expanded.contains(CGPoint(x: plateDet.rect.midX, y: plateDet.rect.midY))
                            })
                            
                            if let vehicle = vehicleDet,
                               let compositeImage = self.generateCompositeSnapshot(
                               vehicleRect: vehicle.rect,
                               plateRect: plateDet.rect,
                               plateText: plateText,
                               from: self.currentBuffer) {
                                let compositeKey = "composite_\(plateText)"
                                if self.shouldLog(label: compositeKey) {
                                    var entry = LogEntry(label: "Plate", confidence: plateDet.confidence, image: compositeImage)
                                    entry.plateText   = plateText
                                    entry.isComposite = true
                                    self.currentFrameLogs.append(entry)
                                    self.markLogTime(label: compositeKey)
                                }
                            }
                        }
                        
                        if found { self.currentFrameDetectedSomething = true }

                    }
                    plateRequest?.imageCropAndScaleOption = .scaleFill
                        
                    } else { print("Plate Detector model (PlateDetector.mlmodelc) not found in bundle.") }
            } else {
                plateRequest = nil
            }
        }

    // MARK: - Detection Decoder
    func decodeOutput(_ output: MLMultiArray, buffer: CVPixelBuffer?, isPlateDetector: Bool) -> ([Detection], [LogEntry], Bool) {
        let count  = 300
        let stride = 6
        let ptr    = UnsafeMutablePointer<Float>(OpaquePointer(output.dataPointer))

        var newDetections: [Detection] = []
        var logsToAdd: [LogEntry] = []
        var detectedSomething = false

        for i in 0..<count {
            let offset = i * stride
            let score  = ptr[offset + 4]
            guard score >= confidenceThreshold else { continue }

            let classIndex = Int(ptr[offset + 5])
            let label: String
            
            if isPlateDetector {
                // For the plate model, the only class is 0 (license-plate)
                guard classIndex == 0, filterPlates else { continue }
                label = "Plate"
            } else {
                guard isClassEnabled(classIndex), let validLabel = classLabels[classIndex] else { continue }
                label = validLabel
            }

            var x1 = CGFloat(ptr[offset])
            var y1 = CGFloat(ptr[offset + 1])
            var x2 = CGFloat(ptr[offset + 2])
            var y2 = CGFloat(ptr[offset + 3])

            if x2 > 1.0 || x1 > 1.0 { x1 /= 640; y1 /= 640; x2 /= 640; y2 /= 640 }

            let rect = CGRect(x: x1, y: y1, width: x2-x1, height: y2-y1)
            newDetections.append(Detection(id: UUID(), rect: rect, label: label, confidence: score))

            let pixelW = rect.width  * videoSize.width
            let pixelH = rect.height * videoSize.height
            let isVehicleOrPlate = ["Car","Truck","Bus","Motorcycle","Bicycle","Plate","Boat","Airplane"].contains(label)
            // Vehicles: covered by composite entries. Plates: covered by stamped plate entries.
            // Only log people, signs, and traffic lights here.
            if !isVehicleOrPlate && score >= logConfidenceThreshold && pixelW > minDetailSize && pixelH > minDetailSize && shouldLog(label: label) {
                if let snapshot = generateSnapshot(for: rect, from: buffer) {
                    logsToAdd.append(LogEntry(label: label, confidence: score, image: snapshot))
                    markLogTime(label: label)
                }
            }
            
            detectedSomething = true
        }

        return (newDetections, logsToAdd, detectedSomething)
    }

    // MARK: - Class Filter
    func isClassEnabled(_ index: Int) -> Bool {
        switch index {
        case 0:        return filterPersons
        case 1, 3:     return filterCycles
        case 2, 5, 7:  return filterVehicles
        case 8:        return filterBoats
        case 9, 11:    return filterSigns
        case 4:        return filterAircraft
        default:       return false
        }
    }
    
    func shouldLog(label: String) -> Bool {
        let now = Date()
        if let last = lastLogTime[label], now.timeIntervalSince(last) < 3.0 { return false }
        return true
    }

    func markLogTime(label: String) { lastLogTime[label] = Date() }

    func generateSnapshot(for normalizedRect: CGRect, from pixelBuffer: CVPixelBuffer?) -> NSImage? {
        guard let pixelBuffer = pixelBuffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width   = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height  = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let safeX = max(0, min(1, normalizedRect.origin.x))
        let safeY = max(0, min(1, normalizedRect.origin.y))
        let safeW = min(normalizedRect.width,  1 - safeX)
        let safeH = min(normalizedRect.height, 1 - safeY)
        guard safeW > 0.01, safeH > 0.01 else { return nil }

        let cropRect = CGRect(
            x: safeX * width,
            y: (1 - safeY - safeH) * height,
            width: safeW * width,
            height: safeH * height
        )
        let cropped  = ciImage.cropped(to: cropRect)
        let rep      = NSCIImageRep(ciImage: cropped)
        let nsImage  = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
    
    
    // Generates a car crop with the plate box and OCR text pill burned into the image.
        // Uses NSImage lockFocus so AppKit string drawing works correctly.
        func generateCompositeSnapshot(vehicleRect: CGRect, plateRect: CGRect, plateText: String, from pixelBuffer: CVPixelBuffer?) -> NSImage? {
            guard let pixelBuffer = pixelBuffer else { return nil }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let width   = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let height  = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

            // Expand vehicle crop 5% for breathing room
            let pad: CGFloat = 0.05
            let vX = max(0, vehicleRect.minX - vehicleRect.width  * pad)
            let vY = max(0, vehicleRect.minY - vehicleRect.height * pad)
            let vW = min(vehicleRect.width  * (1 + 2 * pad), 1 - vX)
            let vH = min(vehicleRect.height * (1 + 2 * pad), 1 - vY)
            guard vW > 0.02, vH > 0.02 else { return nil }

            // Crop vehicle from frame — CIImage is bottom-left origin
            let cropRect = CGRect(
                x: vX * width,
                y: (1 - vY - vH) * height,
                width: vW * width,
                height: vH * height
            )
            guard let cgBase = ciContext.createCGImage(ciImage.cropped(to: cropRect),
                                                       from: ciImage.cropped(to: cropRect).extent) else { return nil }

            let imgW = CGFloat(cgBase.width)
            let imgH = CGFloat(cgBase.height)
            let canvas = NSImage(size: NSSize(width: imgW, height: imgH))

            canvas.lockFocus()

            // 1. Draw the vehicle crop
            NSImage(cgImage: cgBase, size: NSSize(width: imgW, height: imgH))
                .draw(in: NSRect(x: 0, y: 0, width: imgW, height: imgH))

            // 2. Plate rect in pixel space — NSImage uses bottom-left origin so no Y flip needed
            let relX = (plateRect.minX - vX) / vW
            let relY = (plateRect.minY - vY) / vH
            let relW =  plateRect.width  / vW
            let relH =  plateRect.height / vH

            let pxX = relX * imgW
            let pxY = (1 - relY - relH) * imgH     // flip Y: YOLO top-left → NSImage bottom-left
            let pxW = relW * imgW
            let pxH = relH * imgH
            let plateBox = NSRect(x: pxX, y: pxY, width: pxW, height: pxH)

            // 3. Draw semi-transparent orange plate rect
            NSColor.orange.withAlphaComponent(0.15).setFill()
            plateBox.fill()
            NSColor.orange.setStroke()
            let boxPath = NSBezierPath(rect: plateBox)
            boxPath.lineWidth = max(2, imgW * 0.006)
            boxPath.stroke()

            // 4. Draw pill above the plate box
            let fontSize = max(12.0, pxH * 0.55)
            let font     = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .black)
            let attrs: [NSAttributedString.Key: Any] = [
                .font:            font,
                .foregroundColor: NSColor.white
            ]
            let textSize = plateText.size(withAttributes: attrs)
            let pillPad  = CGFloat(8)
            let pillW    = textSize.width  + pillPad * 2
            let pillH    = textSize.height + pillPad * 0.8

            // Centre pill over plate box, sit it just above (pxY + pxH in bottom-left space)
            let pillX    = pxX + (pxW - pillW) / 2
            let pillY    = pxY + pxH
            let pillRect = NSRect(x: pillX, y: pillY, width: pillW, height: pillH)

            // Pill background
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2)
            NSColor.black.withAlphaComponent(0.60).setFill()
            pillPath.fill()

            // Pill border
            NSColor.orange.withAlphaComponent(0.7).setStroke()
            pillPath.lineWidth = max(1, imgW * 0.003)
            pillPath.stroke()

            // Text — NSString draw works natively in lockFocus context
            let textX = pillRect.minX + pillPad
            let textY = pillRect.minY + (pillH - textSize.height) / 2
            plateText.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)

            canvas.unlockFocus()
            return canvas
        }
    

    func loadVideo(url: URL) {
        cleanup()
        // Give AVFoundation a clean slate — create a fresh output for every load.
        // Reusing the shared videoOutput across loads causes silent attach failures
        // on the new item, resulting in audio-only playback.
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ])
        let item  = AVPlayerItem(url: url)
        let asset = AVURLAsset(url: url)
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size  = try? await track.load(.naturalSize) {
                DispatchQueue.main.async { self.videoSize = size }
            }
            let dur = try? await asset.load(.duration)
            DispatchQueue.main.async { self.duration = dur?.seconds ?? 1.0 }
        }
        item.add(videoOutput)
        player       = AVPlayer(playerItem: item)
        player?.play()
        isPlaying    = true
        isProcessing = true
        startLoop()
    }

    func togglePlayPause() {
        guard let player = player else { return }
        if player.rate != 0 { player.pause(); isPlaying = false }
        else                 { player.play();  isPlaying = true  }
    }

    func seek(to time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by delta: Double) {
        guard let player = player else { return }
        seek(to: player.currentTime().seconds + delta)
    }

    func seekOneFrame(forward: Bool) {
        guard let player = player, let item = player.currentItem else { return }
        let currentSeconds = player.currentTime().seconds
        Task {
            let fps: Double
            if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
               let rate  = try? await track.load(.nominalFrameRate),
               rate > 0 {
                fps = Double(rate)
            } else {
                fps = 30.0
            }
            let target = currentSeconds + (forward ? 1.0/fps : -1.0/fps)
            await MainActor.run { seek(to: target) }
        }
    }

    func updateProgress() {
        if !isScrubbing, let player = player { currentTime = player.currentTime().seconds }
    }

    func switchModel() {
        DispatchQueue.main.async { self.detections = [] }
        setupVision()
    }

    func startLoop() {
        stopLoop()
        let queue = DispatchQueue(label: "com.traffic.loop", qos: .userInteractive)
        inferenceTimer = DispatchSource.makeTimerSource(queue: queue)
        inferenceTimer?.schedule(deadline: .now(), repeating: 0.033)
        inferenceTimer?.setEventHandler { [weak self] in self?.processFrame() }
        inferenceTimer?.resume()
    }

    func stopLoop() {
        inferenceTimer?.cancel()
        inferenceTimer = nil
    }

    func cleanup() {
            stopLoop()
            player?.pause()
            player        = nil
            currentBuffer = nil
            currentFrame  = nil
            detections    = []
            logs          = []
            lastLogTime.removeAll()
            hasAutoShownSidebar = false
        }
    
 
    
    func processFrame() {
            // 1. Drop the frame if the queue is busy (This stops the memory leak!)
            guard !isProcessingFrame else { return }
            
            // 2. Get the current time and check for a new buffer
            guard let currentItem = player?.currentItem else { return }
            let itemTime = currentItem.currentTime()
            
            guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
                  let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
                return
            }
            
            self.currentBuffer = pixelBuffer
            
            // 3. Extract the image for the UI right now while we have the buffer
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            var extractedImage: NSImage? = nil
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                extractedImage = NSImage(cgImage: cgImage, size: ciImage.extent.size)
            }
            
            // 4. Lock the gate
            isProcessingFrame = true
            
            // 5. Send to background queue
            visionQueue.async { [weak self] in
                guard let self = self else { return }
                
                // 6. UNLOCK THE GATE when finished, no matter what happens
                defer {
                    self.isProcessingFrame = false
                }
                
                // 7. The "Off" Switch bypasses inference but still draws the video
                if self.selectedModel == "Off" || self.selectedModel == "" {
                    DispatchQueue.main.async {
                        if let syncedFrame = extractedImage {
                            self.currentFrame = syncedFrame
                        }
                        self.detections = []
                    }
                    self.currentBuffer = nil
                    return
                }
                
                // 8. Gather active requests and run them
                var activeRequests: [VNRequest] = []
                if let r1 = self.visionRequest { activeRequests.append(r1) }
                if let r2 = self.plateRequest  { activeRequests.append(r2) }
                
                if !activeRequests.isEmpty {
                    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
                    try? handler.perform(activeRequests)
                }
                
                // 9. Scoop up all the accumulated detections/logs from the model handlers
                var finalDetections = self.currentFrameDetections
                
                // ── SPATIAL DEDUPLICATOR (KILLS DOUBLE BOXES) ──
                var deduplicated: [Detection] = []
                for det in finalDetections {
                    // Check if a box with the same label already exists in the exact same spot (within 5% screen distance)
                    let isDuplicate = deduplicated.contains { existing in
                        existing.label == det.label && hypot(existing.rect.midX - det.rect.midX, existing.rect.midY - det.rect.midY) < 0.05
                    }
                    if !isDuplicate {
                        deduplicated.append(det)
                    }
                }
                finalDetections = deduplicated
                // ───────────────────────────────────────────────
                
                let finalLogs = self.currentFrameLogs
                let finalDetectedSomething = self.currentFrameDetectedSomething
                
                // Clear the accumulators for the next frame
                self.currentFrameDetections = []
                self.currentFrameLogs = []
                self.currentFrameDetectedSomething = false
                
                // 10. Update the UI perfectly synchronized!
                DispatchQueue.main.async {
                    if let syncedFrame = extractedImage {
                        self.currentFrame = syncedFrame
                    }
                    self.detections = finalDetections
                    
                    if !finalLogs.isEmpty {
                        withAnimation {
                            self.logs.insert(contentsOf: finalLogs, at: 0)
                            if self.logs.count > 50 { self.logs.removeLast(self.logs.count - 50) }
                        }
                    }
                    
                    if finalDetectedSomething && !self.hasAutoShownSidebar {
                        self.hasAutoShownSidebar = true
                        self.triggerSidebarShow  = true
                    }
                }
                self.currentBuffer = nil
            }
        }
    
    // ── Frame Stepping ──
        func stepFrame(forward: Bool) {
            guard let playerItem = player?.currentItem else { return }
            
            // Pause the player so it doesn't keep running while we step
            player?.pause()
            
            // Step forward (+1) or backward (-1)
            playerItem.step(byCount: forward ? 1 : -1)
            
            // Force the ML pipeline to process this exact new frame immediately
            processFrame()
        }
    
    }
