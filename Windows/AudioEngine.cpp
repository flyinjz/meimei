#include "AudioEngine.h"
#include <QMetaObject>
#include <algorithm>
#include <cmath>
#include <cstring>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MINIAUDIO_IMPLEMENTATION
#include <miniaudio/miniaudio.h>

// MARK: - Decoder

std::unique_ptr<Decoder> Decoder::open(const QString &path, int outRate, QString *error) {
    std::unique_ptr<Decoder> d(new Decoder);
    d->m_outRate = outRate;
    if (path.startsWith("gen:")) {
        // The generated test library: silence of the track's length.
        d->m_duration = path.section(':', 2, 2).toDouble();
        d->m_synthLeft = qint64(d->m_duration * outRate);
        return d;
    }
    auto fail = [&](const char *why) { if (error) *error = QString::fromUtf8(why); return nullptr; };
    if (avformat_open_input(&d->m_fmt, path.toUtf8().constData(), nullptr, nullptr) < 0) return fail("can't open the file");
    if (avformat_find_stream_info(d->m_fmt, nullptr) < 0) return fail("can't read the file's streams");
    const AVCodec *codec = nullptr;
    d->m_stream = av_find_best_stream(d->m_fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (d->m_stream < 0 || !codec) return fail("no audio in the file");
    AVStream *st = d->m_fmt->streams[d->m_stream];
    d->m_codec = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(d->m_codec, st->codecpar);
    d->m_codec->pkt_timebase = st->time_base;
    if (avcodec_open2(d->m_codec, codec, nullptr) < 0) return fail("can't decode this format");
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    AVChannelLayout in = d->m_codec->ch_layout;
    if (in.nb_channels == 0) av_channel_layout_default(&in, 2);
    if (swr_alloc_set_opts2(&d->m_swr, &stereo, AV_SAMPLE_FMT_FLT, outRate, &in, d->m_codec->sample_fmt,
                            d->m_codec->sample_rate, 0, nullptr) < 0 || swr_init(d->m_swr) < 0)
        return fail("can't convert the audio");
    d->m_packet = av_packet_alloc();
    d->m_frame = av_frame_alloc();
    if (st->duration != AV_NOPTS_VALUE && st->duration > 0) d->m_duration = st->duration * av_q2d(st->time_base);
    else if (d->m_fmt->duration > 0) d->m_duration = d->m_fmt->duration / double(AV_TIME_BASE);
    return d;
}

Decoder::~Decoder() {
    av_frame_free(&m_frame);
    av_packet_free(&m_packet);
    swr_free(&m_swr);
    avcodec_free_context(&m_codec);
    if (m_fmt) avformat_close_input(&m_fmt);
}

bool Decoder::decodeMore() {
    // One decoded frame (or the converter's tail at the end) into m_pending.
    auto convert = [&](const uint8_t **data, int samples) {
        const int room = swr_get_out_samples(m_swr, samples);
        if (room <= 0) return 0;
        const size_t base = m_pending.size();
        m_pending.resize(base + size_t(room) * 2);
        uint8_t *out = reinterpret_cast<uint8_t *>(m_pending.data() + base);
        const int got = swr_convert(m_swr, &out, room, data, samples);
        m_pending.resize(base + size_t(std::max(0, got)) * 2);
        return got;
    };
    while (true) {
        const int r = avcodec_receive_frame(m_codec, m_frame);
        if (r == 0) {
            if (m_seekTarget >= 0) {
                // First frame after a seek: drop up to the exact sample asked for.
                AVStream *st = m_fmt->streams[m_stream];
                const int64_t ts = m_frame->best_effort_timestamp;
                const double t = ts == AV_NOPTS_VALUE ? m_seekTarget
                    : (ts - (st->start_time != AV_NOPTS_VALUE ? st->start_time : 0)) * av_q2d(st->time_base);
                m_skipFrames = qint64(std::llround(std::max(0.0, m_seekTarget - t) * m_outRate));
                m_seekTarget = -1;
            }
            convert(const_cast<const uint8_t **>(m_frame->extended_data), m_frame->nb_samples);
            av_frame_unref(m_frame);
            return true;
        }
        if (r == AVERROR_EOF) {
            if (!m_flushed) { m_flushed = true; return convert(nullptr, 0) > 0; }
            return false;
        }
        if (m_eof) { avcodec_send_packet(m_codec, nullptr); continue; }
        const int rr = av_read_frame(m_fmt, m_packet);
        if (rr < 0) { m_eof = true; avcodec_send_packet(m_codec, nullptr); continue; }
        if (m_packet->stream_index == m_stream) avcodec_send_packet(m_codec, m_packet);
        av_packet_unref(m_packet);
    }
}

int Decoder::read(float *out, int frames) {
    if (!m_fmt) {
        const int n = int(std::min<qint64>(frames, m_synthLeft));
        std::memset(out, 0, size_t(n) * 2 * sizeof(float));
        m_synthLeft -= n;
        return n;
    }
    int done = 0;
    while (done < frames) {
        size_t avail = (m_pending.size() - m_pendingPos) / 2;
        if (avail == 0) {
            m_pending.clear();
            m_pendingPos = 0;
            if (!decodeMore()) break;
            continue;
        }
        if (m_skipFrames > 0) {
            const size_t skip = std::min<size_t>(avail, size_t(m_skipFrames));
            m_pendingPos += skip * 2;
            m_skipFrames -= qint64(skip);
            continue;
        }
        const size_t n = std::min<size_t>(avail, size_t(frames - done));
        std::memcpy(out + done * 2, m_pending.data() + m_pendingPos, n * 2 * sizeof(float));
        m_pendingPos += n * 2;
        done += int(n);
    }
    return done;
}

bool Decoder::seek(double seconds) {
    if (!m_fmt) { m_synthLeft = qint64(std::max(0.0, m_duration - seconds) * m_outRate); return true; }
    AVStream *st = m_fmt->streams[m_stream];
    const int64_t ts = int64_t(seconds / av_q2d(st->time_base)) + (st->start_time != AV_NOPTS_VALUE ? st->start_time : 0);
    if (av_seek_frame(m_fmt, m_stream, ts, AVSEEK_FLAG_BACKWARD) < 0) return false;
    avcodec_flush_buffers(m_codec);
    swr_init(m_swr);
    m_pending.clear();
    m_pendingPos = 0;
    m_eof = m_flushed = false;
    m_skipFrames = 0;
    m_seekTarget = seconds;
    return true;
}

// MARK: - Engine

AudioEngine::AudioEngine(QObject *parent) : QObject(parent), m_device(new ma_device) {
    if (!s_instance) s_instance = this;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate = 0;                       // the device's own rate: no extra resampling
    cfg.dataCallback = &AudioEngine::callback;
    cfg.pUserData = this;
    cfg.performanceProfile = ma_performance_profile_conservative;
    m_deviceOK = ma_device_init(nullptr, &cfg, m_device.get()) == MA_SUCCESS;
    m_rate = m_deviceOK ? int(m_device->sampleRate) : 48000;
    m_capacity = size_t(m_rate);              // one second ahead
    m_ring.assign(m_capacity * 2, 0.f);
    m_thread = std::thread([this] { decodeLoop(); });
    // The playhead publishes ~20x a second, only while something plays.
    m_poll.setInterval(50);
    connect(&m_poll, &QTimer::timeout, this, &AudioEngine::poll);
    // The device stops a moment after playback does, so an idle app costs
    // nothing (no audio thread, no "playing" session in Windows' mixer), and
    // a quick pause/resume never re-opens it.
    m_idle.setSingleShot(true);
    m_idle.setInterval(1500);
    connect(&m_idle, &QTimer::timeout, this, [this] { if (!m_playing) setDeviceRunning(false); });
}

void AudioEngine::setDeviceRunning(bool on) {
    if (!m_deviceOK || on == m_deviceRunning) return;
    m_deviceRunning = on;
    if (on) ma_device_start(m_device.get()); else ma_device_stop(m_device.get());
}

void AudioEngine::setPlayingState(bool playing) {
    m_paused = !playing;
    m_playing = playing;
    if (playing) {
        m_idle.stop();
        setDeviceRunning(true);
        if (!m_poll.isActive()) m_poll.start();
    } else {
        m_poll.stop();
        m_idle.start();
    }
    m_wake.notify_all();
    emit playingChanged();
}

AudioEngine::~AudioEngine() {
    {
        std::lock_guard l(m_decodeLock);
        m_quit = true;
    }
    m_wake.notify_all();
    if (m_thread.joinable()) m_thread.join();
    if (m_deviceOK) ma_device_uninit(m_device.get());
}

void AudioEngine::callback(ma_device *device, void *out, const void *, unsigned frames) {
    static_cast<AudioEngine *>(device->pUserData)->render(static_cast<float *>(out), frames);
}

void AudioEngine::render(float *out, unsigned frames) {
    size_t n = 0;
    if (!m_paused.load() && m_bufferLock.try_lock()) {
        n = std::min<size_t>(frames, m_fill);
        for (size_t i = 0; i < n; ++i) {
            out[i * 2] = m_ring[m_read * 2];
            out[i * 2 + 1] = m_ring[m_read * 2 + 1];
            m_read = (m_read + 1) % m_capacity;
        }
        m_fill -= n;
        m_bufferLock.unlock();
        m_played += n;
    }
    std::memset(out + n * 2, 0, (frames - n) * 2 * sizeof(float));
    if (n > 0 && process) process(out, int(n), m_rate);
    const float v = m_volume.load();
    // Perceptual volume: the slider's square, like AVAudioEngine's mixer curve feels.
    const float g = v * v;
    for (size_t i = 0; i < n * 2; ++i) out[i] *= g;
}

void AudioEngine::decodeLoop() {
    std::vector<float> chunk(4096 * 2);
    std::unique_lock lock(m_decodeLock);
    while (!m_quit) {
        size_t room;
        { std::lock_guard b(m_bufferLock); room = m_capacity - m_fill; }
        if (!m_decoder || (m_decodeEOF && m_nextPath.isEmpty())) {
            m_wake.wait(lock);                    // nothing to decode: sleep until told
            continue;
        }
        if (room < 1024) {
            // Full: top up as the device drains it; while paused, sleep until play.
            if (m_paused.load()) m_wake.wait(lock); else m_wake.wait_for(lock, std::chrono::milliseconds(15));
            continue;
        }
        const int want = int(std::min<size_t>(room, 4096));
        const int n = m_decoder->read(chunk.data(), want);
        if (n > 0) {
            std::lock_guard b(m_bufferLock);
            for (int i = 0; i < n; ++i) {
                m_ring[m_write * 2] = chunk[size_t(i) * 2];
                m_ring[m_write * 2 + 1] = chunk[size_t(i) * 2 + 1];
                m_write = (m_write + 1) % m_capacity;
            }
            m_fill += size_t(n);
            m_written += quint64(n);
            continue;
        }
        // End of this file: carry straight on into the next one, if any.
        if (!m_nextPath.isEmpty()) {
            QString error;
            auto next = Decoder::open(m_nextPath, m_rate, &error);
            const QString path = m_nextPath, id = m_nextID;
            m_nextPath.clear();
            m_nextID.clear();
            if (next) {
                std::lock_guard s(m_segmentLock);
                m_segments.push_back({m_written.load(), id, 0, next->duration()});
                m_decoder = std::move(next);
                m_decodeEOF = false;
                continue;
            }
            QMetaObject::invokeMethod(this, [this, path, error] { emit failed(path, error); }, Qt::QueuedConnection);
        }
        m_decodeEOF = true;
    }
}

bool AudioEngine::start(const QString &path, const QString &id, double startAt, bool paused) {
    QString error;
    auto decoder = Decoder::open(path, m_rate, &error);
    if (!decoder) { emit failed(path, error); return false; }
    if (startAt > 0) decoder->seek(startAt);
    {
        std::lock_guard l(m_decodeLock);
        {
            std::lock_guard b(m_bufferLock);
            m_read = m_write = m_fill = 0;
            m_written = 0;
            m_played = 0;
        }
        {
            std::lock_guard s(m_segmentLock);
            m_segments.clear();
            m_segments.push_back({0, id, startAt, decoder->duration()});
        }
        m_decoder = std::move(decoder);
        m_nextPath.clear();
        m_nextID.clear();
        m_decodeEOF = false;
        m_endedSent = false;
        m_currentPath = path;
    }
    m_currentID = id;
    m_duration = m_segments.front().duration;
    setPlayingState(!paused);
    emit positionChanged();
    return true;
}

void AudioEngine::setNext(const QString &path, const QString &id) {
    m_pendingNextPath = path;
    m_pendingNextID = id;
    {
        std::lock_guard l(m_decodeLock);
        m_nextPath = path;
        m_nextID = id;
    }
    m_wake.notify_all();
}

void AudioEngine::play() {
    if (m_currentID.isEmpty()) return;
    setPlayingState(true);
}

void AudioEngine::pause() {
    setPlayingState(false);
}

void AudioEngine::stop() {
    setPlayingState(false);
    std::lock_guard l(m_decodeLock);
    m_decoder.reset();
    m_nextPath.clear();
    std::lock_guard b(m_bufferLock);
    m_read = m_write = m_fill = 0;
    std::lock_guard s(m_segmentLock);
    m_segments.clear();
    m_currentID.clear();
    m_duration = 0;
}

void AudioEngine::seek(double seconds) {
    if (m_currentID.isEmpty()) return;
    seconds = std::clamp(seconds, 0.0, std::max(0.0, m_duration - 0.05));
    // Restart the current file there: the decoder may already be in the next one.
    const QString path = m_currentPath, id = m_currentID, nextPath = m_pendingNextPath, nextID = m_pendingNextID;
    start(path, id, seconds, m_paused.load());
    if (!nextPath.isEmpty()) setNext(nextPath, nextID);
}

double AudioEngine::currentTime() const {
    const quint64 played = m_played.load();
    std::lock_guard s(const_cast<std::mutex &>(m_segmentLock));
    for (auto it = m_segments.rbegin(); it != m_segments.rend(); ++it)
        if (it->startFrame <= played) return it->startSeconds + double(played - it->startFrame) / m_rate;
    return 0;
}

void AudioEngine::poll() {
    emit positionChanged();
    const quint64 played = m_played.load();
    QString advancedTo;
    {
        std::lock_guard s(m_segmentLock);
        while (m_segments.size() > 1 && m_segments[1].startFrame <= played) {
            m_segments.pop_front();
            advancedTo = m_segments.front().id;
            m_duration = m_segments.front().duration;
        }
    }
    if (!advancedTo.isEmpty() && advancedTo != m_currentID) {
        m_currentID = advancedTo;
        m_currentPath = m_pendingNextPath;
        m_pendingNextPath.clear();
        m_pendingNextID.clear();
        emit advanced(advancedTo);
    }
    bool eof;
    { std::lock_guard l(m_decodeLock); eof = m_decodeEOF && m_nextPath.isEmpty(); }
    if (m_playing && eof && played >= m_written.load() && !m_endedSent) {
        m_endedSent = true;
        setPlayingState(false);
        emit ended();
    }
}
