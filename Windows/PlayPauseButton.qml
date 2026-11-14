// Play / pause: a larger bare glyph in the primary text colour (the Mac's PlayPauseButton).
import QtQuick
import I2S

GlyphButton {
    property bool playing: false
    size: 28
    iconSize: size * 0.62
    icon: playing ? "pause.fill" : "play.fill"
    restColor: Skin.textPrimary
    help: playing ? "Pause" : "Play"
}
