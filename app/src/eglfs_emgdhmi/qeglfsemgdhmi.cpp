// qeglfsemgdhmi.cpp — Qt6 eglfs device-integration for EMGD HMI pixmaps.
//
// Strategy: behave like a normal eglfs backend but substitute every native-window
// step with the EMGD HMI broker:
//   - platformDisplay() returns the EMGD native display (0xd39ade6b magic), not
//     an X11 / wayland / fbdev one.
//   - createNativeWindow() allocates an HMI pixmap (via libemgdhmi.so.0) of the
//     requested size and immediately binds it as the scanout buffer for
//     screen 0 via emgdHmiConfigureBuffers — without that bind step the
//     pixmap is allocated but never visible (proven by spike4).
//   - presentBuffer() optionally signals the daemon with RequestFlip after the
//     standard eglSwapBuffers (D3 says it's a no-op stub on this build, but
//     it's free insurance — if the daemon ever grows real flip-chain logic
//     we'll already be calling it).
//
// All emgdHmi entry points are resolved via dlsym so we don't depend on
// emgdhmi.h headers — which aren't on the build host. Function signatures
// come from:
//   docs/forensic-libemgdhmi-api.md §2 — complete signature table
//   docs/forensic-emgdbuffertype-struct.md §1 — struct layout
//   app/src/planb_spike/q60_planb_spike4_configure_buffers.c — proven C usage

#include "qeglfsemgdhmi.h"

#include <QDebug>
#include <QLoggingCategory>
#include <QSurfaceFormat>
#include <dlfcn.h>
#include <cstring>
#include <cstdint>

// GLES2 functions for the post-swap readback. We avoid pulling GLES headers
// into the plugin's compile by declaring the two we need inline. They are
// resolved at runtime via the EGL config; presentBuffer runs in the GL thread
// after the swap so the context is current.
extern "C" {
    // GL types we need (matches GLES2 spec)
    typedef int GLint;
    typedef unsigned int GLuint;
    typedef unsigned int GLenum;
    typedef int GLsizei;
    typedef void GLvoid;
    #define GL_RGBA            0x1908
    #define GL_BGRA_EXT        0x80E1
    #define GL_UNSIGNED_BYTE   0x1401
    void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height,
                      GLenum format, GLenum type, GLvoid *data);
    void glFinish(void);
    GLenum glGetError(void);
}

QT_BEGIN_NAMESPACE

Q_LOGGING_CATEGORY(lcEmgdHmi, "qt.qpa.egldeviceintegration.emgdhmi")

QEglFSEmgdHmiIntegration::QEglFSEmgdHmiIntegration() = default;

QEglFSEmgdHmiIntegration::~QEglFSEmgdHmiIntegration()
{
    // Don't dlclose — Qt may still be tearing down other things that touch EGL.
    // The OS reaps the lib on process exit.
}

void QEglFSEmgdHmiIntegration::platformInit()
{
    // libemgdhmi.so.0 lives at /usr/lib on the factory rootfs. LD_LIBRARY_PATH
    // should include /usr/lib first (set by run-q60qt.sh) so we resolve
    // glibc symbols against the modern build container's libc rather than
    // MeeGo's 2.11.90 — same trick the spike uses.
    m_libemgdhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!m_libemgdhmi) {
        qCWarning(lcEmgdHmi) << "dlopen(libemgdhmi.so.0) FAILED:" << dlerror();
        return;
    }

    // Resolve all required entry points.
    m_GetNativeDisplay  = reinterpret_cast<int(*)(void**)>(
        dlsym(m_libemgdhmi, "emgdHmiGetNativeDisplay"));
    m_GetNumScreens     = reinterpret_cast<int(*)(void*)>(
        dlsym(m_libemgdhmi, "emgdHmiGetNumScreens"));
    m_CreatePixmap      = reinterpret_cast<int(*)(void*, int, int, int, void**)>(
        dlsym(m_libemgdhmi, "emgdHmiCreatePixmap"));
    m_DestroyPixmap     = reinterpret_cast<int(*)(void*, void*)>(
        dlsym(m_libemgdhmi, "emgdHmiDestroyPixmap"));
    m_ConfigureBuffers  = reinterpret_cast<int(*)(void*, EMGDHmiBufferState**)>(
        dlsym(m_libemgdhmi, "emgdHmiConfigureBuffers"));
    m_RequestFlip       = reinterpret_cast<int(*)(void*, int, int, int*)>(
        dlsym(m_libemgdhmi, "emgdHmiRequestFlip"));
    // 6-arg MapPixmap: (display, pixmap, w, h, stride, **mem) — see spike7
    m_MapPixmap         = reinterpret_cast<int(*)(void*, void*, unsigned, unsigned, unsigned, void**)>(
        dlsym(m_libemgdhmi, "emgdHmiMapPixmap"));

    if (!m_GetNativeDisplay || !m_CreatePixmap || !m_ConfigureBuffers) {
        qCWarning(lcEmgdHmi) << "Missing required emgdHmi entry points — plugin disabled";
        return;
    }

    int rc = m_GetNativeDisplay(&m_ndpy);
    if (rc != 0 || !m_ndpy) {
        qCWarning(lcEmgdHmi) << "emgdHmiGetNativeDisplay rc=" << rc << "ndpy=" << m_ndpy;
        return;
    }
    qCInfo(lcEmgdHmi) << "emgdHmiGetNativeDisplay OK ndpy=" << m_ndpy
                      << "(expect magic 0xd39ade6b)";

    if (m_GetNumScreens) {
        int n = m_GetNumScreens(m_ndpy);
        qCInfo(lcEmgdHmi) << "emgdHmiGetNumScreens =" << n << "(expect 2)";
    }
}

void QEglFSEmgdHmiIntegration::platformDestroy()
{
    if (m_pixmap && m_DestroyPixmap && m_ndpy) {
        int rc = m_DestroyPixmap(m_ndpy, m_pixmap);
        qCInfo(lcEmgdHmi) << "emgdHmiDestroyPixmap rc=" << rc;
        m_pixmap = nullptr;
    }
}

EGLNativeDisplayType QEglFSEmgdHmiIntegration::platformDisplay() const
{
    // Qt eglfs feeds this into eglGetDisplay(). The EMGD WSEGL backend
    // (libwsegl-hmi.so) recognises the magic and produces an EGLDisplay
    // suitable for pixmap surfaces.
    return reinterpret_cast<EGLNativeDisplayType>(m_ndpy);
}

QSize QEglFSEmgdHmiIntegration::screenSize() const
{
    // The factory drawbuf binary uses 800x480 for single panel; the upper
    // LVDS is screen 0. Return that for now — emgdHmiGetFramebufferSize
    // could be plumbed if we ever need to dual-paint.
    return m_size;
}

QSizeF QEglFSEmgdHmiIntegration::physicalScreenSize() const
{
    // ~7" upper LVDS, per Agent 2 Section 9.2: 152mm × 91mm.
    return QSizeF(152.0, 91.0);
}

QSurfaceFormat QEglFSEmgdHmiIntegration::surfaceFormatFor(const QSurfaceFormat &inputFormat) const
{
    // Force the drawbuf-validated EGL config: RGBA8 / D24 / S8 / no MSAA.
    // Per Agent 2 §9.3 — MSAA dropped from drawbuf's 4x for SGX535 perf.
    QSurfaceFormat fmt = inputFormat;
    fmt.setRedBufferSize(8);
    fmt.setGreenBufferSize(8);
    fmt.setBlueBufferSize(8);
    fmt.setAlphaBufferSize(8);
    fmt.setDepthBufferSize(24);
    fmt.setStencilBufferSize(8);
    fmt.setSamples(0);
    fmt.setRenderableType(QSurfaceFormat::OpenGLES);
    fmt.setMajorVersion(2);
    fmt.setMinorVersion(0);
    return fmt;
}

EGLint QEglFSEmgdHmiIntegration::surfaceType() const
{
    // EGL_WINDOW_BIT — Qt's QEglFSWindow always uses eglCreateWindowSurface.
    // The factory drawbuf binary uses the same call site: it passes the EMGD
    // pixmap pointer as EGLNativeWindowType, and libwsegl-hmi.so's
    // WSEGL_CreateWindowDrawable() resolves the pixmap from that handle.
    // (See forensic-factory-ui-binary.md §2.3 — "passes pemgddata->pix as
    // EGLNativeWindowType to eglCreateWindowSurface".)
    //
    // The WSEGL backend doesn't actually care whether we call this "window"
    // or "pixmap" — it has a single drawable type. The discriminator that
    // matters is the surface type flag in the EGLConfig, which we keep as
    // WINDOW so it matches what Qt does.
    return EGL_WINDOW_BIT;
}

EGLNativeWindowType QEglFSEmgdHmiIntegration::createNativeWindow(
        QPlatformWindow * /*platformWindow*/,
        const QSize &size,
        const QSurfaceFormat & /*format*/)
{
    if (!m_ndpy || !m_CreatePixmap) {
        qCWarning(lcEmgdHmi) << "createNativeWindow: ndpy or CreatePixmap missing";
        return EGLNativeWindowType(0);
    }

    // First window only — we paint only screen 0 (upper LVDS). Subsequent
    // window creations (e.g. lower screen) will be addressed when we wire
    // up multi-screen support.
    if (m_pixmap) {
        qCInfo(lcEmgdHmi) << "createNativeWindow: returning existing pixmap" << m_pixmap;
        return reinterpret_cast<EGLNativeWindowType>(m_pixmap);
    }

    // Per Agent 2 §9.1: emgdHmiCreatePixmap(disp, EMGD_HMI_BUFFER=1, 800, 480, &pix).
    // Use the requested size if it's reasonable; otherwise force 800x480.
    int w = size.width()  > 0 ? size.width()  : 800;
    int h = size.height() > 0 ? size.height() : 480;
    if (w > 800)  w = 800;
    if (h > 480)  h = 480;
    m_size = QSize(w, h);

    int rc = m_CreatePixmap(m_ndpy, 1 /* EMGD_HMI_BUFFER */, w, h, &m_pixmap);
    if (rc != 0 || !m_pixmap) {
        qCWarning(lcEmgdHmi) << "emgdHmiCreatePixmap rc=" << rc << "pix=" << m_pixmap;
        return EGLNativeWindowType(0);
    }
    qCInfo(lcEmgdHmi) << "emgdHmiCreatePixmap" << w << "x" << h << "→ pix=" << m_pixmap;

    // THE KEY STEP — bind the pixmap to the HMI scanout slot for screen 0.
    // Without this, eglSwapBuffers paints into a buffer that's allocated
    // in GTT but not in the kernel's scanout table → nothing visible.
    if (!configureBuffers()) {
        qCWarning(lcEmgdHmi) << "configureBuffers FAILED — pixmap allocated but not scanned out";
    }

    // Spike 5 proved: GL rendering into a pixmap surface does NOT reach the
    // memory the kernel scans out — eglSwapBuffers on a pixmap is a no-op
    // for visibility. Workaround: after each swap, glReadPixels into the
    // CPU-mapped pixmap memory. That memcpy IS what shows on screen.
    //
    // Map the pixmap once here; CPU vaddr is reused in presentBuffer.
    if (m_MapPixmap) {
        int rc = m_MapPixmap(m_ndpy, m_pixmap,
                             static_cast<unsigned>(w),
                             static_cast<unsigned>(h),
                             static_cast<unsigned>(w * 4),
                             &m_pixmap_vaddr);
        qCInfo(lcEmgdHmi) << "emgdHmiMapPixmap rc=" << rc
                          << "vaddr=" << m_pixmap_vaddr;
        if (rc != 0) m_pixmap_vaddr = nullptr;
    } else {
        qCWarning(lcEmgdHmi) << "emgdHmiMapPixmap not resolved — readback path disabled";
    }

    return reinterpret_cast<EGLNativeWindowType>(m_pixmap);
}

void QEglFSEmgdHmiIntegration::destroyNativeWindow(EGLNativeWindowType window)
{
    if (!m_DestroyPixmap || !m_ndpy)
        return;
    void *px = reinterpret_cast<void *>(window);
    int rc = m_DestroyPixmap(m_ndpy, px);
    qCInfo(lcEmgdHmi) << "emgdHmiDestroyPixmap pix=" << px << "rc=" << rc;
    if (px == m_pixmap) {
        m_pixmap = nullptr;
        m_buffersConfigured = false;
    }
}

void QEglFSEmgdHmiIntegration::presentBuffer(QPlatformSurface *surface)
{
    // Qt's eglfs has already called eglSwapBuffers before this hook fires.
    // The GL context is still current. We now have to get those rendered
    // pixels into the memory the EMGD kernel actually scans out — Qt's GL
    // back buffer is NOT the same as our pixmap memory (spike 5 confirmed).
    //
    // Workaround: glReadPixels into our CPU-mapped pixmap memory. CPU cost
    // is high (~1.5 MB read + write per frame at 800x480 ARGB8888) but it
    // makes the GL output visible. Long-term, write a custom Qt backend
    // that renders into a QImage backed by the pixmap memory directly
    // (skip GL entirely, drawbuf-style). For tonight: prove the path.
    Q_UNUSED(surface);

    readbackToPixmap();

    // RequestFlip is a 10-byte stub on this build (per Agent D3) — call it
    // anyway in case the daemon ever grows real flip logic.
    if (!m_flipRequested && m_RequestFlip && m_ndpy) {
        int did_flip = 0;
        int rc = m_RequestFlip(m_ndpy, 0 /* screen 0 = upper LVDS */,
                               0 /* owner EMGD_DISPLAY_HMI */,
                               &did_flip);
        qCInfo(lcEmgdHmi) << "emgdHmiRequestFlip rc=" << rc << "did_flip=" << did_flip;
        m_flipRequested = true;
    }
}

void QEglFSEmgdHmiIntegration::readbackToPixmap()
{
    if (!m_pixmap_vaddr) return;
    glFinish();  // make sure GL is done before we read back
    glReadPixels(0, 0, m_size.width(), m_size.height(),
                 GL_RGBA, GL_UNSIGNED_BYTE, m_pixmap_vaddr);
    // glReadPixels writes bytes in R,G,B,A order. uint32_t on little-endian
    // = 0xAABBGGRR. If scanout expects 0xAARRGGBB we'll see colors swapped
    // (R/B). Hardware test will tell — fix in spike 6's color cycle finding.
}

bool QEglFSEmgdHmiIntegration::hasCapability(QPlatformIntegration::Capability cap) const
{
    switch (cap) {
    case QPlatformIntegration::OpenGL:
    case QPlatformIntegration::ThreadedOpenGL:
    case QPlatformIntegration::BufferQueueingOpenGL:
        return true;
    default:
        return false;
    }
}

bool QEglFSEmgdHmiIntegration::supportsPBuffers() const          { return false; }
bool QEglFSEmgdHmiIntegration::supportsSurfacelessContexts() const { return false; }

// ---------------------------------------------------------------------------
// configureBuffers — replicate spike4 §05 verbatim.
// ---------------------------------------------------------------------------
bool QEglFSEmgdHmiIntegration::configureBuffers()
{
    if (m_buffersConfigured)
        return true;
    if (!m_ConfigureBuffers || !m_ndpy || !m_pixmap)
        return false;

    EMGDHmiBufferState screen0[3] = {};
    screen0[0].plane_type    = 1; // EMGD_HMI_BUFFER
    screen0[0].pixmap_handle = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(m_pixmap));
    screen0[0].pixmap_handle_hi = 0;
    screen0[0].width  = m_size.width();
    screen0[0].height = m_size.height();
    screen0[0].stride = m_size.width() * 4;  // ARGB8888 byte-pitch
    // src_x / src_y / screen_x / screen_y / flags* zeroed

    EMGDHmiBufferState screen1[3] = {};  // lower LVDS untouched
    EMGDHmiBufferState *state[2] = { screen0, screen1 };

    int rc = m_ConfigureBuffers(m_ndpy, state);
    qCInfo(lcEmgdHmi) << "emgdHmiConfigureBuffers (h=" << m_size.height() << ") rc=" << rc;

    // Per D5 §4 fallback: if BAD_CONFIG (-3) on full 480-row height, retry
    // with 450 (per_screen_h = total_fb_h / num_screens). Spike4 has the
    // same fallback.
    if (rc == -3 && m_size.height() == 480) {
        qCInfo(lcEmgdHmi) << "Retrying ConfigureBuffers with height=450";
        screen0[0].height = 450;
        rc = m_ConfigureBuffers(m_ndpy, state);
        qCInfo(lcEmgdHmi) << "emgdHmiConfigureBuffers (h=450) rc=" << rc;
        if (rc == 0)
            m_size.setHeight(450);
    }

    m_buffersConfigured = (rc == 0);
    return m_buffersConfigured;
}

QT_END_NAMESPACE

#include "moc_qeglfsemgdhmi.cpp"
