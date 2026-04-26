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

// MARK: - Window Aspect Ratio Enforcer

struct AspectRatioEnforcer: NSViewRepresentable {
    let videoSize: CGSize
    let sidebarWidth: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        if videoSize.width > 0 && videoSize.height > 0 {
            let ratio = CGSize(width: videoSize.width + sidebarWidth, height: videoSize.height)
            window.aspectRatio = ratio
            window.minSize = CGSize(width: 480 + sidebarWidth, height: 270)
        } else {
            window.resizeIncrements = NSSize(width: 1, height: 1)
            window.minSize = CGSize(width: 600, height: 400)
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
                                .keyboardShortcut("d", modifiers: [])

                                Button(action: { showSettings.toggle() }) {
                                    Image(systemName: "gearshape")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                .glassButton()
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
            .background(TabKeyHandler { withAnimation { showSidebar.toggle() } })

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
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 80))
                                        .foregroundColor(.yellow)
                                    Text("Image Unavailable").foregroundColor(.gray)
                                }
                            }
                        }
                        .frame(width: 900, height: 600)

                        VStack(spacing: 8) {
                            Text(log.label.uppercased())
                                .font(.title)
                                .fontWeight(.black)
                                .foregroundColor(.cyan)

                            HStack(spacing: 20) {
                                Label("\(Int(log.confidence * 100))% Confidence", systemImage: "target")
                                Label(log.timestamp.formatted(date: .omitted, time: .standard), systemImage: "clock")
                            }
                            .foregroundColor(.white.opacity(0.8))
                            .font(.headline)
                        }

                        Text("↑ ↓ navigate  •  Esc or click to close")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.5))
                            .padding(.top, 4)
                    }
                    .padding()
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        
        .background(TabKeyHandler { withAnimation { showSidebar.toggle() } })
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
    
    

    func closeOverlay() { withAnimation { selectedLog = nil } }

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
    let action: () -> Void
    func makeNSView(context: Context) -> NSView {
        let view = TabCatcherView()
        view.onTab = action
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TabCatcherView)?.onTab = action
    }
}

class TabCatcherView: NSView {
    var onTab: (() -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 48 { self?.onTab?(); return nil }
            return event
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
                    Text(log.label.uppercased())
                        .font(.system(size: compact ? 9 : 11, weight: .bold))
                        .foregroundColor(log.label == "Plate" ? .orange : .cyan)
                        .lineLimit(1)
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
}

struct LogEntry: Identifiable {
    let id        = UUID()
    let timestamp = Date()
    let label:      String
    let confidence: Float
    var image:      NSImage? = nil
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

                ZStack(alignment: .topLeading) {
                    Rectangle().stroke(boxColor, lineWidth: 2)
                    Rectangle().fill(boxColor.opacity(0.25))
                    Text(showConfidence ? "\(det.label) \(Int(det.confidence * 100))%" : "\(det.label)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(boxColor.opacity(0.6), lineWidth: 0.5)
                        )
                        .offset(y: -20)
                }
                .frame(width: w, height: h)
                .position(x: x + w/2, y: y + h/2)
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
    @Published var filterPlates   = true // Enabled by default

    @Published var isPlaying     = false
    @Published var isProcessing  = false
    @Published var currentTime:  Double = 0.0
    @Published var duration:     Double = 1.0
    @Published var videoSize:    CGSize = .zero
    @Published var triggerSidebarShow = false

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
    
    // Temporary storage to merge detections from multiple models running simultaneously
    private var currentFrameDetections: [Detection] = []
    private var currentFrameLogs: [LogEntry] = []
    private var currentFrameDetectedSomething = false

    let classLabels: [Int: String] = [
        0: "Person", 1: "Bicycle", 2: "Car", 3: "Motorcycle",
        5: "Bus", 7: "Truck", 8: "Boat", 9: "Traffic Light", 11: "Stop Sign"
    ]

    override init() {
        super.init()
        setupVision()
    }

    func setupVision() {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        // 1. Setup General Object Detection Model
        if selectedModel != "" {
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
                    
                    let (dets, logs, found) = self.decodeOutput(multiArray, buffer: self.currentBuffer, isPlateDetector: false)
                    self.currentFrameDetections.append(contentsOf: dets)
                    self.currentFrameLogs.append(contentsOf: logs)
                    if found { self.currentFrameDetectedSomething = true }
                }
                visionRequest?.imageCropAndScaleOption = .scaleFill
            } else { print("General Model not found: \(modelName)") }
        } else {
            visionRequest = nil
        }
        
        // 2. Setup License Plate Detector Model
        if enablePlateDetector {
            if let plateURL = Bundle.main.url(forResource: "PlateDetector", withExtension: "mlmodelc"),
               let plateCoreML = try? MLModel(contentsOf: plateURL, configuration: config),
               let plateVision = try? VNCoreMLModel(for: plateCoreML) {
                
                plateRequest = VNCoreMLRequest(model: plateVision) { [weak self] request, _ in
                    guard let self = self,
                          let results = request.results as? [VNCoreMLFeatureValueObservation],
                          let multiArray = results.first?.featureValue.multiArrayValue else { return }
                    
                    let (dets, logs, found) = self.decodeOutput(multiArray, buffer: self.currentBuffer, isPlateDetector: true)
                    self.currentFrameDetections.append(contentsOf: dets)
                    self.currentFrameLogs.append(contentsOf: logs)
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
            if score >= logConfidenceThreshold && pixelW > minDetailSize && pixelH > minDetailSize && shouldLog(label: label) {
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
        case 8:        return filterVehicles
        case 9, 11:    return filterSigns
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

    func loadVideo(url: URL) {
        cleanup()
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
            guard let playerItem = player?.currentItem else { return }
            let currentTime = playerItem.currentTime()
            
            if videoOutput.hasNewPixelBuffer(forItemTime: currentTime),
               let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) {
                
                // Extract the frame synchronously BEFORE passing to the background ML queue.
                // This ensures we have the exact visual frame that belongs to these boxes.
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                var extractedImage: NSImage? = nil
                if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    extractedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
                
                visionQueue.async { [weak self] in
                    guard let self = self else { return }
                    
                    // 1. Gather active models
                    var activeRequests: [VNRequest] = []
                    if let r1 = self.visionRequest { activeRequests.append(r1) }
                    if let r2 = self.plateRequest  { activeRequests.append(r2) }
                    
                    guard !activeRequests.isEmpty else { return }
                    
                    // 2. Clear temporary frame storage
                    self.currentBuffer = pixelBuffer
                    self.currentFrameDetections = []
                    self.currentFrameLogs = []
                    self.currentFrameDetectedSomething = false
                    
                    // 3. RUN BOTH MODELS SIMULTANEOUSLY
                    try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform(activeRequests)
                    
                    // 4. Capture the merged results
                    let finalDetections = self.currentFrameDetections
                    let finalLogs = self.currentFrameLogs
                    let finalDetectedSomething = self.currentFrameDetectedSomething
                    
                    // 5. ATOMIC UI UPDATE: Push frame and boxes at the exact same millisecond.
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
