// MapLibreItem.cpp — QQuickItem MapLibre GL renderer
// Q60 Nav — DCU i386, Mesa swrast (software GL), Qt 6.6
//
// Architecture (HeadlessFrontend path)
// ─────────────────────────────────────
// HeadlessFrontend owns the EGL pbuffer context entirely internally.
// headless_backend_egl.cpp (compiled into libmbgl-core.a) handles all EGL setup
// using Mesa swrast.  We never write EGL code here.
//
// Render flow:
//   scheduleRender()
//     → m_runLoop->runOnce()           drain pending mbgl callbacks/tile loads
//     → m_frontend->render(*m_map)     synchronous — blocks until frame is done
//     → RenderResult.image             PremultipliedImage (RGBA, w×h)
//     → wrap as QImage (zero-copy ref) → deep copy → store in m_rendered
//     → update()                       triggers updatePaintNode() on render thread
//
// Environment variables required on the DCU target:
//   LD_LIBRARY_PATH=/opt/nav/lib
//   LIBGL_DRIVERS_PATH=/opt/nav/lib/dri
//   MESA_GL_VERSION_OVERRIDE=3.3    (if swrast doesn't advertise GL 3.x)
//
// Tile server / offline cache:
//   /opt/nav/tiles/mbgl-cache.db   — SQLite MBTiles or mbgl offline region DB
//   /opt/nav/style/                — style JSON + sprites + glyphs
//   /opt/nav/style/q60-dark.json   — default style

#include "MapLibreItem.h"

#include <QSGImageNode>
#include <QQuickWindow>
#include <QDebug>
#include <QPainter>

#ifdef MAPLIBRE_AVAILABLE
#include <mbgl/util/geo.hpp>
#include <mbgl/util/image.hpp>
#include <mbgl/style/style.hpp>         // mbgl::style::Style — needed for Map::getStyle() calls

#if __has_include(<mbgl/style/sources/geojson_source.hpp>)
#  include <mbgl/style/sources/geojson_source.hpp>
#  define HAVE_GEOJSON_SOURCE 1
#endif

#if __has_include(<mbgl/style/layers/line_layer.hpp>)
#  include <mbgl/style/layers/line_layer.hpp>
#  define HAVE_LINE_LAYER 1
#endif

#if __has_include(<mbgl/style/layers/circle_layer.hpp>)
#  include <mbgl/style/layers/circle_layer.hpp>
#  define HAVE_CIRCLE_LAYER 1
#endif

#include <mbgl/util/color.hpp>
#endif // MAPLIBRE_AVAILABLE

// ═══════════════════════════════════════════════════════════════════════════════
// Placeholder renderer
// ═══════════════════════════════════════════════════════════════════════════════
// Dark-green grid matching NavigationView.qml's fallback Canvas.
// Used when MAPLIBRE_AVAILABLE is not set, or when EGL init throws.

QImage MapLibreItem::makePlaceholderImage(int w, int h) const
{
    if (w <= 0 || h <= 0) return {};
    QImage img(w, h, QImage::Format_ARGB32_Premultiplied);
    img.fill(QColor(0x0f, 0x1a, 0x12));

    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing, false);

    // Grid lines
    p.setPen(QPen(QColor(0x3a, 0xdf, 0x8a, 18), 1));
    for (int x = 0; x < w; x += 60)
        p.drawLine(x, 0, x, h);
    for (int y = 0; y < h; y += 60)
        p.drawLine(0, y, w, y);

    // Large watermark
    p.setPen(QColor(0x1a, 0x2a, 0x1a, 38));
    QFont f;
    f.setPixelSize(96);
    f.setWeight(QFont::Black);
    p.setFont(f);
    p.drawText(img.rect(), Qt::AlignCenter, QStringLiteral("MAP"));

    // Coordinate debug text
    p.setPen(QColor(0x2a, 0x4a, 0x3a, 180));
    QFont f2;
    f2.setPixelSize(11);
    p.setFont(f2);
    p.drawText(8, h - 8,
               QString("%.5f, %.5f  z%.1f")
                   .arg(m_center.latitude())
                   .arg(m_center.longitude())
                   .arg(m_zoom));
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
    setAntialiasing(false); // Software renderer — skip AA cycles
}

MapLibreItem::~MapLibreItem() = default;

void MapLibreItem::componentComplete()
{
    QQuickItem::componentComplete();
    initMap();
}

// ─── initMap ──────────────────────────────────────────────────────────────────
void MapLibreItem::initMap()
{
#ifdef MAPLIBRE_AVAILABLE
    if (m_ready) return;

    const int w = qMax(static_cast<int>(width()),  32);
    const int h = qMax(static_cast<int>(height()), 32);
    qDebug() << "[MapLibre] Initializing" << w << "x" << h;

    // RunLoop must be created on the thread that will own the Map.
    // This is Qt's main thread in our single-threaded setup.
    m_runLoop = std::make_unique<mbgl::util::RunLoop>(
        mbgl::util::RunLoop::Type::Default);

    try {
        mbgl::Size sz{ static_cast<uint32_t>(w), static_cast<uint32_t>(h) };

        // HeadlessFrontend creates and owns an EGL pbuffer + Mesa swrast context.
        // headless_backend_egl.cpp (in libmbgl-core.a) handles all EGL wiring.
        // Throws std::runtime_error if EGL / Mesa is unavailable.
        m_frontend = std::make_unique<mbgl::HeadlessFrontend>(
            sz,
            /*pixelRatio=*/1.0f,
            mbgl::gfx::HeadlessBackend::SwapBehaviour::NoFlush,
            mbgl::gfx::ContextMode::Unique);

        mbgl::ResourceOptions resOpts;
        resOpts.withCachePath("/opt/nav/tiles/mbgl-cache.db")
               .withAssetPath("/opt/nav/style/");

        m_map = std::make_unique<mbgl::Map>(
            *m_frontend,
            mbgl::MapObserver::nullObserver(),
            mbgl::MapOptions()
                .withMapMode(mbgl::MapMode::Static)
                .withConstrainMode(mbgl::ConstrainMode::HeightOnly)
                .withViewportMode(mbgl::ViewportMode::Default)
                .withSize(sz)
                .withPixelRatio(1.0f),
            resOpts);

        m_map->getStyle().loadURL(m_style.toStdString());
        applyCamera();

        m_ready = true;
        emit readyChanged(true);
        qDebug() << "[MapLibre] Map created — scheduling first render";

        scheduleRender();

    } catch (const std::exception &e) {
        qWarning() << "[MapLibre] Init failed:" << e.what()
                   << "— falling back to placeholder";
        m_rendered = makePlaceholderImage(w, h);
        update();
    }

#else // !MAPLIBRE_AVAILABLE
    qDebug() << "[MapLibre] Not compiled — using placeholder";
    m_rendered = makePlaceholderImage(
        qMax(static_cast<int>(width()),  32),
        qMax(static_cast<int>(height()), 32));
    update();
#endif
}

// ─── applyCamera ──────────────────────────────────────────────────────────────
void MapLibreItem::applyCamera()
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_map) return;
    m_map->jumpTo(
        mbgl::CameraOptions()
            .withCenter(mbgl::LatLng{ m_center.latitude(), m_center.longitude() })
            .withZoom(m_zoom)
            .withBearing(m_bearing)
            .withPitch(m_pitch));
#endif
}

// ─── scheduleRender ───────────────────────────────────────────────────────────
// Drains mbgl's run loop (processes tile loads, timers, etc.) then calls
// HeadlessFrontend::render() synchronously.  Returns immediately if map is not
// initialised.
void MapLibreItem::scheduleRender()
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_frontend || !m_map) return;

    // Drain any pending mbgl work (tile fetches, async tasks) before rendering.
    if (m_runLoop) m_runLoop->runOnce();

    try {
        auto result = m_frontend->render(*m_map);
        const auto &img = result.image;

        if (!img.valid()) {
            // Map not yet ready (tiles still loading) — keep showing previous frame
            // or placeholder; schedule another render attempt.
            if (m_rendered.isNull())
                m_rendered = makePlaceholderImage(
                    qMax(static_cast<int>(width()),  32),
                    qMax(static_cast<int>(height()), 32));
            update();
            return;
        }

        // Wrap mbgl image in QImage (zero-copy, shared buffer reference).
        // Deep-copy immediately before mbgl can reclaim the buffer.
        QImage frame(
            reinterpret_cast<const uchar *>(img.data.get()),
            static_cast<int>(img.size.width),
            static_cast<int>(img.size.height),
            QImage::Format_RGBA8888_Premultiplied);
        m_rendered = frame.copy();

    } catch (const std::exception &e) {
        qWarning() << "[MapLibre] render() threw:" << e.what()
                   << "— showing placeholder";
        m_rendered = makePlaceholderImage(
            qMax(static_cast<int>(width()),  32),
            qMax(static_cast<int>(height()), 32));
    }

    update(); // triggers updatePaintNode() on the render thread
#endif
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
    if (m_frontend && m_map) {
        mbgl::Size sz{ static_cast<uint32_t>(w), static_cast<uint32_t>(h) };
        m_frontend->setSize(sz);
        m_map->setSize(sz);
        scheduleRender();
        return;
    }
#endif

    // Not yet initialised — refresh placeholder at new size.
    m_rendered = makePlaceholderImage(w, h);
    update();
}

// ─── updatePaintNode ──────────────────────────────────────────────────────────
// Called on the Qt render thread.  Presents m_rendered as a QSGImageNode.
QSGNode *MapLibreItem::updatePaintNode(QSGNode *oldNode,
                                        UpdatePaintNodeData *)
{
    if (m_rendered.isNull()) {
        m_rendered = makePlaceholderImage(
            qMax(static_cast<int>(width()),  1),
            qMax(static_cast<int>(height()), 1));
    }

    QSGImageNode *node = static_cast<QSGImageNode *>(oldNode);
    if (!node) node = window()->createImageNode();

    // Upload texture; destroy the old one first (node doesn't own old tex life).
    QSGTexture *oldTex = node->texture();
    QSGTexture *tex = window()->createTextureFromImage(
        m_rendered, QQuickWindow::TextureHasAlphaChannel);
    node->setTexture(tex);
    node->setRect(boundingRect());
    delete oldTex;

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
    if (m_map) { applyCamera(); scheduleRender(); }
#else
    m_rendered = makePlaceholderImage(
        qMax(static_cast<int>(width()),  32),
        qMax(static_cast<int>(height()), 32));
    update();
#endif
}

void MapLibreItem::setZoom(double z)
{
    if (qFuzzyCompare(z, m_zoom)) return;
    m_zoom = z;
    emit zoomChanged(z);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { applyCamera(); scheduleRender(); }
#else
    m_rendered = makePlaceholderImage(
        qMax(static_cast<int>(width()),  32),
        qMax(static_cast<int>(height()), 32));
    update();
#endif
}

void MapLibreItem::setBearing(double b)
{
    if (qFuzzyCompare(b, m_bearing)) return;
    m_bearing = b;
    emit bearingChanged(b);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { applyCamera(); scheduleRender(); }
#endif
}

void MapLibreItem::setPitch(double p)
{
    if (qFuzzyCompare(p, m_pitch)) return;
    m_pitch = p;
    emit pitchChanged(p);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { applyCamera(); scheduleRender(); }
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

// ─── addMarker ────────────────────────────────────────────────────────────────
// Adds a circle layer at the given coordinates.  Each marker gets its own
// GeoJSON source + CircleLayer keyed by `id`.
void MapLibreItem::addMarker(double lat, double lon,
                              const QString &id, const QVariantMap &)
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_map) return;

#ifdef HAVE_GEOJSON_SOURCE
#ifdef HAVE_CIRCLE_LAYER
    auto &style = m_map->getStyle();
    const std::string srcId  = id.toStdString();
    const std::string lyrId  = srcId;

    // Remove stale layer/source if re-adding same id.
    try { style.removeLayer(lyrId);   } catch (...) {}
    try { style.removeSource(srcId);  } catch (...) {}

    // Build GeoJSON Point feature.
    mapbox::geojson::point pt{ lon, lat };
    mapbox::geojson::feature feat{ pt };
    mapbox::geojson::feature_collection fc{ feat };
    mbgl::GeoJSON geojson{ fc };

    auto src = std::make_unique<mbgl::style::GeoJSONSource>(srcId);
    src->setGeoJSON(geojson);
    style.addSource(std::move(src));

    auto layer = std::make_unique<mbgl::style::CircleLayer>(lyrId, srcId);
    // Route blue: #4A90E2 premultiplied → r=0.29, g=0.565, b=0.886
    layer->setCircleColor(mbgl::style::PropertyValue<mbgl::Color>(
        mbgl::Color{ 0.29f, 0.565f, 0.886f, 1.0f }));
    layer->setCircleRadius(mbgl::style::PropertyValue<float>(8.0f));
    layer->setCircleStrokeColor(mbgl::style::PropertyValue<mbgl::Color>(
        mbgl::Color::white()));
    layer->setCircleStrokeWidth(mbgl::style::PropertyValue<float>(2.0f));
    style.addLayer(std::move(layer));

    m_markerIds.append(id);
    scheduleRender();
#else
    // TODO: CircleLayer header unavailable — marker not rendered
    Q_UNUSED(lat); Q_UNUSED(lon); Q_UNUSED(id);
#endif
#else
    // TODO: GeoJSONSource header unavailable — marker not rendered
    Q_UNUSED(lat); Q_UNUSED(lon); Q_UNUSED(id);
#endif

#else // !MAPLIBRE_AVAILABLE
    Q_UNUSED(lat); Q_UNUSED(lon); Q_UNUSED(id);
    update();
#endif
}

// ─── removeMarker ─────────────────────────────────────────────────────────────
void MapLibreItem::removeMarker(const QString &id)
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_map) return;
    auto &style = m_map->getStyle();
    const std::string lyrId = id.toStdString();
    try { style.removeLayer(lyrId);  } catch (...) {}
    try { style.removeSource(lyrId); } catch (...) {}
    m_markerIds.removeAll(id);
    scheduleRender();
#else
    Q_UNUSED(id);
#endif
}

// ─── clearRoute ───────────────────────────────────────────────────────────────
void MapLibreItem::clearRoute()
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_map) return;
    auto &style = m_map->getStyle();
    try { style.removeLayer("route-line");   } catch (...) {}
    try { style.removeSource("route-line"); } catch (...) {}
    scheduleRender();
#endif
}

// ─── showRoute ────────────────────────────────────────────────────────────────
// coordinates: QVariantList where each element is a QGeoCoordinate or a
// QVariantMap with "lat"/"lon" keys.
void MapLibreItem::showRoute(const QVariantList &coordinates)
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_map || coordinates.isEmpty()) return;

#if defined(HAVE_GEOJSON_SOURCE) && defined(HAVE_LINE_LAYER)
    // Clear any previous route first.
    clearRoute();

    // Build a GeoJSON LineString from the coordinate list.
    mapbox::geojson::line_string line;
    line.reserve(static_cast<std::size_t>(coordinates.size()));

    for (const QVariant &v : coordinates) {
        double lat = 0.0, lon = 0.0;
        if (v.canConvert<QGeoCoordinate>()) {
            const auto gc = v.value<QGeoCoordinate>();
            lat = gc.latitude();
            lon = gc.longitude();
        } else if (v.canConvert<QVariantMap>()) {
            const auto m = v.toMap();
            lat = m.value(QStringLiteral("lat")).toDouble();
            lon = m.value(QStringLiteral("lon")).toDouble();
        } else {
            continue;
        }
        line.push_back({ lon, lat });
    }

    if (line.size() < 2) {
        qWarning() << "[MapLibre] showRoute: need at least 2 points, got"
                   << line.size();
        return;
    }

    mapbox::geojson::feature feat{ line };
    mapbox::geojson::feature_collection fc{ feat };
    mbgl::GeoJSON geojson{ fc };

    auto &style = m_map->getStyle();

    auto src = std::make_unique<mbgl::style::GeoJSONSource>("route-line");
    src->setGeoJSON(geojson);
    style.addSource(std::move(src));

    auto layer = std::make_unique<mbgl::style::LineLayer>("route-line", "route-line");
    // Route blue #4A90E2 — premultiplied: r=0.29, g=0.565, b=0.886
    layer->setLineColor(mbgl::style::PropertyValue<mbgl::Color>(
        mbgl::Color{ 0.29f, 0.565f, 0.886f, 1.0f }));
    layer->setLineWidth(mbgl::style::PropertyValue<float>(4.0f));
    layer->setLineOpacity(mbgl::style::PropertyValue<float>(0.9f));
    style.addLayer(std::move(layer));

    scheduleRender();

#else
    // TODO: geojson_source.hpp or line_layer.hpp not available in this build
    Q_UNUSED(coordinates);
#endif

#else // !MAPLIBRE_AVAILABLE
    Q_UNUSED(coordinates);
    update();
#endif
}
