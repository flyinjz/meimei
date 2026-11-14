#pragma once
// The audio engine: FFmpeg decodes, miniaudio plays (WASAPI on Windows, Core
// Audio on macOS, PipeWire/PulseAudio/ALSA on Linux). A decode thread fills a
// ring buffer ahead of the device; the next track is decoded straight after
// the current one, so albums play gaplessly. The playhead is the device's
// own position, so the clock never runs ahead of what you hear.
#include <QObject>
#include <QString>
#include <QTimer>
#include <QJSEngine>
#include <qqmlintegration.h>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

class Decoder;
struct ma_device;

class AudioEngine : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(Audio)
    QML_SINGLETON
    Q_PROPERTY(bool playing READ isPlaying NOTIFY playingChanged)
    Q_PROPERTY(double position READ currentTime NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration NOTIFY positionChanged)
    Q_PROPERTY(QString currentID READ currentID NOTIFY positionChanged)
    Q_PROPERTY(float volume READ volume WRITE setVolume NOTIFY volumeChanged)
public:
    explicit AudioEngine(QObject *parent = nullptr);
    ~AudioEngine() override;
    /// The app's one engine (made in main), as QML's `Audio`.
    static AudioEngine *create(class QQmlEngine *, class QJSEngine *) { QJSEngine::setObjectOwnership(s_instance, QJSEngine::CppOwnership); return s_instance; }
    static inline AudioEngine *s_instance = nullptr;

    /// Starts `path` from `startAt` seconds (replacing whatever plays).
    Q_INVOKABLE bool start(const QString &path, const QString &id, double startAt = 0, bool paused = false);
    /// What plays after the current track ends (gapless); empty clears it.
    Q_INVOKABLE void setNext(const QString &path, const QString &id);
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void seek(double seconds);
    void setVolume(float v) { if (v != m_volume.load()) { m_volume.store(v); emit volumeChanged(); } }
    /// Whether the output device is open and running (it closes when idle).
    bool deviceRunning() const { return m_deviceRunning; }
    float volume() const { return m_volume.load(); }

    bool isPlaying() const { return m_playing; }
    QString currentID() const { return m_currentID; }
    double currentTime() const;
    double duration() const { return m_duration; }
    int outputRate() const { return m_rate; }

    /// Called on the audio thread with interleaved stereo floats, after
    /// volume; for the EQ and the analyzer.
    std::function<void(float *frames, int count, int rate)> process;

signals:
    void playingChanged();
    void positionChanged();
    void volumeChanged();
    /// The device moved on to the prepared next track by itself.
    void advanced(const QString &id);
    /// The last track finished and nothing was queued.
    void ended();
    void failed(const QString &path, const QString &why);

private:
    struct Segment { quint64 startFrame; QString id; double startSeconds; double duration; };
    void decodeLoop();
    void stopDecoder();
    void startDecoder();
    void poll();
    void setPlayingState(bool playing);
    void setDeviceRunning(bool on);
    static void callback(ma_device *device, void *out, const void *in, unsigned frames);
    void render(float *out, unsigned frames);

    std::unique_ptr<ma_device> m_device;
    int m_rate = 48000;
    bool m_deviceOK = false;

    // Ring buffer (stereo frames), guarded by m_bufferLock; the device
    // callback only try-locks it and plays silence if it can't.
    std::vector<float> m_ring;
    size_t m_capacity = 0, m_read = 0, m_write = 0, m_fill = 0;
    std::mutex m_bufferLock;

    // Decoding.
    std::thread m_thread;
    std::mutex m_decodeLock;
    std::condition_variable m_wake;
    bool m_quit = false;
    std::unique_ptr<Decoder> m_decoder, m_nextDecoder;
    QString m_nextPath, m_nextID;
    bool m_decodeEOF = false;

    // Positions, in output frames since the last start or seek.
    std::atomic<quint64> m_written{0}, m_played{0};
    std::atomic<bool> m_paused{true};
    std::atomic<float> m_volume{0.7f};
    std::deque<Segment> m_segments;           // under m_decodeLock
    std::mutex m_segmentLock;

    QString m_currentID, m_currentPath;
    // The next track as the player asked for it (kept across seeks until it starts).
    QString m_pendingNextPath, m_pendingNextID;
    double m_duration = 0;
    bool m_playing = false;
    bool m_endedSent = false;
    QTimer m_poll, m_idle;
    bool m_deviceRunning = false;
};

/// One file, decoded to interleaved stereo float at the output rate.
class Decoder {
public:
    static std::unique_ptr<Decoder> open(const QString &path, int outRate, QString *error);
    ~Decoder();
    /// Up to `frames` frames into `out`; 0 at the end of the file.
    int read(float *out, int frames);
    bool seek(double seconds);
    double duration() const { return m_duration; }

private:
    Decoder() = default;
    bool decodeMore();
    struct AVFormatContext *m_fmt = nullptr;
    struct AVCodecContext *m_codec = nullptr;
    struct SwrContext *m_swr = nullptr;
    struct AVPacket *m_packet = nullptr;
    struct AVFrame *m_frame = nullptr;
    int m_stream = -1, m_outRate = 48000;
    double m_duration = 0;
    std::vector<float> m_pending;
    size_t m_pendingPos = 0;
    bool m_eof = false, m_flushed = false;
    qint64 m_skipFrames = 0;                  // after a seek, to land on the exact sample
    double m_seekTarget = -1;
    qint64 m_synthLeft = 0;                   // generated test tracks
};
