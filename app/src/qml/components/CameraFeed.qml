// CameraFeed — isolated QtMultimedia component
// Loaded via Loader in RearCameraView so that if QtMultimedia 6.6
// is unavailable on this Mesa softpipe build the Loader.status goes
// to Loader.Error cleanly, activating the placeholder instead.
import QtQuick
import QtMultimedia 6.6

Item {
    id: root
    anchors.fill: parent

    MediaPlayer {
        id: player
        source:    "v4l2:///dev/video0"
        autoPlay:  true
        loops:     MediaPlayer.Infinite

        onErrorOccurred: {
            console.log("[CameraFeed] MediaPlayer error:", errorString)
        }
    }

    VideoOutput {
        id:          videoOutput
        anchors.fill: parent
        fillMode:    VideoOutput.PreserveAspectCrop
        player:      player
    }
}
