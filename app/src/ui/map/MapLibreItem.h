#pragma once
// MapLibreItem.h — QQuickItem wrapper for MapLibre GL Native
// Q60 Nav — DCU i386, Mesa swrast (software GL), Qt 6.6
//
// When MAPLIBRE_AVAILABLE is defined (cmake sets it when libmbgl-core.a is found):
//   - Implements mbgl::RendererFrontend to drive a mbgl::Renderer on an offscreen
//     EGL/Mesa surface, rendering into a QImage that is composited via QSGImageNode.
//   - Exposes Q_PROPERTYs for center, zoom, bearing, pitch, style, ready.
//   - Q_INVOKABLEs: flyTo, addMarker, removeMarker, clearRoute, showRoute.
//
// When not defined: registers an inert QML type; NavigationView falls back to its
// placeholder Rectangle.
//
// Registered QML type name: "MapLibreMap" (see main.cpp / qmlRegisterType call).
//
// API notes (confirmed from output/maplibre-i386/include/):
//   - mbgl::Map ctor: Map(RendererFrontend&, MapObserver&, MapOptions, ResourceOptions)
//   - Style URL: map.getStyle().loadURL(std::string)
//   - Camera: map.jumpTo(CameraOptions) — CameraOptions uses optional<double> fields
//   - Render: map.renderStill(StillImageCallback) — async callback on completion
//   - RendererFrontend is a pure-virtual interface we implement here.

#include <QQuickItem>
#include <QGeoCoordinate>
#include <QVariantMap>
#include <QImage>

#ifdef MAPLIBRE_AVAILABLE
#include <mbgl/map/map.hpp>
#include <mbgl/map/map_options.hpp>
#include <mbgl/map/map_observer.hpp>
#include <mbgl/map/camera.hpp>
#include <mbgl/renderer/renderer_frontend.hpp>
#include <mbgl/renderer/renderer.hpp>
#include <mbgl/renderer/renderer_observer.hpp>
#include <mbgl/gfx/renderer_backend.hpp>
#include <mbgl/gl/renderer_backend.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/util/run_loop.hpp>
#include <mbgl/util/image.hpp>

#include <memory>
#include <functional>
#include <shared_mutex>

// ─── Forward declarations ──────────────────────────────────────────────────────

// OffscreenBackend: subclass of mbgl::gl::RendererBackend that creates and owns
// an EGL pbuffer surface backed by Mesa swrast.  The implementation lives in
// MapLibreItem.cpp and is only compiled when MAPLIBRE_AVAILABLE is set.
//
// TODO: This class requires EGL headers (egl.h, eglext.h) and must be linked
// against libEGL (Mesa swrast build provides it at /opt/nav/lib/libEGL.so).
// Until the EGL wiring is confirmed working on the DCU target, initMap() will
// leave m_backend null and render a placeholder QImage.
class OffscreenBackend;

// ─── MinimalRendererFrontend ──────────────────────────────────────────────────
// Implements mbgl::RendererFrontend: bridges the Map (caller) and the Renderer
// (consumer).  Follows the same single-threaded pattern used by the MapLibre
// Android SDK's GLSurfaceRenderer — all calls happen on Qt's main thread so we
// do not need explicit locking beyond what mbgl expects.
class MinimalRendererFrontend final : public mbgl::RendererFrontend {
public:
    // Callback fired after render() completes with a premultiplied RGBA image.
    using FrameCallback = std::function<void(mbgl::PremultipliedImage)>;

    explicit MinimalRendererFrontend(mbgl::gfx::RendererBackend& backend,
                                     float pixelRatio,
                                     FrameCallback cb);
    ~MinimalRendererFrontend() override;

    // RendererFrontend interface
    void reset()                                              override;
    void setObserver(mbgl::RendererObserver& obs)             override;
    void update(std::shared_ptr<mbgl::UpdateParameters> params) override;

    // Called by MapLibreItem when it wants a frame (e.g. after jumpTo or style change).
    // Synchronously invokes Renderer::render() and fires the FrameCallback if a full
    // frame was produced.
    void renderFrame();

    mbgl::Renderer* renderer() const { return m_renderer.get(); }

private:
    std::unique_ptr<mbgl::Renderer>           m_renderer;
    std::shared_ptr<mbgl::UpdateParameters>   m_updateParams;
    FrameCallback                             m_frameCb;
    bool                                      m_dirty = false;
};
#endif // MAPLIBRE_AVAILABLE

// ─── MapLibreItem ─────────────────────────────────────────────────────────────
class MapLibreItem : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QGeoCoordinate center   READ center   WRITE setCenter   NOTIFY centerChanged)
    Q_PROPERTY(double          zoom    READ zoom     WRITE setZoom     NOTIFY zoomChanged)
    Q_PROPERTY(double          bearing READ bearing  WRITE setBearing  NOTIFY bearingChanged)
    Q_PROPERTY(double          pitch   READ pitch    WRITE setPitch    NOTIFY pitchChanged)
    Q_PROPERTY(QString         style   READ style    WRITE setStyle    NOTIFY styleChanged)
    Q_PROPERTY(bool            ready   READ ready                      NOTIFY readyChanged)

public:
    explicit MapLibreItem(QQuickItem *parent = nullptr);
    ~MapLibreItem() override;

    QGeoCoordinate center()  const { return m_center; }
    double zoom()            const { return m_zoom; }
    double bearing()         const { return m_bearing; }
    double pitch()           const { return m_pitch; }
    QString style()          const { return m_style; }
    bool ready()             const { return m_ready; }

    void setCenter(const QGeoCoordinate &c);
    void setZoom(double z);
    void setBearing(double b);
    void setPitch(double p);
    void setStyle(const QString &url);

public slots:
    Q_INVOKABLE void flyTo(double lat, double lon, double zoom = -1);
    Q_INVOKABLE void addMarker(double lat, double lon, const QString &id,
                                const QVariantMap &props = {});
    Q_INVOKABLE void removeMarker(const QString &id);
    Q_INVOKABLE void clearRoute();
    Q_INVOKABLE void showRoute(const QVariantList &coordinates);

signals:
    void centerChanged(QGeoCoordinate);
    void zoomChanged(double);
    void bearingChanged(double);
    void pitchChanged(double);
    void styleChanged(QString);
    void readyChanged(bool);
    void mapClicked(double lat, double lon);

protected:
    QSGNode *updatePaintNode(QSGNode *oldNode,
                             UpdatePaintNodeData *data) override;
    void componentComplete() override;
    void geometryChange(const QRectF &newGeometry,
                        const QRectF &oldGeometry) override;

private:
    void initMap();
    void applyCamera();
    void scheduleRender();
    void onFrameReady(QImage frame);

    QGeoCoordinate m_center{35.5, -79.0}; // Default: central NC; update as needed
    double m_zoom    = 12.0;
    double m_bearing = 0.0;
    double m_pitch   = 0.0;
    QString m_style  = QStringLiteral("file:///opt/nav/style/q60-dark.json");
    bool m_ready     = false;
    bool m_dirty     = true;

    QImage m_rendered; // Latest rendered frame, updated from onFrameReady()

#ifdef MAPLIBRE_AVAILABLE
    std::unique_ptr<mbgl::util::RunLoop>       m_runLoop;
    std::unique_ptr<OffscreenBackend>          m_backend;
    std::unique_ptr<MinimalRendererFrontend>   m_frontend;
    std::unique_ptr<mbgl::Map>                 m_map;
#endif
};
