// MapLibreItem.cpp — QQuickItem MapLibre GL renderer
// Q60 Nav — DCU i386, Mesa swrast (software GL), Qt 6.6
//
// Architecture overview
// ─────────────────────
// Map (state machine) → MinimalRendererFrontend::update() → stores UpdateParameters
//   └─ MapLibreItem::scheduleRender() → MinimalRendererFrontend::renderFrame()
//        └─ mbgl::Renderer::render(updateParams) — draws into EGL pbuffer (Mesa swrast)
//             └─ OffscreenBackend::readFramebuffer() → PremultipliedImage
//                  └─ onFrameReady(QImage) → m_rendered updated → QSGImageNode refresh
//
// EGL / Mesa wiring
// ─────────────────
// OffscreenBackend must create an EGL display (eglGetDisplay(EGL_DEFAULT_DISPLAY)),
// a pbuffer surface, and a GL context.  On the DCU target Mesa swrast provides:
//   /opt/nav/lib/libEGL.so, /opt/nav/lib/libGL.so (swrast driver)
// Set LD_LIBRARY_PATH=/opt/nav/lib and LIBGL_DRIVERS_PATH=/opt/nav/lib/dri
// before launching the process.
//
// TODO checklist before enabling MAPLIBRE_AVAILABLE on the DCU:
//   [1] Implement OffscreenBackend::activate()/deactivate() with eglMakeCurrent()
//   [2] Implement OffscreenBackend::getExtensionFunctionPointer() with eglGetProcAddress()
//   [3] Implement OffscreenBackend::getDefaultRenderable() returning a gl::Renderable
//       that wraps the pbuffer FBO.
//   [4] Verify libmbgl-core.a is linked: target_link_libraries(q60nav mbgl-core)
//   [5] Confirm style JSON at /opt/nav/style/q60-dark.json is valid MapLibre style spec.
//   [6] Run with MESA_DEBUG=1 LIBGL_DEBUG=verbose to confirm swrast is loading.

#include "MapLibreItem.h"

#include <QSGImageNode>
#include <QQuickWindow>
#include <QDebug>
#include <QPainter>

#ifdef MAPLIBRE_AVAILABLE
#include <mbgl/map/camera.hpp>
#include <mbgl/util/geo.hpp>
#include <mbgl/util/image.hpp>
#include <mbgl/gfx/backend_scope.hpp>

// ═══════════════════════════════════════════════════════════════════════════════
// OffscreenBackend
// ═══════════════════════════════════════════════════════════════════════════════
// Subclasses mbgl::gl::RendererBackend to manage an EGL pbuffer + Mesa swrast
// context.  All methods below marked TODO require EGL implementation before
// the MAPLIBRE_AVAILABLE path is activated.

#include <mbgl/gl/renderable_resource.hpp>

// ── PbufferRenderableResource ──────────────────────────────────────────────────
// Wraps the EGL pbuffer surface as a gl::RenderableResource.
// bind() must call eglMakeCurrent on the pbuffer before mbgl renders.
class PbufferRenderableResource final : public mbgl::gl::RenderableResource {
public:
    explicit PbufferRenderableResource() = default;

    void bind() override {
        // TODO: eglMakeCurrent(m_display, m_pbuffer, m_pbuffer, m_context)
        // Bind the default (window/pbuffer) framebuffer: glBindFramebuffer(GL_FRAMEBUFFER, 0)
    }

    void swap() override {
        // Pbuffer — no swap needed; pixels are read back via readFramebuffer()
    }
};

// ── PbufferRenderable ──────────────────────────────────────────────────────────
class PbufferRenderable final : public mbgl::gfx::Renderable {
public:
    explicit PbufferRenderable(mbgl::Size size)
        : mbgl::gfx::Renderable(size, std::make_unique<PbufferRenderableResource>())
    {}

    void resize(mbgl::Size newSize) { size = newSize; }
};

// ── OffscreenBackend ───────────────────────────────────────────────────────────
class OffscreenBackend final : public mbgl::gl::RendererBackend {
public:
    explicit OffscreenBackend(mbgl::Size size)
        : mbgl::gl::RendererBackend(mbgl::gfx::ContextMode::Unique)
        , m_renderable(size)
    {
        // TODO: create EGL display, config, pbuffer surface, and GL context.
        // Pseudocode:
        //   m_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        //   eglInitialize(m_display, nullptr, nullptr);
        //   EGLint attrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        //                      EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        //                      EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
        //                      EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE };
        //   EGLConfig cfg; EGLint n;
        //   eglChooseConfig(m_display, attrs, &cfg, 1, &n);
        //   EGLint pbAttrs[] = { EGL_WIDTH, (EGLint)size.width,
        //                         EGL_HEIGHT, (EGLint)size.height, EGL_NONE };
        //   m_pbuffer = eglCreatePbufferSurface(m_display, cfg, pbAttrs);
        //   m_context = eglCreateContext(m_display, cfg, EGL_NO_CONTEXT, nullptr);
        //   eglMakeCurrent(m_display, m_pbuffer, m_pbuffer, m_context);
        qDebug() << "[MapLibre] OffscreenBackend created (EGL TODO)";
    }

    ~OffscreenBackend() override {
        // TODO: eglDestroyContext / eglDestroySurface / eglTerminate
    }

    // Resize the pbuffer when the QQuickItem changes size.
    void resize(mbgl::Size newSize) {
        m_renderable.resize(newSize);
        // TODO: destroy and recreate pbuffer surface at new dimensions.
    }

    // Read pixels from the currently bound framebuffer into a PremultipliedImage.
    mbgl::PremultipliedImage readPixels() {
        // Delegates to the protected readFramebuffer() method from gl::RendererBackend.
        // This calls glReadPixels internally.
        return readFramebuffer(m_renderable.getSize());
    }

    // ── RendererBackend interface ────────────────────────────────────────────
    mbgl::gfx::Renderable& getDefaultRenderable() override {
        return m_renderable;
    }

    void updateAssumedState() override {
        // Called before each render pass.  Tell mbgl which FBO is currently bound.
        assumeFramebufferBinding(0); // Default framebuffer (pbuffer)
        assumeViewport(0, 0, m_renderable.getSize());
        assumeScissorTest(false);
    }

protected:
    void activate() override {
        // TODO: eglMakeCurrent(m_display, m_pbuffer, m_pbuffer, m_context)
    }

    void deactivate() override {
        // TODO: eglMakeCurrent(m_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)
    }

    ProcAddress getExtensionFunctionPointer(const char* name) override {
        // TODO: return reinterpret_cast<ProcAddress>(eglGetProcAddress(name));
        Q_UNUSED(name);
        return nullptr;
    }

private:
    PbufferRenderable m_renderable;
    // TODO: EGLDisplay m_display = EGL_NO_DISPLAY;
    // TODO: EGLSurface m_pbuffer = EGL_NO_SURFACE;
    // TODO: EGLContext m_context = EGL_NO_CONTEXT;
};

// ═══════════════════════════════════════════════════════════════════════════════
// MinimalRendererFrontend
// ═══════════════════════════════════════════════════════════════════════════════

MinimalRendererFrontend::MinimalRendererFrontend(mbgl::gfx::RendererBackend& backend,
                                                  float pixelRatio,
                                                  FrameCallback cb)
    : m_renderer(std::make_unique<mbgl::Renderer>(backend, pixelRatio))
    , m_frameCb(std::move(cb))
{}

MinimalRendererFrontend::~MinimalRendererFrontend() = default;

void MinimalRendererFrontend::reset() {
    m_renderer.reset();
}

void MinimalRendererFrontend::setObserver(mbgl::RendererObserver& obs) {
    if (m_renderer) m_renderer->setObserver(&obs);
}

void MinimalRendererFrontend::update(std::shared_ptr<mbgl::UpdateParameters> params) {
    // Coalesce — store the latest params; renderFrame() will consume them.
    m_updateParams = std::move(params);
    m_dirty = true;
    // In a Continuous-mode map this would trigger a repaint via a platform timer.
    // MapLibreItem::scheduleRender() drives the repaint from Qt's update loop.
}

void MinimalRendererFrontend::renderFrame() {
    if (!m_renderer || !m_updateParams || !m_dirty) return;
    m_dirty = false;

    // Renderer::render() issues GL draw calls into the currently bound FBO.
    m_renderer->render(m_updateParams);

    // TODO: After Renderer::render(), the pixels are in the EGL pbuffer.
    // Read them back via OffscreenBackend::readPixels() and fire m_frameCb.
    // For now, m_frameCb is called with an empty image so the Qt side sees
    // a null render and keeps showing the placeholder.
    //
    // When EGL is wired up, replace the line below with:
    //   auto* backend = dynamic_cast<OffscreenBackend*>(
    //       &m_renderer->... /* no direct backend access from Renderer */ );
    // The cleanest way is to store a reference to OffscreenBackend in this
    // class and call it directly.  See MapLibreItem::initMap() where both
    // objects are created together.
    m_frameCb(mbgl::PremultipliedImage{}); // TODO: replace with readPixels()
}

#endif // MAPLIBRE_AVAILABLE

// ═══════════════════════════════════════════════════════════════════════════════
// Placeholder renderer — used when MAPLIBRE_AVAILABLE is not set, or until EGL
// is confirmed working.  Draws the same dark-green grid as NavigationView.qml.
// ═══════════════════════════════════════════════════════════════════════════════
static QImage makePlaceholder(int w, int h,
                               double lat, double lon, double zoom)
{
    if (w <= 0 || h <= 0) return {};
    QImage img(w, h, QImage::Format_ARGB32_Premultiplied);
    img.fill(QColor(0x0f, 0x1a, 0x12));

    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing, false);

    // Grid lines (matches the Canvas in NavigationView.qml)
    p.setPen(QPen(QColor(0x3a, 0xdf, 0x8a, 18), 1));
    for (int x = 0; x < w; x += 60)
        p.drawLine(x, 0, x, h);
    for (int y = 0; y < h; y += 60)
        p.drawLine(0, y, w, y);

    // Watermark
    p.setPen(QColor(0x1a, 0x2a, 0x1a, 38));
    QFont f;
    f.setPixelSize(96);
    f.setWeight(QFont::Black);
    p.setFont(f);
    p.drawText(img.rect(), Qt::AlignCenter, QStringLiteral("MAP"));

    // Coordinates (debug aid)
    p.setPen(QColor(0x2a, 0x4a, 0x3a, 180));
    QFont f2;
    f2.setPixelSize(11);
    p.setFont(f2);
    p.drawText(8, h - 8,
               QString("%.5f, %.5f  z%.1f").arg(lat).arg(lon).arg(zoom));
    p.end();
    return img;
}

// ═══════════════════════════════════════════════════════════════════════════════
// MapLibreItem
// ═══════════════════════════════════════════════════════════════════════════════

MapLibreItem::MapLibreItem(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
    setAntialiasing(false); // Software renderer on Atom — skip AA cycles
}

MapLibreItem::~MapLibreItem() = default;

void MapLibreItem::componentComplete()
{
    QQuickItem::componentComplete();
    initMap();
}

void MapLibreItem::initMap()
{
#ifdef MAPLIBRE_AVAILABLE
    if (m_ready) return;

    const int w = qMax(static_cast<int>(width()),  32);
    const int h = qMax(static_cast<int>(height()), 32);

    qDebug() << "[MapLibre] Initializing" << w << "x" << h;

    // RunLoop must be created on the thread that owns the Map.
    // Qt main thread == mbgl main thread in this single-threaded setup.
    m_runLoop = std::make_unique<mbgl::util::RunLoop>(
        mbgl::util::RunLoop::Type::Default);

    // ── Backend + frontend ───────────────────────────────────────────────────
    // TODO: OffscreenBackend construction will throw / return false until EGL is
    // wired in.  Wrap in try/catch so the fallback placeholder is shown instead
    // of crashing the DCU process.
    try {
        mbgl::Size sz{ static_cast<uint32_t>(w), static_cast<uint32_t>(h) };
        m_backend = std::make_unique<OffscreenBackend>(sz);

        m_frontend = std::make_unique<MinimalRendererFrontend>(
            *m_backend,
            /*pixelRatio=*/1.0f,
            [this](mbgl::PremultipliedImage img) {
                // Called from renderFrame() on the main thread.
                if (!img.valid()) {
                    // EGL not yet wired — show placeholder.
                    onFrameReady(makePlaceholder(
                        static_cast<int>(m_backend
                            ? m_backend->getDefaultRenderable().getSize().width  : w),
                        static_cast<int>(m_backend
                            ? m_backend->getDefaultRenderable().getSize().height : h),
                        m_center.latitude(), m_center.longitude(), m_zoom));
                    return;
                }
                // Valid frame: wrap mbgl image in QImage (zero-copy, deep-copy
                // before mbgl reclaims the buffer).
                QImage frame(
                    reinterpret_cast<const uchar *>(img.data.get()),
                    static_cast<int>(img.size.width),
                    static_cast<int>(img.size.height),
                    QImage::Format_RGBA8888_Premultiplied);
                onFrameReady(frame.copy());
            });
    } catch (const std::exception &e) {
        qWarning() << "[MapLibre] Backend init failed:" << e.what()
                   << "— using placeholder";
        m_rendered = makePlaceholder(w, h,
                                     m_center.latitude(),
                                     m_center.longitude(), m_zoom);
        m_dirty = false;
        update();
        return;
    }

    // ── Map ──────────────────────────────────────────────────────────────────
    mbgl::MapOptions mapOpts;
    mapOpts.withMapMode(mbgl::MapMode::Static)       // Static = render-on-demand
           .withConstrainMode(mbgl::ConstrainMode::HeightOnly)
           .withViewportMode(mbgl::ViewportMode::Default)
           .withSize({ static_cast<uint32_t>(w), static_cast<uint32_t>(h) })
           .withPixelRatio(1.0f);

    mbgl::ResourceOptions resOpts;
    resOpts.withAssetPath("/opt/nav")
           .withCachePath("/data/mbgl-cache.db");
    // Note: no API key needed for locally-hosted tiles.

    m_map = std::make_unique<mbgl::Map>(
        *m_frontend,
        mbgl::MapObserver::nullObserver(),
        mapOpts,
        resOpts
    );

    // ── Initial camera + style ───────────────────────────────────────────────
    // Map::setStyle() requires a unique_ptr<style::Style> which needs a FileSource.
    // The simpler path for URL-based styles is getStyle().loadURL().
    m_map->getStyle().loadURL(m_style.toStdString());

    applyCamera();

    m_ready = true;
    emit readyChanged(true);
    qDebug() << "[MapLibre] Map created — waiting for first frame";

    // Kick the first render; the Map will call frontend->update() as tiles load.
    scheduleRender();

#else // !MAPLIBRE_AVAILABLE
    qDebug() << "[MapLibre] Not compiled — using placeholder";
    m_rendered = makePlaceholder(
        qMax(static_cast<int>(width()),  32),
        qMax(static_cast<int>(height()), 32),
        m_center.latitude(), m_center.longitude(), m_zoom);
    m_dirty = false;
    update();
#endif
}

// ─── applyCamera ──────────────────────────────────────────────────────────────
// Pushes m_center / m_zoom / m_bearing / m_pitch to the Map via CameraOptions.
void MapLibreItem::applyCamera()
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_map) return;
    mbgl::CameraOptions cam;
    cam.withCenter(mbgl::LatLng{ m_center.latitude(), m_center.longitude() })
       .withZoom(m_zoom)
       .withBearing(m_bearing)
       .withPitch(m_pitch);
    m_map->jumpTo(cam);
#endif
}

// ─── scheduleRender ───────────────────────────────────────────────────────────
// Asks the RunLoop to drain any pending mbgl work, then calls renderFrame().
void MapLibreItem::scheduleRender()
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_frontend) return;
    // Drain queued mbgl callbacks (tile loads, timer callbacks, etc.)
    if (m_runLoop) m_runLoop->runOnce();
    m_frontend->renderFrame();
#endif
}

// ─── onFrameReady ─────────────────────────────────────────────────────────────
// Receives a rendered QImage from MinimalRendererFrontend, stores it, and
// triggers a Qt scene-graph update.  Called on the main thread.
void MapLibreItem::onFrameReady(QImage frame)
{
    if (!frame.isNull()) m_rendered = std::move(frame);
    m_dirty = false;
    update(); // triggers updatePaintNode() on the render thread
}

// ─── geometryChange ───────────────────────────────────────────────────────────
void MapLibreItem::geometryChange(const QRectF &newGeometry,
                                   const QRectF &oldGeometry)
{
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    if (newGeometry.size() == oldGeometry.size()) return;

    const int w = qMax(static_cast<int>(newGeometry.width()),  32);
    const int h = qMax(static_cast<int>(newGeometry.height()), 32);

#ifdef MAPLIBRE_AVAILABLE
    if (m_map && m_backend) {
        mbgl::Size sz{ static_cast<uint32_t>(w), static_cast<uint32_t>(h) };
        m_backend->resize(sz);
        m_map->setSize(sz);
    }
#endif

    // Always refresh placeholder when not yet rendering real tiles.
    if (!m_ready || m_rendered.isNull()) {
        m_rendered = makePlaceholder(w, h,
                                     m_center.latitude(),
                                     m_center.longitude(), m_zoom);
    }
    m_dirty = true;
    update();
}

// ─── updatePaintNode ──────────────────────────────────────────────────────────
// Called on the Qt render thread.  Presents m_rendered as a QSGImageNode.
QSGNode *MapLibreItem::updatePaintNode(QSGNode *oldNode,
                                        UpdatePaintNodeData *)
{
    if (m_rendered.isNull()) {
        // Nothing to show yet — seed a placeholder so the screen isn't black.
        const int w = qMax(static_cast<int>(width()),  1);
        const int h = qMax(static_cast<int>(height()), 1);
        m_rendered = makePlaceholder(w, h,
                                     m_center.latitude(),
                                     m_center.longitude(), m_zoom);
    }

    QSGImageNode *node = static_cast<QSGImageNode *>(oldNode);
    if (!node) node = window()->createImageNode();

    // createTextureFromImage() uploads m_rendered to GPU (or software raster).
    // Ownership of the texture passes to the node; destroy the old one first.
    QSGTexture *oldTex = node->texture();
    QSGTexture *tex = window()->createTextureFromImage(
        m_rendered, QQuickWindow::TextureHasAlphaChannel);
    node->setTexture(tex);
    node->setRect(boundingRect());
    delete oldTex; // safe: old texture is no longer referenced by the node

    return node;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Property setters
// ═══════════════════════════════════════════════════════════════════════════════

void MapLibreItem::setCenter(const QGeoCoordinate &c)
{
    if (c == m_center) return;
    m_center = c;
    emit centerChanged(c);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { applyCamera(); m_dirty = true; scheduleRender(); }
#else
    m_rendered = makePlaceholder(
        qMax(static_cast<int>(width()),  32),
        qMax(static_cast<int>(height()), 32),
        m_center.latitude(), m_center.longitude(), m_zoom);
    update();
#endif
}

void MapLibreItem::setZoom(double z)
{
    if (qFuzzyCompare(z, m_zoom)) return;
    m_zoom = z;
    emit zoomChanged(z);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { applyCamera(); m_dirty = true; scheduleRender(); }
#else
    m_rendered = makePlaceholder(
        qMax(static_cast<int>(width()),  32),
        qMax(static_cast<int>(height()), 32),
        m_center.latitude(), m_center.longitude(), m_zoom);
    update();
#endif
}

void MapLibreItem::setBearing(double b)
{
    if (qFuzzyCompare(b, m_bearing)) return;
    m_bearing = b;
    emit bearingChanged(b);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { applyCamera(); m_dirty = true; scheduleRender(); }
#endif
}

void MapLibreItem::setPitch(double p)
{
    if (qFuzzyCompare(p, m_pitch)) return;
    m_pitch = p;
    emit pitchChanged(p);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { applyCamera(); m_dirty = true; scheduleRender(); }
#endif
}

void MapLibreItem::setStyle(const QString &url)
{
    if (url == m_style) return;
    m_style = url;
    emit styleChanged(url);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) {
        m_map->getStyle().loadURL(url.toStdString());
        m_dirty = true;
        scheduleRender();
    }
#endif
}

// ═══════════════════════════════════════════════════════════════════════════════
// Q_INVOKABLEs
// ═══════════════════════════════════════════════════════════════════════════════

void MapLibreItem::flyTo(double lat, double lon, double z)
{
    setCenter(QGeoCoordinate(lat, lon));
    if (z > 0) setZoom(z);
}

void MapLibreItem::addMarker(double lat, double lon,
                              const QString &id, const QVariantMap &)
{
    Q_UNUSED(lat); Q_UNUSED(lon); Q_UNUSED(id);
    // TODO: inject a GeoJSON SymbolSource + SymbolLayer via map.getStyle().addSource()
    // and map.getStyle().addLayer() using mbgl::style::GeoJSONSource /
    // mbgl::style::SymbolLayer.  The annotation API (map.addAnnotation()) is the
    // easier path but supports fewer styling options.
    m_dirty = true;
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) scheduleRender();
#else
    update();
#endif
}

void MapLibreItem::removeMarker(const QString &id)
{
    Q_UNUSED(id);
    // TODO: map.getStyle().removeLayer(id) + removeSource(id)
    m_dirty = true;
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) scheduleRender();
#else
    update();
#endif
}

void MapLibreItem::clearRoute()
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_map) return;
    auto &style = m_map->getStyle();
    // removeLayer/removeSource return unique_ptr; ignore the value.
    try { style.removeLayer("q60-route"); }    catch (...) {}
    try { style.removeSource("q60-route-src"); } catch (...) {}
    m_dirty = true;
    scheduleRender();
#endif
}

void MapLibreItem::showRoute(const QVariantList &coordinates)
{
    Q_UNUSED(coordinates);
    // TODO: Build a GeoJSON LineString from Valhalla polyline shape and inject:
    //   auto src = std::make_unique<mbgl::style::GeoJSONSource>("q60-route-src");
    //   src->setGeoJSON(mapbox::geojson::parse(geojsonStr));
    //   m_map->getStyle().addSource(std::move(src));
    //   auto layer = std::make_unique<mbgl::style::LineLayer>("q60-route", "q60-route-src");
    //   layer->setLineColor(mbgl::style::PropertyExpression<mbgl::Color>(...));
    //   layer->setLineWidth(...);
    //   m_map->getStyle().addLayer(std::move(layer));
    m_dirty = true;
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) scheduleRender();
#else
    update();
#endif
}
