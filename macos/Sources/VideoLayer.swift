import AppKit
import OpenGL.GL3

private func mpvGetProcAddress(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
    let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}

private let openGLAPIType = strdup("opengl")

/// Renders mpv frames with the libmpv OpenGL render API (the same approach IINA uses).
/// The web view sits on top with a transparent background.
final class VideoLayer: CAOpenGLLayer {
    private unowned let mpv: MPVController
    private var renderContext: OpaquePointer?
    private var glContext: CGLContextObj?
    private let flagLock = NSLock()
    private let renderLock = NSLock()
    private var frameReady = false
    private var forceRender = true

    init(mpv: MPVController) {
        self.mpv = mpv
        super.init()
        isAsynchronous = true
        isOpaque = true
        backgroundColor = NSColor.black.cgColor
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        let other = layer as! VideoLayer
        mpv = other.mpv
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var bounds: CGRect {
        didSet { requestRedraw() }
    }

    func requestRedraw() {
        flagLock.lock()
        forceRender = true
        flagLock.unlock()
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let profile = CGLPixelFormatAttribute(rawValue: UInt32(kCGLOGLPVersion_3_2_Core.rawValue))
        let end = CGLPixelFormatAttribute(rawValue: 0)
        let candidates: [[CGLPixelFormatAttribute]] = [
            [kCGLPFAOpenGLProfile, profile, kCGLPFAAccelerated, kCGLPFADoubleBuffer,
             kCGLPFAAllowOfflineRenderers, kCGLPFASupportsAutomaticGraphicsSwitching, end],
            [kCGLPFAOpenGLProfile, profile, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers, end],
            [kCGLPFADoubleBuffer, end],
        ]
        for attrs in candidates {
            var pix: CGLPixelFormatObj?
            var count: GLint = 0
            if CGLChoosePixelFormat(attrs, &pix, &count) == kCGLNoError, let pix {
                return pix
            }
        }
        Log.error("[VIDEO]: No suitable OpenGL pixel format")
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        let ctx = super.copyCGLContext(forPixelFormat: pf)
        var swap: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
        CGLEnable(ctx, kCGLCEMPEngine)
        CGLSetCurrentContext(ctx)
        glContext = ctx
        createRenderContext()
        return ctx
    }

    private func createRenderContext() {
        guard renderContext == nil, let handle = mpv.handle else { return }
        var initParams = mpv_opengl_init_params(get_proc_address: mpvGetProcAddress, get_proc_address_ctx: nil)
        var ctx: OpaquePointer?
        let rc = withUnsafeMutablePointer(to: &initParams) { ip -> Int32 in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(openGLAPIType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(ip)),
                mpv_render_param(),
            ]
            return mpv_render_context_create(&ctx, handle, &params)
        }
        guard rc >= 0, let ctx else {
            Log.error("[VIDEO]: mpv_render_context_create failed: \(String(cString: mpv_error_string(rc)))")
            return
        }
        renderContext = ctx
        mpv_render_context_set_update_callback(ctx, { p in
            guard let p else { return }
            Unmanaged<VideoLayer>.fromOpaque(p).takeUnretainedValue().frameAvailable()
        }, Unmanaged.passUnretained(self).toOpaque())
        Log.info("[VIDEO]: OpenGL render context ready")
    }

    /// Called on an mpv thread; must not call back into mpv.
    private func frameAvailable() {
        flagLock.lock()
        frameReady = true
        flagLock.unlock()
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return frameReady || forceRender
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        flagLock.lock()
        frameReady = false
        forceRender = false
        flagLock.unlock()

        renderLock.lock()
        defer { renderLock.unlock() }
        CGLSetCurrentContext(ctx)

        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        if let rc = renderContext {
            mpv_render_context_update(rc)
            var target = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(viewport[2]), h: Int32(viewport[3]), internal_format: 0)
            var flip: CInt = 1
            withUnsafeMutablePointer(to: &target) { tp in
                withUnsafeMutablePointer(to: &flip) { fp in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(tp)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(fp)),
                        mpv_render_param(),
                    ]
                    _ = mpv_render_context_render(rc, &params)
                }
            }
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
        if let rc = renderContext { mpv_render_context_report_swap(rc) }
    }

    /// Frees the render context; must run before mpv_terminate_destroy.
    func destroy() {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let rc = renderContext else { return }
        renderContext = nil
        mpv_render_context_set_update_callback(rc, nil, nil)
        if let ctx = glContext {
            CGLLockContext(ctx)
            CGLSetCurrentContext(ctx)
            mpv_render_context_free(rc)
            CGLUnlockContext(ctx)
        } else {
            mpv_render_context_free(rc)
        }
    }
}

final class VideoView: NSView {
    let videoLayer: VideoLayer

    init(mpv: MPVController) {
        videoLayer = VideoLayer(mpv: mpv)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func makeBackingLayer() -> CALayer { videoLayer }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.requestRedraw()
    }

    // The web view handles all input.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
