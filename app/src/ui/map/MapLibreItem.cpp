// MapLibreItem.cpp — QQuickItem MapLibre GL renderer
// Phase 3 implementation — renders into a QSGImageNode via software (swrast)

#include "MapLibreItem.h"
#include <QSGImageNode>
#include <QQuickWindow>
#include <QDebug>

#ifdef MAPLIBRE_AVAILABLE
#include <mbgl/map/camera.hpp>
#include <mbgl/util/geo.hpp>
#include <mbgl/util/image.hpp>
#include <mbgl/gfx/headless_backend.hpp>
#endif

MapLibreItem::MapLibreItem(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
    setAntialiasing(false); // Software render on Atom — don't burn cycles
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

    qDebug() << "[MapLibre] Initializing headless frontend"
             << width() << "x" << height();

    m_runLoop = std::make_unique<mbgl::util::RunLoop>();

    mbgl::HeadlessFrontend::Options opts;
    opts.size = { static_cast<uint32_t>(width()),
                  static_cast<uint32_t>(height()) };
    opts.pixelRatio = 1.0f;

    m_frontend = std::make_unique<mbgl::HeadlessFrontend>(opts);

    mbgl::MapOptions mapOpts;
    mapOpts.withMapMode(mbgl::MapMode::Static)
           .withConstrainMode(mbgl::ConstrainMode::HeightOnly)
           .withViewportMode(mbgl::ViewportMode::Default);

    mbgl::ResourceOptions resOpts;
    resOpts.withAssetPath("/opt/nav")
           .withCachePath("/data/mbgl-cache.db");

    m_map = std::make_unique<mbgl::Map>(
        *m_frontend,
        mbgl::MapObserver::nullObserver(),
        mapOpts,
        resOpts
    );

    m_map->setStyleURL(m_style.toStdString());
    m_map->setZoom(m_zoom);
    m_map->setLatLng({m_center.latitude(), m_center.longitude()});
    m_map->setBearing(m_bearing);
    m_map->setPitch(m_pitch);

    m_ready = true;
    emit readyChanged(true);
    qDebug() << "[MapLibre] Ready";
    update();
#else
    qDebug() << "[MapLibre] Not available — using placeholder";
    m_ready = false;
#endif
}

void MapLibreItem::geometryChange(const QRectF &newGeometry,
                                   const QRectF &oldGeometry)
{
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    if (newGeometry.size() != oldGeometry.size()) {
        m_dirty = true;
        update();
    }
}

QSGNode *MapLibreItem::updatePaintNode(QSGNode *oldNode,
                                        UpdatePaintNodeData *)
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_ready) return oldNode;

    if (m_dirty) {
        render();
        m_dirty = false;
    }

    if (m_rendered.isNull()) return oldNode;

    QSGImageNode *node = static_cast<QSGImageNode *>(oldNode);
    if (!node) {
        node = window()->createImageNode();
    }

    QSGTexture *tex = window()->createTextureFromImage(
        m_rendered, QQuickWindow::TextureHasAlphaChannel);
    node->setTexture(tex);
    node->setRect(boundingRect());
    return node;
#else
    Q_UNUSED(oldNode)
    return nullptr;
#endif
}

void MapLibreItem::render()
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_map || !m_frontend) return;

    auto result = m_frontend->render(*m_map);
    auto &img   = result.image;

    m_rendered = QImage(
        reinterpret_cast<const uchar *>(img.data.get()),
        static_cast<int>(img.size.width),
        static_cast<int>(img.size.height),
        QImage::Format_RGBA8888_Premultiplied
    ).copy(); // deep copy — img.data ownership stays in mbgl
#endif
}

// ─── Property setters ─────────────────────────────────────────────────────

void MapLibreItem::setCenter(const QGeoCoordinate &c)
{
    if (c == m_center) return;
    m_center = c;
    emit centerChanged(c);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) {
        m_map->setLatLng({c.latitude(), c.longitude()});
        m_dirty = true; update();
    }
#endif
}

void MapLibreItem::setZoom(double z)
{
    if (qFuzzyCompare(z, m_zoom)) return;
    m_zoom = z;
    emit zoomChanged(z);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { m_map->setZoom(z); m_dirty = true; update(); }
#endif
}

void MapLibreItem::setBearing(double b)
{
    if (qFuzzyCompare(b, m_bearing)) return;
    m_bearing = b;
    emit bearingChanged(b);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { m_map->setBearing(b); m_dirty = true; update(); }
#endif
}

void MapLibreItem::setPitch(double p)
{
    if (qFuzzyCompare(p, m_pitch)) return;
    m_pitch = p;
    emit pitchChanged(p);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { m_map->setPitch(p); m_dirty = true; update(); }
#endif
}

void MapLibreItem::setStyle(const QString &url)
{
    if (url == m_style) return;
    m_style = url;
    emit styleChanged(url);
#ifdef MAPLIBRE_AVAILABLE
    if (m_map) { m_map->setStyleURL(url.toStdString()); m_dirty = true; update(); }
#endif
}

// ─── Q_INVOKABLEs ─────────────────────────────────────────────────────────

void MapLibreItem::flyTo(double lat, double lon, double z)
{
    setCenter(QGeoCoordinate(lat, lon));
    if (z > 0) setZoom(z);
}

void MapLibreItem::addMarker(double lat, double lon,
                              const QString &id, const QVariantMap &)
{
    Q_UNUSED(lat); Q_UNUSED(lon); Q_UNUSED(id);
    // TODO Phase 3: add GeoJSON source + symbol layer via MapLibre Annotations API
    m_dirty = true; update();
}

void MapLibreItem::removeMarker(const QString &id)
{
    Q_UNUSED(id);
    m_dirty = true; update();
}

void MapLibreItem::clearRoute()
{
#ifdef MAPLIBRE_AVAILABLE
    if (!m_map) return;
    // Remove route layer and source
    try {
        m_map->removeLayer("q60-route");
        m_map->removeSource("q60-route-src");
    } catch (...) {}
    m_dirty = true; update();
#endif
}

void MapLibreItem::showRoute(const QVariantList &coordinates)
{
    Q_UNUSED(coordinates);
    // TODO Phase 3: inject GeoJSON LineString from Valhalla shape into MapLibre source
    // m_map->addSource("q60-route-src", geojson);
    // m_map->addLayer(lineLayer);
    m_dirty = true; update();
}
