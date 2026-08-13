import Cocoa
import CoreImage
import CoreGraphics
import UniformTypeIdentifiers
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// ============================================================================
//  Repo Lines — a standalone macOS glass desktop widget.
//  Tracks multiple repos via tabs; each counts its lines into four buckets.
//  Per-repo custom display name + logo. Real behind-window vibrancy, sits on
//  the desktop behind app windows. The opacity slider fades only the frosted
//  centre, never the text/logo/bezel.
// ============================================================================

// ---- line accounting -------------------------------------------------------

struct Totals {
    var code = 0, docs = 0, datasets = 0, thirdparty = 0, files = 0
    var langs: [String: Int] = [:]     // authored lines per language (code + docs)
    var written: Int { code + docs }
    var bundled: Int { datasets + thirdparty }
    var total: Int { written + bundled }
}

let binaryExt: Set<String> = [
    "png","webp","jpg","jpeg","gif","ico","icns","ttf","otf","woff","woff2","eot",
    "gz","zip","tar","pdf","mp4","mov","mp3","wav","parquet","sqlite","db",
    "so","dylib","a","o","class","jar","wasm","bin","exe","dll","psd","sketch"
]
let lockNames: Set<String> = [
    "package-lock.json","yarn.lock","pnpm-lock.yaml","gemfile.lock",
    "poetry.lock","cargo.lock","composer.lock","podfile.lock","flake.lock"
]

func bucket(_ path: String) -> String {
    let p = path.lowercased()
    let base = (path as NSString).lastPathComponent
    if lockNames.contains(base.lowercased()) { return "thirdparty" }
    if p.hasSuffix(".min.js") || p.hasSuffix(".min.css") { return "thirdparty" }
    if p.contains("/vendor/") || p.hasPrefix("vendor/") ||
       p.contains("/third_party/") || p.contains("/vendored/") { return "thirdparty" }
    if p == "vendor-pdf_viewer.css" { return "thirdparty" }
    if p.hasPrefix("assets/bank-logos/") && p.hasSuffix(".svg") { return "thirdparty" }
    if p.hasPrefix("lib/core/data/") && p.hasSuffix(".json") { return "datasets" }
    for e in ["csv","tsv","geojson","ndjson"] where p.hasSuffix("." + e) { return "datasets" }
    for e in ["md","txt","rst","adoc"] where p.hasSuffix("." + e) { return "docs" }
    if base == "LICENSE" || base == "COPYING" { return "docs" }
    return "code"
}

func runGit(_ root: String, _ args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["git", "-C", root] + args
    let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
    do { try proc.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 { return nil }
    return String(data: data, encoding: .utf8)
}

func gitFiles(_ root: String) -> [String]? {
    guard let s = runGit(root, ["ls-files"]) else { return nil }
    let arr = s.split(separator: "\n").map(String.init)
    return arr.isEmpty ? nil : arr
}

// Cheap change-detector: HEAD + working-tree status. If unchanged since the last
// scan, we skip the expensive re-read so refreshes are instant.
func repoSignature(_ root: String) -> String {
    let head = runGit(root, ["rev-parse", "HEAD"]) ?? ""
    let status = runGit(root, ["status", "--porcelain=v1"]) ?? ""
    return head + status
}

func walkFiles(_ root: String) -> [String] {
    var res = [String]()
    let fm = FileManager.default
    let baseURL = URL(fileURLWithPath: root)
    let skip: Set<String> = [".git", "node_modules", "dist", "build", ".next", "vendor", "Pods"]
    guard let en = fm.enumerator(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return res }
    for case let url as URL in en {
        if skip.contains(url.lastPathComponent) {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { en.skipDescendants() }
            continue
        }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if !isDir { res.append(String(url.path.dropFirst(root.count + 1))) }
    }
    return res
}

func scan(_ root: String) -> Totals {
    var t = Totals()
    let files = gitFiles(root) ?? walkFiles(root)
    let fm = FileManager.default
    for f in files {
        let ext = (f as NSString).pathExtension.lowercased()
        if binaryExt.contains(ext) { continue }
        guard let data = fm.contents(atPath: root + "/" + f) else { continue }
        var lines = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0, let hit = memchr(p, 0x0A, remaining) {
                lines += 1
                let consumed = UnsafeRawPointer(hit) - p + 1
                p = UnsafeRawPointer(hit).advanced(by: 1)
                remaining -= consumed
            }
        }
        let b = bucket(f)
        switch b {
        case "docs":       t.docs += lines
        case "datasets":   t.datasets += lines
        case "thirdparty": t.thirdparty += lines
        default:           t.code += lines
        }
        t.files += 1
        // language breakdown over authored files only (exclude bundled data/vendored)
        if b == "code" || b == "docs" { t.langs[language(for: f), default: 0] += lines }
    }
    return t
}

// ---- styling ---------------------------------------------------------------

var ACCENT    = NSColor(red: 0.373, green: 0.816, blue: 0.769, alpha: 1)   // teal #5fd0c4
var TXT       = NSColor.white
var TXT_DIM   = NSColor(white: 1, alpha: 0.62)
var TXT_FAINT = NSColor(white: 1, alpha: 0.42)

enum FontStyle: Int { case system, rounded, serif, mono }
var FONT_STYLE: FontStyle = .system

func themedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    switch FONT_STYLE {
    case .system:  return base
    case .rounded: return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    case .serif:   return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    case .mono:    return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

let grouper: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","; return f
}()
func fmt(_ n: Int) -> String { grouper.string(from: NSNumber(value: n)) ?? "\(n)" }

func attr(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ tracking: CGFloat = 0) -> NSAttributedString {
    let sh = NSShadow()
    sh.shadowColor = NSColor(white: 0, alpha: 0.55)
    sh.shadowBlurRadius = 6
    sh.shadowOffset = NSSize(width: 0, height: -1)
    var a: [NSAttributedString.Key: Any] = [
        .font: themedFont(size, weight),
        .foregroundColor: color, .shadow: sh
    ]
    if tracking != 0 { a[.kern] = tracking }
    return NSAttributedString(string: text, attributes: a)
}

func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ tracking: CGFloat = 0) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.isBezeled = false; l.drawsBackground = false; l.isEditable = false; l.alignment = .center
    l.attributedStringValue = attr(text, size, weight, color, tracking)
    return l
}

final class StatView: NSStackView {
    let num = NSTextField(labelWithString: "—")
    let cap: NSTextField
    let caption: String
    let muted: Bool
    var current = "—"
    var color: NSColor { muted ? TXT_DIM : TXT }
    init(caption: String, muted: Bool) {
        self.caption = caption; self.muted = muted
        cap = label(caption, 10.5, .regular, TXT_FAINT)
        super.init(frame: .zero)
        num.isBezeled = false; num.drawsBackground = false; num.isEditable = false; num.alignment = .center
        num.attributedStringValue = attr("—", 17, .semibold, color)
        orientation = .vertical; spacing = 1; alignment = .centerX
        addArrangedSubview(num); addArrangedSubview(cap)
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ v: String) { current = v; num.attributedStringValue = attr(v, 17, .semibold, color) }
    func restyle() {
        num.attributedStringValue = attr(current, 17, .semibold, color)
        cap.attributedStringValue = attr(caption, 10.5, .regular, TXT_FAINT)
    }
}

// GitHub-style language colours (linguist-ish), keyed by extension → (name, hex).
let LANGS: [(ext: String, name: String, hex: String)] = [
    ("js","JavaScript","f1e05a"), ("mjs","JavaScript","f1e05a"), ("cjs","JavaScript","f1e05a"),
    ("jsx","JavaScript","f1e05a"), ("ts","TypeScript","3178c6"), ("tsx","TypeScript","3178c6"),
    ("swift","Swift","F05138"), ("py","Python","3572A5"), ("rb","Ruby","701516"),
    ("go","Go","00ADD8"), ("rs","Rust","dea584"), ("java","Java","b07219"),
    ("kt","Kotlin","A97BFF"), ("c","C","555555"), ("h","C","555555"),
    ("cpp","C++","f34b7d"), ("cc","C++","f34b7d"), ("hpp","C++","f34b7d"),
    ("cs","C#","178600"), ("php","PHP","4F5D95"), ("html","HTML","e34c26"),
    ("css","CSS","563d7c"), ("scss","SCSS","c6538c"), ("less","Less","1d365d"),
    ("json","JSON","8a8a8a"), ("yml","YAML","cb171e"), ("yaml","YAML","cb171e"),
    ("toml","TOML","9c4221"), ("md","Markdown","083fa1"), ("markdown","Markdown","083fa1"),
    ("sh","Shell","89e051"), ("bash","Shell","89e051"), ("zsh","Shell","89e051"),
    ("plist","XML","0060ac"), ("xml","XML","0060ac"), ("txt","Text","aaaaaa"),
    ("svg","SVG","ff9900"), ("sql","SQL","e38c00"),
]
func hexColor(_ hex: String) -> NSColor {
    var v: UInt64 = 0; Scanner(string: hex).scanHexInt64(&v)
    return NSColor(red: CGFloat((v>>16)&0xff)/255, green: CGFloat((v>>8)&0xff)/255, blue: CGFloat(v&0xff)/255, alpha: 1)
}
let EXT_LANG: [String: String] = Dictionary(LANGS.map { ($0.ext, $0.name) }, uniquingKeysWith: { a, _ in a })
let LANG_COLOR: [String: NSColor] = Dictionary(LANGS.map { ($0.name, hexColor($0.hex)) }, uniquingKeysWith: { a, _ in a })
func language(for path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    return EXT_LANG[ext] ?? (ext.isEmpty ? "Other" : ext.uppercased())
}
func colorFor(_ name: String) -> NSColor { LANG_COLOR[name] ?? NSColor(white: 0.55, alpha: 1) }

// A GitHub-style segmented percentage bar.
final class LangBar: NSView {
    var segments: [(NSColor, CGFloat)] = []   // (colour, fraction 0…1)
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSBezierPath(roundedRect: r, xRadius: r.height/2, yRadius: r.height/2).addClip()
        if segments.isEmpty { NSColor(white: 1, alpha: 0.12).setFill(); r.fill(); return }
        var x: CGFloat = 0
        for (c, f) in segments {
            let w = r.width * f
            c.setFill()
            NSRect(x: x, y: 0, width: ceil(w) + 0.5, height: r.height).fill()
            x += w
        }
    }
}

// A borderless button that renders like a centred label (used for the name/logo
// so they can be clicked to rename / pick a logo).
func textButton(_ target: AnyObject, _ action: Selector, tip: String) -> NSButton {
    let b = NSButton(); b.isBordered = false; b.bezelStyle = .regularSquare; b.title = ""
    b.target = target; b.action = action; b.toolTip = tip
    return b
}

// ---- widget ----------------------------------------------------------------

// Live desktop refraction. Captures the screen region directly behind the widget
// (excluding the widget itself, so no feedback), runs a glass distortion on that
// real backdrop, and hands back a CGImage to paint into the bezel ring.
@available(macOS 14.0, *)
final class Refractor: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "refractor.frames")
    private var noise: CIImage?
    var onImage: ((CGImage) -> Void)?
    var onError: ((String) -> Void)?
    var scale: CGFloat = 14      // glass distortion strength (live-tunable)
    var blur: CGFloat = 5        // frosting amount (live-tunable)

    private func makeConfig(f: CGRect, sf: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: f.minX - sf.minX, y: sf.maxY - f.maxY, width: f.width, height: f.height)
        cfg.width = Int(f.width * scale); cfg.height = Int(f.height * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false; cfg.queueDepth = 3
        return cfg
    }

    // Enumerate shareable content (the ONLY thing that checks Screen Recording
    // permission) exactly once, here at startup.
    func start(window: NSWindow) {
        guard stream == nil,
              let scr = window.screen ?? NSScreen.main,
              let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let did = num.uint32Value
        let ourID = CGWindowID(window.windowNumber)
        let f = window.frame, scale = scr.backingScaleFactor, sf = scr.frame
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.current
                guard let disp = content.displays.first(where: { $0.displayID == did }) else { return }
                let excl = content.windows.filter { $0.windowID == ourID }
                let filter = SCContentFilter(display: disp, excludingWindows: excl)
                let s = SCStream(filter: filter, configuration: self.makeConfig(f: f, sf: sf, scale: scale), delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await s.startCapture()
                self.stream = s
            } catch { self.onError?("\(error)") }
        }
    }

    // On move we only re-point the capture region — no content enumeration, so no
    // repeated permission prompt.
    func updateRegion(window: NSWindow) {
        guard let s = stream, let scr = window.screen ?? NSScreen.main else { return }
        let cfg = makeConfig(f: window.frame, sf: scr.frame, scale: scr.backingScaleFactor)
        Task { try? await s.updateConfiguration(cfg) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let px = sb.imageBuffer else { return }
        var ci = CIImage(cvImageBuffer: px)
        let extent = ci.extent
        if noise == nil || noise!.extent.width < extent.width {
            noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
                .cropped(to: extent).applyingGaussianBlur(sigma: 2)
        }
        if let noise, let g = CIFilter(name: "CIGlassDistortion",
                                       parameters: [kCIInputImageKey: ci, "inputTexture": noise, "inputScale": scale]),
           let out = g.outputImage {
            ci = out.cropped(to: extent)
        }
        if blur > 0.1 { ci = ci.applyingGaussianBlur(sigma: Double(blur)).cropped(to: extent) }   // frost it
        guard let cg = ciContext.createCGImage(ci, from: extent) else { return }
        DispatchQueue.main.async { [weak self] in self?.onImage?(cg) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?("\(error)") }
}

// Borderless windows can't become key by default, which blocks interaction.
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class WidgetController: NSObject {
    struct Repo: Codable { var path: String; var name: String?; var logo: String? }

    let window: NSWindow
    let radius: CGFloat = 20
    let bezelW: CGFloat = 3
    var bgOpacity: CGFloat
    var frost: NSVisualEffectView!

    var repos: [Repo] = []
    var active = 0
    var cache: [String: Totals] = [:]
    var lastSig: [String: String] = [:]
    var snapTimer: Timer?
    var bezelView: NSView?
    var refractor: AnyObject?
    var settingsWindow: NSWindow?
    var dividerLabel: NSTextField?
    // glass params (live-tunable via the settings panel, persisted)
    var gScale: CGFloat = 14, gBlur: CGFloat = 5, gOpacity: CGFloat = 0.5, gWidth: CGFloat = 16, gFeather: CGFloat = 6
    var gRows: [(kp: ReferenceWritableKeyPath<WidgetController, CGFloat>, value: NSTextField)] = []
    var activeRepo: Repo? { repos.indices.contains(active) ? repos[active] : nil }
    func displayName(_ r: Repo) -> String { r.name ?? (r.path as NSString).lastPathComponent }

    let tabBar = NSStackView()
    let logoBtn = NSButton()
    let nameBtn = NSButton()
    let hero = NSTextField(labelWithString: "—")
    let sub  = NSTextField(labelWithString: "lines written — and counting")
    let stCode = StatView(caption: "code & config", muted: false)
    let stDocs = StatView(caption: "documentation", muted: false)
    let stData = StatView(caption: "core datasets", muted: true)
    let stThird = StatView(caption: "third-party", muted: true)
    let foot = NSTextField(labelWithString: "")
    let langBar = LangBar()
    let langLegend = NSStackView()

    override init() {
        window = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 452),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let savedBg = UserDefaults.standard.object(forKey: "bgOpacity") as? Double
        bgOpacity = CGFloat(savedBg ?? 0.9)
        super.init()
        loadGlass()
        loadTheme()
        loadRepos()
        buildWindow()
        rebuildTabs()
        selectActive(refreshNow: true)
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: persistence
    func loadRepos() {
        if let d = UserDefaults.standard.data(forKey: "repos"),
           let arr = try? JSONDecoder().decode([Repo].self, from: d) { repos = arr }
        active = UserDefaults.standard.integer(forKey: "activeRepo")
        if repos.isEmpty, let old = UserDefaults.standard.string(forKey: "repoPath"),
           FileManager.default.fileExists(atPath: old) {
            repos = [Repo(path: old, name: nil, logo: nil)]   // migrate an older single-repo setting
        }
        // no repos yet -> the widget shows an "add a repo" state on first launch
        if !repos.indices.contains(active) { active = 0 }
    }
    func saveRepos() {
        if let d = try? JSONEncoder().encode(repos) { UserDefaults.standard.set(d, forKey: "repos") }
        UserDefaults.standard.set(active, forKey: "activeRepo")
    }

    // MARK: mask helpers
    static func roundedMask(size: NSSize, radius: CGFloat) -> NSImage {
        return NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }
    static func ringPath(_ rect: CGRect, _ radius: CGFloat, _ thickness: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        let ir = rect.insetBy(dx: thickness, dy: thickness)
        let irad = max(1, radius - thickness)
        p.addRoundedRect(in: ir, cornerWidth: irad, cornerHeight: irad)
        return p
    }

    // A soft-edged (feathered) ring mask so the refraction fades into the panel
    // instead of showing a hard band boundary.
    static func featheredRing(size: NSSize, radius: CGFloat, thickness: CGFloat, feather: CGFloat) -> CGImage? {
        let img = NSImage(size: size, flipped: false) { rect in
            let p = NSBezierPath(); p.windingRule = .evenOdd
            p.appendRoundedRect(rect, xRadius: radius, yRadius: radius)
            let ir = rect.insetBy(dx: thickness, dy: thickness)
            let r2 = max(1, radius - thickness)
            p.appendRoundedRect(ir, xRadius: r2, yRadius: r2)
            NSColor.white.setFill(); p.fill()
            return true
        }
        guard let tiff = img.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let out = ci.applyingGaussianBlur(sigma: feather).cropped(to: ci.extent)
        return CIContext().createCGImage(out, from: ci.extent)
    }

    func buildWindow() {
        let env = ProcessInfo.processInfo.environment
        let distortBezel = env["RL_BEZEL"] == "distort"   // side-by-side test toggle
        let testX = env["RL_X"].flatMap { Double($0) }     // test placement (floats on top)

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Just BELOW normal level: every app window covers it (so it always sits
        // behind your work, on the desktop) — but it's above the dead click-through
        // desktop layer, so it stays interactive. Closest a plain window gets to a
        // native desktop widget (which uses private WindowServer layers we can't join).
        window.level = testX != nil ? .floating : NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.delegate = self

        let size = window.contentView!.bounds.size
        window.alphaValue = 1.0
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true

        // base: full frosted glass; its alpha (only) is what the opacity slider drives
        frost = NSVisualEffectView(frame: root.bounds)
        frost.alphaValue = bgOpacity
        frost.autoresizingMask = [.width, .height]
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.maskImage = WidgetController.roundedMask(size: size, radius: radius)
        root.addSubview(frost)

        // bezel
        if distortBezel {
            // 10px, 95%-transparent band that DISTORTS the frosted backdrop beneath
            // it (strong Core Image glass distortion) — the refractor experiment.
            let band = NSView(frame: root.bounds)
            band.autoresizingMask = [.width, .height]; band.wantsLayer = true
            band.layerUsesCoreImageFilters = true
            band.layer?.backgroundColor = NSColor(white: 1, alpha: 0.01).cgColor  // 99% transparent
            if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
                    .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
                    .applyingGaussianBlur(sigma: 1.0),
               let glass = CIFilter(name: "CIGlassDistortion",
                                    parameters: ["inputTexture": noise, "inputScale": 100]) {  // strong
                band.layer?.backgroundFilters = [glass]
            }
            let ring = CAShapeLayer()
            ring.path = WidgetController.ringPath(root.bounds, radius, 10)   // 10px
            ring.fillRule = .evenOdd; ring.fillColor = NSColor.black.cgColor
            band.layer?.mask = ring
            root.addSubview(band)
        } else {
            // thin bezel rim + crisp glass edge
            let rim = NSView(frame: root.bounds)
            rim.autoresizingMask = [.width, .height]; rim.wantsLayer = true
            let ringLayer = CAShapeLayer()
            ringLayer.path = WidgetController.ringPath(root.bounds, radius, bezelW)
            ringLayer.fillRule = .evenOdd
            ringLayer.fillColor = NSColor(white: 1, alpha: 0.10).cgColor
            rim.layer?.addSublayer(ringLayer)
            root.addSubview(rim)
        }
        let outer = NSView(frame: root.bounds)
        outer.autoresizingMask = [.width, .height]; outer.wantsLayer = true
        outer.layer?.cornerRadius = radius
        outer.layer?.borderWidth = 1
        outer.layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        root.addSubview(outer)

        // live-refraction bezel — the Refractor paints the distorted backdrop here each
        // frame. Above the frost/rim, below the content, masked to the rim so it never
        // touches the text.
        let bezelView = NSView(frame: root.bounds)
        bezelView.autoresizingMask = [.width, .height]; bezelView.wantsLayer = true
        bezelView.layer?.contentsGravity = .resize
        bezelView.layer?.opacity = Float(gOpacity)      // blend with the frosted panel beneath
        let maskLayer = CALayer()
        maskLayer.frame = root.bounds
        maskLayer.contents = WidgetController.featheredRing(size: size, radius: radius, thickness: gWidth, feather: gFeather)
        bezelView.layer?.mask = maskLayer
        root.addSubview(bezelView)
        self.bezelView = bezelView

        // logo (click → choose this repo's logo)
        logoBtn.isBordered = false; logoBtn.bezelStyle = .regularSquare
        logoBtn.imagePosition = .imageOnly; logoBtn.imageScaling = .scaleProportionallyUpOrDown
        logoBtn.target = self; logoBtn.action = #selector(pickLogo)
        logoBtn.toolTip = "Click to choose a logo for this repo"

        // name (click → rename display; folder is untouched)
        nameBtn.isBordered = false; nameBtn.bezelStyle = .regularSquare
        nameBtn.target = self; nameBtn.action = #selector(renameRepo)
        nameBtn.toolTip = "Click to rename the display (folder is not renamed)"

        for (l, t, s, w, c) in [
            (hero, "—", 44, NSFont.Weight.semibold, TXT),
            (sub, "lines written — and counting", 12, .regular, TXT_DIM),
            (foot, "", 10.5, .regular, TXT_FAINT),
        ] as [(NSTextField, String, CGFloat, NSFont.Weight, NSColor)] {
            l.isBezeled = false; l.drawsBackground = false; l.isEditable = false; l.alignment = .center
            l.attributedStringValue = attr(t, s, w, c, 0)
        }

        tabBar.orientation = .horizontal; tabBar.spacing = 5; tabBar.alignment = .centerY
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        let gearBtn = iconButton("slider.horizontal.3", action: #selector(toggleSettings))
        let refreshBtn = iconButton("arrow.clockwise", action: #selector(manualRefresh))
        let closeBtn = iconButton("xmark.circle.fill", action: #selector(quit))
        let topRow = NSStackView(views: [tabBar, NSView(), gearBtn, refreshBtn, closeBtn])
        topRow.orientation = .horizontal; topRow.spacing = 8; topRow.alignment = .centerY
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let row1 = NSStackView(views: [stCode, stDocs]); row1.distribution = .fillEqually; row1.spacing = 8
        let row2 = NSStackView(views: [stData, stThird]); row2.distribution = .fillEqually; row2.spacing = 8
        let divider = makeDivider("bundled · not written")

        langBar.translatesAutoresizingMaskIntoConstraints = false
        langBar.heightAnchor.constraint(equalToConstant: 7).isActive = true
        langBar.widthAnchor.constraint(equalToConstant: 244).isActive = true
        langLegend.orientation = .vertical; langLegend.spacing = 3; langLegend.alignment = .centerX
        // the code breakdown floats, centred in the space below the stats
        let langGroup = NSStackView(views: [langBar, langLegend])
        langGroup.orientation = .vertical; langGroup.alignment = .centerX; langGroup.spacing = 9
        langGroup.translatesAutoresizingMaskIntoConstraints = false

        let col = NSStackView(views: [logoBtn, nameBtn, hero, sub, row1, divider, row2, foot])
        col.orientation = .vertical; col.alignment = .centerX; col.spacing = 8
        col.setCustomSpacing(4, after: logoBtn)
        col.setCustomSpacing(2, after: hero)
        col.setCustomSpacing(14, after: sub)
        col.setCustomSpacing(12, after: row1)
        col.setCustomSpacing(12, after: divider)
        col.setCustomSpacing(12, after: row2)
        col.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(topRow)
        root.addSubview(col)
        root.addSubview(langGroup)
        let gap = NSLayoutGuide(); root.addLayoutGuide(gap)
        NSLayoutConstraint.activate([
            logoBtn.widthAnchor.constraint(equalToConstant: 44),
            logoBtn.heightAnchor.constraint(equalToConstant: 44),
            topRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            topRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            topRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            col.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            col.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            col.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            col.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            // float the breakdown in the middle of the space between the total line and the bottom
            gap.topAnchor.constraint(equalTo: col.bottomAnchor),
            gap.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            langGroup.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            langGroup.centerYAnchor.constraint(equalTo: gap.centerYAnchor),
        ])

        window.contentView = root
        if let testX, let scr = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: scr.frame.minX + CGFloat(testX),
                                          y: scr.frame.maxY - size.height - 80))
        } else if let arr = UserDefaults.standard.array(forKey: "origin") as? [Double], arr.count == 2 {
            window.setFrameOrigin(NSPoint(x: arr[0], y: arr[1]))
        } else if let scr = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: scr.frame.minX + 90,
                                          y: scr.frame.maxY - size.height - 130))
        }
        window.orderFrontRegardless()

        if #available(macOS 14.0, *) {
            let r = Refractor()
            r.scale = gScale; r.blur = gBlur
            r.onImage = { [weak self] cg in self?.bezelView?.layer?.contents = cg }
            r.onError = { msg in NSLog("[refraction] \(msg)") }
            r.start(window: window)
            refractor = r
        }
    }

    func iconButton(_ symbol: String, action: Selector) -> NSButton {
        let b = NSButton()
        b.isBordered = false; b.bezelStyle = .regularSquare; b.title = ""
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        b.contentTintColor = TXT_FAINT
        b.target = self; b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }

    func makeDivider(_ text: String) -> NSView {
        let l = label(text, 10, .regular, TXT_FAINT)
        dividerLabel = l
        let left = NSBox(); let right = NSBox()
        for b in [left, right] { b.boxType = .separator; b.translatesAutoresizingMaskIntoConstraints = false }
        let row = NSStackView(views: [left, l, right])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        left.widthAnchor.constraint(equalToConstant: 38).isActive = true
        right.widthAnchor.constraint(equalToConstant: 38).isActive = true
        return row
    }

    // MARK: tabs
    func rebuildTabs() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, r) in repos.enumerated() {
            let short = String(displayName(r).prefix(8))
            let b = NSButton(); b.isBordered = false; b.bezelStyle = .regularSquare; b.tag = i
            b.attributedTitle = attr(short, 10.5, i == active ? .semibold : .regular,
                                     i == active ? ACCENT : TXT_DIM, 0.3)
            b.target = self; b.action = #selector(tabClicked(_:))
            b.toolTip = r.path
            let menu = NSMenu()
            let rn = NSMenuItem(title: "Rename…", action: #selector(renameTab(_:)), keyEquivalent: "")
            rn.target = self; rn.tag = i
            let rm = NSMenuItem(title: "Remove tab", action: #selector(removeTab(_:)), keyEquivalent: "")
            rm.target = self; rm.tag = i
            menu.addItem(rn); menu.addItem(rm)
            b.menu = menu   // right-click / control-click a tab
            tabBar.addArrangedSubview(b)
        }
        let plus = NSButton(); plus.isBordered = false; plus.bezelStyle = .regularSquare
        plus.attributedTitle = attr("+", 14, .regular, TXT_DIM)
        plus.target = self; plus.action = #selector(addRepo); plus.toolTip = "Add a repo"
        tabBar.addArrangedSubview(plus)
        if repos.count > 1 {
            let minus = NSButton(); minus.isBordered = false; minus.bezelStyle = .regularSquare
            minus.attributedTitle = attr("–", 14, .regular, TXT_FAINT)
            minus.target = self; minus.action = #selector(removeRepo); minus.toolTip = "Remove current repo"
            tabBar.addArrangedSubview(minus)
        }
    }

    @objc func tabClicked(_ s: NSButton) {
        active = s.tag; saveRepos(); rebuildTabs(); selectActive(refreshNow: true)
    }
    @objc func removeTab(_ s: NSMenuItem) {
        let idx = s.tag
        guard repos.indices.contains(idx) else { return }
        repos.remove(at: idx)
        if active > idx { active -= 1 }
        if active >= repos.count { active = max(0, repos.count - 1) }
        saveRepos(); rebuildTabs(); selectActive(refreshNow: true)
    }
    @objc func renameTab(_ s: NSMenuItem) {
        guard repos.indices.contains(s.tag) else { return }
        active = s.tag; saveRepos(); rebuildTabs(); renameRepo()
    }
    @objc func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Track"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            repos.append(Repo(path: url.path, name: nil, logo: nil))
            active = repos.count - 1
            saveRepos(); rebuildTabs(); selectActive(refreshNow: true)
        }
    }
    @objc func removeRepo() {
        guard repos.indices.contains(active) else { return }
        repos.remove(at: active)
        if active >= repos.count { active = max(0, repos.count - 1) }
        saveRepos(); rebuildTabs(); selectActive(refreshNow: true)
    }
    @objc func pickLogo() {
        guard repos.indices.contains(active) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: repos[active].path)
        panel.prompt = "Use as logo"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            repos[active].logo = url.path
            saveRepos(); setLogo(url.path)
        }
    }
    @objc func renameRepo() {
        guard repos.indices.contains(active) else { return }
        let a = NSAlert()
        a.messageText = "Display name"
        a.informativeText = "Shown on the widget and its tab. The folder is not renamed."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.stringValue = repos[active].name ?? ""
        tf.placeholderString = (repos[active].path as NSString).lastPathComponent
        a.accessoryView = tf
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            let v = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            repos[active].name = v.isEmpty ? nil : v
            saveRepos(); rebuildTabs()
            if let r = activeRepo {
                nameBtn.attributedTitle = attr(displayName(r).uppercased(), 10.5, .semibold, ACCENT, 1.6)
            }
        }
    }

    func setLogo(_ logo: String?) {
        if let lp = logo, let img = NSImage(contentsOfFile: lp) { logoBtn.image = img; return }
        if let bp = Bundle.main.path(forResource: "logo", ofType: "png"),
           let img = NSImage(contentsOfFile: bp) { logoBtn.image = img; return }
        logoBtn.image = nil
    }

    func selectActive(refreshNow: Bool) {
        guard let r = activeRepo else {
            nameBtn.attributedTitle = attr("+ ADD A REPO", 10.5, .semibold, ACCENT, 1.4)
            setLogo(nil); showDashes(); return
        }
        setLogo(r.logo)
        nameBtn.attributedTitle = attr(displayName(r).uppercased(), 10.5, .semibold, ACCENT, 1.6)
        if let c = cache[r.path] { render(c) } else { showDashes() }
        if refreshNow { refresh() }
    }

    @objc func manualRefresh() {
        if let p = activeRepo?.path { lastSig[p] = "" }
        refresh()
    }
    @objc func quit() { NSApp.terminate(nil) }

    // Capture the widget window itself (glass included) via ScreenCaptureKit, drop a
    // PNG on the Desktop, then reveal it in Finder — no system screenshot tool needed.

    // MARK: glass settings panel
    func loadGlass() {
        let d = UserDefaults.standard
        guard d.object(forKey: "gScale") != nil else { return }
        gScale = CGFloat(d.double(forKey: "gScale")); gBlur = CGFloat(d.double(forKey: "gBlur"))
        gOpacity = CGFloat(d.double(forKey: "gOpacity")); gWidth = CGFloat(d.double(forKey: "gWidth"))
        gFeather = CGFloat(d.double(forKey: "gFeather"))
    }
    func saveGlass() {
        let d = UserDefaults.standard
        d.set(Double(gScale), forKey: "gScale"); d.set(Double(gBlur), forKey: "gBlur")
        d.set(Double(gOpacity), forKey: "gOpacity"); d.set(Double(gWidth), forKey: "gWidth")
        d.set(Double(gFeather), forKey: "gFeather")
    }
    func applyGlass() {
        frost?.alphaValue = bgOpacity
        if #available(macOS 14.0, *), let r = refractor as? Refractor { r.scale = gScale; r.blur = gBlur }
        bezelView?.layer?.opacity = Float(gOpacity)
        if let bv = bezelView {
            let m = CALayer(); m.frame = bv.bounds
            m.contents = WidgetController.featheredRing(size: bv.bounds.size, radius: radius, thickness: gWidth, feather: gFeather)
            bv.layer?.mask = m
        }
        saveGlass()
        UserDefaults.standard.set(Double(bgOpacity), forKey: "bgOpacity")
    }

    // Theme (colours + font) — mutable globals, persisted, applied by restyle().
    func loadTheme() {
        let d = UserDefaults.standard
        if let a = d.array(forKey: "accentRGBA") as? [Double], a.count == 4 {
            ACCENT = NSColor(red: a[0], green: a[1], blue: a[2], alpha: a[3])
        }
        if let t = d.array(forKey: "textRGBA") as? [Double], t.count == 4 {
            let c = NSColor(red: t[0], green: t[1], blue: t[2], alpha: t[3])
            TXT = c; TXT_DIM = c.withAlphaComponent(0.62); TXT_FAINT = c.withAlphaComponent(0.42)
        }
        if d.object(forKey: "fontStyle") != nil, let fs = FontStyle(rawValue: d.integer(forKey: "fontStyle")) { FONT_STYLE = fs }
    }
    func saveColor(_ c: NSColor, _ key: String) {
        if let s = c.usingColorSpace(.sRGB) {
            UserDefaults.standard.set([Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), Double(s.alphaComponent)], forKey: key)
        }
    }
    func restyle() {
        sub.attributedStringValue = attr("lines written — and counting", 12, .regular, TXT_DIM)
        dividerLabel?.attributedStringValue = attr("bundled · not written", 10, .regular, TXT_FAINT)
        for s in [stCode, stDocs, stData, stThird] { s.restyle() }
        if let r = activeRepo {
            nameBtn.attributedTitle = attr(displayName(r).uppercased(), 10.5, .semibold, ACCENT, 1.6)
            if let c = cache[r.path] { render(c) } else { showDashes() }
        }
        rebuildTabs()
    }
    @objc func accentChanged(_ w: NSColorWell) { ACCENT = w.color; saveColor(ACCENT, "accentRGBA"); restyle() }
    @objc func textChanged(_ w: NSColorWell) {
        let c = w.color; TXT = c; TXT_DIM = c.withAlphaComponent(0.62); TXT_FAINT = c.withAlphaComponent(0.42)
        saveColor(c, "textRGBA"); restyle()
    }
    @objc func fontChanged(_ p: NSPopUpButton) {
        FONT_STYLE = FontStyle(rawValue: p.indexOfSelectedItem) ?? .system
        UserDefaults.standard.set(FONT_STYLE.rawValue, forKey: "fontStyle"); restyle()
    }
    func labeledControl(_ title: String, _ control: NSView) -> NSView {
        let t = NSTextField(labelWithString: title); t.font = .systemFont(ofSize: 11, weight: .medium)
        let row = NSStackView(views: [t, NSView(), control]); row.orientation = .horizontal; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 218).isActive = true
        return row
    }

    @objc func toggleSettings() {
        if let w = settingsWindow { w.close(); settingsWindow = nil; return }
        buildSettings()
    }
    func buildSettings() {
        let defs: [(String, Double, Double, ReferenceWritableKeyPath<WidgetController, CGFloat>)] = [
            ("Centre opacity", 0, 1, \.bgOpacity),
            ("Distortion strength", 0, 60, \.gScale),
            ("Frost blur", 0, 15, \.gBlur),
            ("Bezel opacity", 0, 1, \.gOpacity),
            ("Bezel width", 4, 40, \.gWidth),
            ("Edge feather", 0, 20, \.gFeather),
        ]
        gRows = []
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (i, p) in defs.enumerated() {
            let title = NSTextField(labelWithString: p.0)
            title.font = .systemFont(ofSize: 11, weight: .medium)
            let cur = self[keyPath: p.3]
            let slider = NSSlider(value: Double(cur), minValue: p.1, maxValue: p.2,
                                  target: self, action: #selector(glassSliderChanged(_:)))
            slider.tag = i
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let val = NSTextField(labelWithString: String(format: "%.1f", Double(cur)))
            val.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); val.textColor = .secondaryLabelColor
            val.alignment = .right; val.widthAnchor.constraint(equalToConstant: 34).isActive = true
            let hrow = NSStackView(views: [slider, val]); hrow.orientation = .horizontal; hrow.spacing = 8
            let cell = NSStackView(views: [title, hrow]); cell.orientation = .vertical; cell.spacing = 2; cell.alignment = .leading
            stack.addArrangedSubview(cell)
            gRows.append((p.3, val))
        }
        let accentWell = NSColorWell(); accentWell.color = ACCENT
        accentWell.target = self; accentWell.action = #selector(accentChanged(_:))
        accentWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        accentWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let textWell = NSColorWell(); textWell.color = TXT
        textWell.target = self; textWell.action = #selector(textChanged(_:))
        textWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        textWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let fontPop = NSPopUpButton()
        fontPop.addItems(withTitles: ["System", "Rounded", "Serif", "Monospace"])
        fontPop.selectItem(at: FONT_STYLE.rawValue)
        fontPop.target = self; fontPop.action = #selector(fontChanged(_:))
        stack.addArrangedSubview(labeledControl("Accent colour", accentWell))
        stack.addArrangedSubview(labeledControl("Text colour", textWell))
        stack.addArrangedSubview(labeledControl("Font", fontPop))

        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetGlass))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        stack.layoutSubtreeIfNeeded()
        let sz = stack.fittingSize
        let container = NSView(frame: NSRect(x: 0, y: 0, width: max(250, sz.width + 32), height: sz.height + 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
        ])
        let panel = NSPanel(contentRect: container.frame, styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Glass settings"
        panel.isFloatingPanel = true; panel.level = .floating
        panel.contentView = container
        panel.delegate = self
        let wf = window.frame
        panel.setFrameTopLeftPoint(NSPoint(x: wf.maxX + 12, y: wf.maxY))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = panel
    }
    @objc func glassSliderChanged(_ s: NSSlider) {
        guard gRows.indices.contains(s.tag) else { return }
        let row = gRows[s.tag]
        self[keyPath: row.kp] = CGFloat(s.doubleValue)
        row.value.stringValue = String(format: "%.1f", s.doubleValue)
        applyGlass()
    }
    @objc func resetGlass() {
        gScale = 14; gBlur = 5; gOpacity = 0.5; gWidth = 16; gFeather = 6; bgOpacity = 0.9
        ACCENT = NSColor(red: 0.373, green: 0.816, blue: 0.769, alpha: 1)
        TXT = .white; TXT_DIM = NSColor(white: 1, alpha: 0.62); TXT_FAINT = NSColor(white: 1, alpha: 0.42)
        FONT_STYLE = .system
        saveColor(ACCENT, "accentRGBA"); saveColor(TXT, "textRGBA"); UserDefaults.standard.set(0, forKey: "fontStyle")
        applyGlass(); restyle()
        settingsWindow?.close(); settingsWindow = nil; buildSettings()
    }
    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === settingsWindow { settingsWindow = nil }
    }

    func refresh() {
        guard let r = activeRepo else { return }
        let root = r.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let sig = repoSignature(root)
            if !sig.isEmpty && sig == self.lastSig[root] { return }   // unchanged — skip rescan
            let t = scan(root)
            DispatchQueue.main.async {
                self.lastSig[root] = sig
                self.cache[root] = t
                if self.activeRepo?.path == root { self.render(t) }
            }
        }
    }

    func showDashes() {
        hero.attributedStringValue = attr("—", 44, .semibold, TXT)
        stCode.set("—"); stDocs.set("—"); stData.set("—"); stThird.set("—")
        foot.attributedStringValue = attr("scanning…", 10.5, .regular, TXT_FAINT)
        langBar.segments = []; langBar.needsDisplay = true
        langLegend.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func render(_ t: Totals) {
        hero.attributedStringValue = attr(fmt(t.written), 44, .semibold, TXT)
        stCode.set(fmt(t.code)); stDocs.set(fmt(t.docs))
        stData.set(fmt(t.datasets)); stThird.set(fmt(t.thirdparty))
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        foot.attributedStringValue = attr("\(fmt(t.total)) total · \(fmt(t.files)) files · \(df.string(from: Date()))", 10.5, .regular, TXT_FAINT)
        updateLanguages(t)
    }

    // GitHub-style language bar: sections ≥1% shown, the rest bundled as "Other".
    func updateLanguages(_ t: Totals) {
        langLegend.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let total = t.langs.values.reduce(0, +)
        guard total > 0 else { langBar.segments = []; langBar.needsDisplay = true; return }
        var segs: [(NSColor, CGFloat)] = []
        var items: [(String, NSColor, Double)] = []
        var other = 0.0
        for (name, lines) in t.langs.sorted(by: { $0.value > $1.value }) {
            let pct = Double(lines) / Double(total) * 100
            if name != "Other" && pct >= 1.0 { let c = colorFor(name); segs.append((c, CGFloat(pct/100))); items.append((name, c, pct)) }
            else { other += pct }   // unknown/extensionless + everything <1% → single "Other"
        }
        if other > 0.05 { let c = NSColor(white: 0.55, alpha: 1); segs.append((c, CGFloat(other/100))); items.append(("Other", c, other)) }
        langBar.segments = segs; langBar.needsDisplay = true
        // legend, two per row
        var rowStack: NSStackView?
        for (i, it) in items.enumerated() {
            if i % 2 == 0 { let r = NSStackView(); r.orientation = .horizontal; r.spacing = 12; langLegend.addArrangedSubview(r); rowStack = r }
            rowStack?.addArrangedSubview(legendItem(it.0, it.1, it.2))
        }
    }
    func legendItem(_ name: String, _ color: NSColor, _ pct: Double) -> NSView {
        let dot = NSView(); dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor; dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let lbl = NSTextField(labelWithString: "")
        lbl.isBezeled = false; lbl.drawsBackground = false; lbl.isEditable = false
        lbl.attributedStringValue = attr("\(name) \(String(format: "%.1f", pct))%", 10, .regular, TXT_DIM)
        let row = NSStackView(views: [dot, lbl]); row.orientation = .horizontal; row.spacing = 5; row.alignment = .centerY
        return row
    }
}

extension WidgetController: NSWindowDelegate {
    // Drag smoothly; snap to a 20px grid a moment after you stop (debounced), so it
    // lands on the grid without the jerk of snapping mid-drag.
    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }   // ignore the settings panel
        // free smooth drag — no grid snap; just remember where it's dropped and
        // re-point the capture region once movement settles.
        snapTimer?.invalidate()
        snapTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            let o = self.window.frame.origin
            UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: "origin")
            if #available(macOS 14.0, *), let r = self.refractor as? Refractor { r.updateRegion(window: self.window) }
        }
    }
}

// ---- app -------------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = WidgetController()
app.run()
