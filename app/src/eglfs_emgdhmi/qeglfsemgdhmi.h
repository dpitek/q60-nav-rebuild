// qeglfsemgdhmi.h — Qt6 EGLFS device-integration plugin for the EMGD HMI
//                  pixmap surface contract (Plan B''' Q60 nav).
//
// This is the surgical wrap that translates Qt's eglfs platform plugin's
// EGL-device-integration API onto the factory EMGD HMI broker (emgdhmid +
// libemgdhmi.so.0 + libwsegl-hmi.so). It makes Qt 6.6.3 paint into a
// pixmap that emgd.ko then scans out onto LVDS upper (screen 0).
//
// Reference: docs/forensic-factory-ui-binary.md §9.1
//            docs/forensic-emgdbuffertype-struct.md §10
//            docs/forensic-libemgdhmi-api.md §2 (signatures)
//            app/src/planb_spike/q60_planb_spike4_configure_buffers.c
//
// Lifecycle:
//   platformInit()              → dlopen libemgdhmi + emgdHmiGetNativeDisplay
//   createNativeWindow(...)     → emgdHmiCreatePixmap + emgdHmiConfigureBuffers
//   destroyNativeWindow(...)    → emgdHmiDestroyPixmap
//   presentBuffer(...)          → (optional) emgdHmiRequestFlip after first swap

#ifndef QEGLFSEMGDHMI_H
#define QEGLFSEMGDHMI_H

#include <private/qeglfsdeviceintegration_p.h>
#include <QSize>
#include <QtCore/qglobal.h>
#include <cstdint>

QT_BEGIN_NAMESPACE

class QEglFSEmgdHmiIntegration : public QEglFSDeviceIntegration
{
public:
    QEglFSEmgdHmiIntegration();
    ~QEglFSEmgdHmiIntegration() override;

    // QEglFSDeviceIntegration overrides
    void platformInit() override;
    void platformDestroy() override;
    EGLNativeDisplayType platformDisplay() const override;
    QSize screenSize() const override;
    QSizeF physicalScreenSize() const override;
    QSurfaceFormat surfaceFormatFor(const QSurfaceFormat &inputFormat) const override;
    EGLint surfaceType() const override;
    EGLNativeWindowType createNativeWindow(QPlatformWindow *platformWindow,
                                           const QSize &size,
                                           const QSurfaceFormat &format) override;
    void destroyNativeWindow(EGLNativeWindowType window) override;
    void presentBuffer(QPlatformSurface *surface) override;
    bool hasCapability(QPlatformIntegration::Capability cap) const override;
    bool supportsPBuffers() const override;
    bool supportsSurfacelessContexts() const override;

private:
    // Forensic-recovered struct — see docs/forensic-emgdbuffertype-struct.md §1
    // 56-byte, packed, 4-byte aligned. Plane_type 0 is sentinel (end of list).
    struct EMGDHmiBufferState {
        uint32_t plane_type;         // 0x00 — 1 = EMGD_HMI_BUFFER
        uint32_t pixmap_handle;      // 0x04 — low 32 bits of EGLNativePixmapType
        uint32_t pixmap_handle_hi;   // 0x08 — always 0
        int32_t  screen_x;           // 0x0c
        int32_t  screen_y;           // 0x10
        int32_t  src_x;              // 0x14
        int32_t  src_y;              // 0x18
        int32_t  width;              // 0x1c
        int32_t  height;             // 0x20
        uint32_t stride;             // 0x24 — byte-pitch
        uint32_t flags0;             // 0x28 — 0 (safe default)
        uint32_t flags1;             // 0x2c
        uint32_t flags2;             // 0x30
        uint32_t flags3;             // 0x34
    };
    static_assert(sizeof(EMGDHmiBufferState) == 56,
                  "EMGDHmiBufferState must be exactly 56 bytes (0x38)");

    // libemgdhmi.so.0 function pointers (resolved via dlsym in platformInit)
    void *m_libemgdhmi = nullptr;
    int (*m_GetNativeDisplay)(void **) = nullptr;
    int (*m_GetNumScreens)(void *) = nullptr;
    int (*m_CreatePixmap)(void *, int /*type*/, int /*w*/, int /*h*/, void **) = nullptr;
    int (*m_DestroyPixmap)(void *, void *) = nullptr;
    int (*m_ConfigureBuffers)(void *, EMGDHmiBufferState **) = nullptr;
    int (*m_RequestFlip)(void *, int /*screen*/, int /*owner*/, int *) = nullptr;
    // 6-arg MapPixmap — signature per D2 forensic-libemgdhmi-api.md §2 #11
    int (*m_MapPixmap)(void *, void *, unsigned, unsigned, unsigned, void **) = nullptr;

    void *m_ndpy = nullptr;       // EMGD native display handle (magic 0xd39ade6b)
    void *m_pixmap = nullptr;     // Our scanout pixmap (single, screen 0)
    void *m_pixmap_vaddr = nullptr; // CPU virtual address from MapPixmap — readback target
    QSize m_size{800, 480};       // Upper LVDS only for now
    bool m_buffersConfigured = false;
    bool m_flipRequested = false; // RequestFlip is a no-op stub per D3, but cheap to call

    bool configureBuffers();
    void readbackToPixmap();      // glReadPixels post-swap → memcpy into vaddr
};

class QEglFSEmgdHmiIntegrationPlugin : public QEglFSDeviceIntegrationPlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QEglFSDeviceIntegrationFactoryInterface_iid
                      FILE "eglfs_emgdhmi.json")
public:
    QEglFSDeviceIntegration *create() override { return new QEglFSEmgdHmiIntegration; }
};

QT_END_NAMESPACE

#endif // QEGLFSEMGDHMI_H
