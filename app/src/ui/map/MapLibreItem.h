#pragma once
// MapLibreItem.h — QQuickItem wrapper for MapLibre GL Native
// Phase 3: replaces the placeholder Rectangle in NavigationView.qml
//
// When MAPLIBRE_AVAILABLE is defined (cmake sets it when libmbgl-core.a found):
//   - Renders vector tiles via MapLibre GL using Mesa software renderer (swrast)
//   - Exposes Q_PROPERTYs for center, zoom, bearing, pitch
//   - Q_INVOKABLEs for flyTo, setStyle, addMarker
//
// When not defined: compile as no-op (NavigationView uses placeholder)

#include <QQuickItem>
#include <QGeoCoordinate>
#include <QVariantMap>

#ifdef MAPLIBRE_AVAILABLE
#include <mbgl/map/map.hpp>
#include <mbgl/gl/headless_frontend.hpp>
#include <mbgl/util/run_loop.hpp>
#endif

class MapLibreItem : public QQuickItem {
    Q_OBJECT

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
    void render();

    QGeoCoordinate m_center{35.7796, -78.6382}; // Raleigh default
    double m_zoom    = 12.0;
    double m_bearing = 0.0;
    double m_pitch   = 0.0;
    QString m_style  = "file:///opt/nav/style/q60-dark.json";
    bool m_ready     = false;
    bool m_dirty     = true;

#ifdef MAPLIBRE_AVAILABLE
    std::unique_ptr<mbgl::util::RunLoop>        m_runLoop;
    std::unique_ptr<mbgl::HeadlessFrontend>     m_frontend;
    std::unique_ptr<mbgl::Map>                  m_map;
    QImage m_rendered;
#endif
};
