// CameraFeed — isolated QtMultimedia component
// Loaded via Loader in RearCameraView so that if QtMultimedia 6.6
// is unavailable on this Mesa softpipe build the Loader.status goes
// to Loader.Error cleanly, activating the placeholder instead.
import QtQuick 2.15
import QtMultimedia 5.15

Item {
    id: root
    anchors.fill: parent

    MediaPlayer {
        id: player
        source:    "v4l2:///dev/video0"
        autoPlay:  true
        loops:     MediaPlayer.Infinite

        onError: {
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
