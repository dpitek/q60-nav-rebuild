#pragma once
// MapLibreItem.h — QQuickItem wrapper for MapLibre GL Native
// Q60 Nav — DCU i386, Mesa swrast (software GL), Qt 6.6
//
// When MAPLIBRE_AVAILABLE is defined (cmake sets it when libmbgl-core.a is found):
//   - Uses mbgl::HeadlessFrontend directly — it owns the EGL pbuffer context
//     internally via headless_backend_egl.cpp (Mesa swrast, already compiled in).
//   - HeadlessFrontend::render(Map&) is fully synchronous: call it, get pixels back.
//   - Rendered frames are exposed to Qt as QImage, composited via QSGImageNode.
//   - Exposes Q_PROPERTYs for center, zoom, bearing, pitch, style, ready.
//   - Q_INVOKABLEs: flyTo, addMarker, removeMarker, clearRoute, showRoute.
//
// When not defined: registers an inert QML type; NavigationView falls back to its
// placeholder Rectangle.
//
// Registered QML type name: MapLibreMap (QML_ELEMENT, see CMakeLists).

#include <QQuickItem>
#include <QGeoCoordinate>
#include <QImage>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#ifdef MAPLIBRE_AVAILABLE
// optional shim must come first — mbgl headers pull it in transitively but
// better to be explicit so order never matters.
#include <mbgl/util/optional.hpp>
#include <mbgl/gfx/headless_frontend.hpp>
#include <mbgl/map/map.hpp>
#include <mbgl/map/map_options.hpp>
#include <mbgl/map/map_observer.hpp>
#include <mbgl/map/camera.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/util/run_loop.hpp>
#include <mbgl/util/image.hpp>

#include <memory>
#endif // MAPLIBRE_AVAILABLE

// ─── MapLibreItem ─────────────────────────────────────────────────────────────
class MapLibreItem : public QQuickItem {
    Q_OBJECT
    // Qt 5.15: registered via qmlRegisterType<MapLibreItem>(...) in main.cpp.
    // (Qt 6 QML_NAMED_ELEMENT removed for Plan B Qt 5.15 build.)

    Q_PROPERTY(QGeoCoordinate center   READ center   WRITE setCenter   NOTIFY centerChanged)
    Q_PROPERTY(double          zoom    READ zoom     WRITE setZoom     NOTIFY zoomChanged)
    Q_PROPERTY(double          bearing READ bearing  WRITE setBearing  NOTIFY bearingChanged)
    Q_PROPERTY(double          pitch   READ pitch    WRITE setPitch    NOTIFY pitchChanged)
    Q_PROPERTY(QString         style   READ style    WRITE setStyle    NOTIFY styleChanged)
    Q_PROPERTY(bool            ready          READ ready                           NOTIFY readyChanged)
    Q_PROPERTY(bool            trafficVisible READ trafficVisible WRITE setTrafficVisible NOTIFY trafficVisibleChanged)

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
    void setTrafficVisible(bool visible);
    bool trafficVisible() const { return m_trafficVisible; }

public slots:
    Q_INVOKABLE void flyTo(double lat, double lon, double zoom = -1);
    Q_INVOKABLE void panMap(double dx, double dy);
    Q_INVOKABLE void joystickSelect();
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
    void trafficVisibleChanged(bool);
    void mapClicked(double lat, double lon);

protected:
    QSGNode *updatePaintNode(QSGNode *oldNode,
                             UpdatePaintNodeData *data) override;
    void componentComplete() override;
    // Qt6: QQuickItem renamed to geometryChange (no 'd'). Qt5 used geometryChanged.
    void geometryChange(const QRectF &newGeometry,
                        const QRectF &oldGeometry) override;

private:
    void initMap();
    void applyCamera();
    void scheduleRender();
    QImage makePlaceholderImage(int w, int h) const;

    QGeoCoordinate m_center{35.5, -79.0}; // Default: central NC
    double  m_zoom    = 12.0;
    double  m_bearing = 0.0;
    double  m_pitch   = 0.0;
    QString m_style   = QStringLiteral("file:///opt/nav/style/q60-dark.json");
    bool    m_ready          = false;
    bool    m_trafficVisible = false;

    QImage      m_rendered;      // Latest rendered frame (updated from scheduleRender)
    QStringList m_markerIds;    // Track active marker layer IDs for removeMarker()
    int         m_renderRetries = 0; // Retry counter for silent render exceptions

#ifdef MAPLIBRE_AVAILABLE
    std::unique_ptr<mbgl::util::RunLoop>    m_runLoop;
    std::unique_ptr<mbgl::HeadlessFrontend> m_frontend;
    std::unique_ptr<mbgl::Map>              m_map;
#endif
};
