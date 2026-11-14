#include "Player.h"
#include "AudioEngine.h"
#include "CoreBridge.h"
#include "Library.h"
#include "i2s_core.h"
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <algorithm>
#include <cmath>
#include <numeric>
#include <random>

namespace {
Library *lib() { return Library::instance(); }
double now() { return double(QDateTime::currentMSecsSinceEpoch()) / 1000.0; }
QString defaultsFile(const QString &key) { return Core::supportDir() + "/defaults/" + key + ".json"; }
QJsonValue readDefault(const QString &key) {
    QFile f(defaultsFile(key));
    if (!f.open(QIODevice::ReadOnly)) return {};
    // Each file holds one JSON value (a bare value or an object).
    const QByteArray bytes = f.readAll();
    const QJsonDocument doc = QJsonDocument::fromJson("[" + bytes + "]");
    return doc.isArray() && !doc.array().isEmpty() ? doc.array().first() : QJsonValue();
}
}

Player *Player::instance() {
    static Player *s = new Player;
    return s;
}

Player::Player(QObject *parent) : QObject(parent) {
    m_uptime.start();
    m_clock.setInterval(50);
    connect(&m_clock, &QTimer::timeout, this, &Player::tick);
    m_saveSoon.setSingleShot(true);
    m_saveSoon.setInterval(1000);
    connect(&m_saveSoon, &QTimer::timeout, this, &Player::saveSession);
    for (auto signal : {&Player::queueChanged, &Player::trackChanged, &Player::playingChanged})
        connect(this, signal, &m_saveSoon, qOverload<>(&QTimer::start));
    connect(lib(), &Library::tracksChanged, this, &Player::libraryChanged);
}

void Player::attach(AudioEngine *engine) {
    m_engine = engine;
    connect(m_engine, &AudioEngine::advanced, this, &Player::engineAdvanced);
    connect(m_engine, &AudioEngine::ended, this, &Player::reachedEnd);
    connect(m_engine, &AudioEngine::playingChanged, this, [this] { audibleChanged(); emit playingChanged(); });
    connect(m_engine, &AudioEngine::volumeChanged, this, [this] { audibleChanged(); emit volumeChanged(); });
    m_clock.start();
}

QString Player::currentID() const { return m_pos >= 0 && m_pos < int(m_order.size()) ? m_queue[size_t(m_order[size_t(m_pos)])] : QString(); }
int Player::indexAt(int orderIndex) const { return lib()->indexOf(m_queue[size_t(m_order[size_t(orderIndex)])]); }
int Player::trackIndex() const { return m_pos >= 0 ? lib()->indexOf(currentID()) : -1; }
QVariantMap Player::track() const { return lib()->track(trackIndex()); }
QString Player::clock(double s) const { return Track::clock(s); }

double Player::duration() const {
    if (m_engine && m_engine->duration() > 0 && m_pos >= 0) return m_engine->duration();
    const Track *t = lib()->at(trackIndex());
    return t ? t->duration : 0;
}
bool Player::playing() const { return m_engine && m_engine->isPlaying(); }
double Player::volume() const { return m_engine ? m_engine->volume() : 0.7; }

/// The library changed: tracks may have new indexes or be gone.
void Player::libraryChanged() {
    const QString current = currentID();
    std::vector<int> remap(m_queue.size(), -1);
    std::vector<QString> kept;
    for (size_t i = 0; i < m_queue.size(); ++i) if (lib()->indexOf(m_queue[i]) >= 0) { remap[i] = int(kept.size()); kept.push_back(m_queue[i]); }
    if (kept.size() != m_queue.size()) {
        std::vector<int> order;
        for (int q : m_order) if (remap[size_t(q)] >= 0) order.push_back(remap[size_t(q)]);
        m_queue = kept;
        m_order = order;
        m_pos = -1;
        for (int i = 0; i < int(m_order.size()); ++i) if (m_queue[size_t(m_order[size_t(i)])] == current) m_pos = i;
        if (m_pos < 0 && !current.isEmpty()) { m_engine->stop(); m_lyrics.clear(); emit lyricsChanged(); }
        prepareNext();
        emit queueChanged();
    }
    emit trackChanged();
}

QVariantList Player::upNext() const {
    QVariantList out;
    if (m_pos < 0) return out;
    for (int i = m_pos + 1; i < int(m_order.size()); ++i) if (const int x = indexAt(i); x >= 0) out << x;
    return out;
}

void Player::play(const QVariantList &tracks, int start) {
    if (!m_engine || start < 0 || start >= tracks.size()) return;
    m_queue.clear();
    for (const QVariant &v : tracks) if (const Track *t = lib()->at(v.toInt())) m_queue.push_back(t->id);
    if (m_queue.empty()) return;
    m_order.resize(m_queue.size());
    std::iota(m_order.begin(), m_order.end(), 0);
    if (m_shuffle) {
        std::vector<int> rest;
        for (int i = 0; i < int(m_queue.size()); ++i) if (i != start) rest.push_back(i);
        std::shuffle(rest.begin(), rest.end(), std::mt19937(std::random_device{}()));
        m_order.assign(1, start);
        m_order.insert(m_order.end(), rest.begin(), rest.end());
        m_pos = 0;
    } else {
        m_pos = start;
    }
    startCurrent();
}

void Player::playFromTable(int trackIndex) {
    const auto &order = lib()->visible();
    QVariantList list;
    int start = -1;
    for (size_t i = 0; i < order.size(); ++i) { if (order[i] == trackIndex) start = int(i); list << order[i]; }
    if (start < 0) play(QVariantList{trackIndex}, 0); else play(list, start);
}

void Player::shuffleTable() {
    const QVariantList list = lib()->visibleTracks();
    if (list.isEmpty()) return;
    setShuffle(true);
    static std::mt19937 rng(std::random_device{}());
    play(list, std::uniform_int_distribution<int>(0, int(list.size()) - 1)(rng));
}

void Player::insert(const QVariantList &tracks, bool afterCurrent) {
    if (tracks.isEmpty()) return;
    if (m_pos < 0) { play(tracks, 0); return; }
    const int first = int(m_queue.size());
    for (const QVariant &v : tracks) if (const Track *t = lib()->at(v.toInt())) m_queue.push_back(t->id);
    std::vector<int> added(m_queue.size() - size_t(first));
    std::iota(added.begin(), added.end(), first);
    if (afterCurrent) m_order.insert(m_order.begin() + m_pos + 1, added.begin(), added.end());
    else m_order.insert(m_order.end(), added.begin(), added.end());
    prepareNext();
    emit queueChanged();
}

void Player::playNext(const QVariantList &tracks) { insert(tracks, true); }
void Player::addToQueue(const QVariantList &tracks) { insert(tracks, false); }

void Player::jumpToUpNext(int offset) {
    const int target = m_pos + 1 + offset;
    if (target < 0 || target >= int(m_order.size())) return;
    m_pos = target;
    startCurrent();
}

void Player::removeFromUpNext(int offset) {
    const int target = m_pos + 1 + offset;
    if (target <= m_pos || target >= int(m_order.size())) return;
    m_order.erase(m_order.begin() + target);
    prepareNext();
    emit queueChanged();
}

void Player::clearUpNext() {
    if (m_pos < 0) return;
    m_order.resize(size_t(m_pos) + 1);
    prepareNext();
    emit queueChanged();
}

void Player::rebuildOrder() {
    if (m_queue.empty()) return;
    const int current = m_pos >= 0 ? m_order[size_t(m_pos)] : -1;
    if (m_shuffle) {
        std::vector<int> rest;
        for (int i = 0; i < int(m_queue.size()); ++i) if (i != current) rest.push_back(i);
        std::shuffle(rest.begin(), rest.end(), std::mt19937(std::random_device{}()));
        m_order.clear();
        if (current >= 0) m_order.push_back(current);
        m_order.insert(m_order.end(), rest.begin(), rest.end());
        m_pos = current >= 0 ? 0 : -1;
    } else {
        m_order.resize(m_queue.size());
        std::iota(m_order.begin(), m_order.end(), 0);
        m_pos = current;
    }
    prepareNext();
    emit queueChanged();
}

void Player::writeDefault(const QString &key, const QJsonValue &value) {
    QDir().mkpath(Core::supportDir() + "/defaults");
    QSaveFile f(defaultsFile(key));
    if (!f.open(QIODevice::WriteOnly)) return;
    if (value.isObject()) f.write(QJsonDocument(value.toObject()).toJson(QJsonDocument::Compact));
    else f.write(QJsonDocument(QJsonArray{value}).toJson(QJsonDocument::Compact).mid(1).chopped(1));
    f.commit();
}

void Player::setShuffle(bool s) {
    if (s == m_shuffle) return;
    m_shuffle = s;
    rebuildOrder();
    writeDefault("com.meimei.player.shuffle", s);
    emit shuffleChanged();
}

void Player::setRepeatMode(const QString &m) {
    if (m == m_repeat || (m != "off" && m != "all" && m != "one")) return;
    m_repeat = m;
    prepareNext();
    writeDefault("com.meimei.player.repeatMode", m);
    emit repeatModeChanged();
}

void Player::setStopAfterCurrent(bool s) {
    if (s == m_stopAfter) return;
    m_stopAfter = s;
    prepareNext();
    emit stopAfterCurrentChanged();
}

void Player::cycleRepeat() { setRepeatMode(m_repeat == "off" ? "all" : m_repeat == "all" ? "one" : "off"); }

void Player::setVolume(double v) {
    if (!m_engine) return;
    v = std::clamp(v, 0.0, 1.0);
    if (std::abs(v - m_engine->volume()) < 1e-6) return;
    m_engine->setVolume(float(v));
    writeDefault("com.meimei.player.volume", v);
}

void Player::toggleMute() {
    if (volume() > 0.001) { m_beforeMute = volume(); setVolume(0); }
    else setVolume(std::max(0.1, m_beforeMute));
}

void Player::toggleLiked() {
    const int i = trackIndex();
    if (const Track *t = lib()->at(i)) { lib()->setLiked({i}, !t->liked); emit trackChanged(); }
}

/// Starts the current track, skipping past files that can't be opened.
void Player::startCurrent(bool paused, double at) {
    int attempts = 0;
    while (m_pos >= 0 && attempts < int(m_order.size())) {
        const Track *t = lib()->at(indexAt(m_pos));
        if (t && m_engine->start(t->filePath, t->id, at, paused)) {
            prepareNext();
            m_position = at;
            loadLyrics();
            beginListen();
            emit trackChanged();
            emit queueChanged();
            emit positionChanged();
            emit playingChanged();
            return;
        }
        ++attempts;
        if (!(m_pos + 1 < int(m_order.size()) || m_repeat == "all")) break;
        m_pos = (m_pos + 1) % int(m_order.size());
    }
    m_engine->stop();
    m_pos = -1;
    m_lyrics.clear();
    beginListen();
    emit lyricsChanged();
    emit trackChanged();
    emit playingChanged();
}

void Player::togglePlayPause() {
    if (!m_engine) return;
    if (m_engine->isPlaying()) m_engine->pause();
    else if (m_pos >= 0) {
        if (m_engine->currentID() == currentID()) m_engine->play();
        else startCurrent(false, m_position);
    } else {
        // Nothing queued yet: play what the table shows.
        const QVariantList list = lib()->visibleTracks();
        if (!list.isEmpty()) play(list, 0);
    }
}

void Player::stop() {
    if (!m_engine || m_pos < 0) return;
    m_engine->pause();
    seek(0);
}

void Player::next() {
    if (m_pos < 0 || m_order.empty()) return;
    if (m_pos + 1 < int(m_order.size())) m_pos += 1;
    else if (m_repeat != "off") m_pos = 0;
    else { m_engine->stop(); m_pos = -1; beginListen(); emit trackChanged(); emit playingChanged(); return; }
    startCurrent();
}

void Player::previous() {
    if (m_pos < 0 || m_order.empty()) return;
    if (m_engine->currentTime() > 3 || (m_pos == 0 && m_repeat == "off")) { seek(0); return; }
    m_pos = m_pos > 0 ? m_pos - 1 : int(m_order.size()) - 1;
    startCurrent();
}

void Player::seek(double seconds) {
    if (!m_engine) return;
    m_engine->seek(seconds);
    m_position = std::clamp(seconds, 0.0, duration());
    emit positionChanged();
    updateLine();
}

int Player::nextOrderIndex() const {
    if (m_pos < 0 || m_order.empty()) return -1;
    if (m_repeat == "one") return m_pos;
    if (m_pos + 1 < int(m_order.size())) return m_pos + 1;
    return m_repeat == "all" ? 0 : -1;
}

void Player::prepareNext() {
    if (!m_engine) return;
    const int index = nextOrderIndex();
    const Track *t = index >= 0 && !m_stopAfter ? lib()->at(indexAt(index)) : nullptr;
    if (t) m_engine->setNext(t->filePath, t->id); else m_engine->setNext({}, {});
}

/// The engine moved on to the prepared track by itself (gapless).
void Player::engineAdvanced(const QString &id) {
    finishListen();
    const int index = nextOrderIndex();
    if (index >= 0 && m_queue[size_t(m_order[size_t(index)])] == id) m_pos = index;
    else for (int i = 0; i < int(m_order.size()); ++i) if (m_queue[size_t(m_order[size_t(i)])] == id) { m_pos = i; break; }
    prepareNext();
    loadLyrics();
    beginListen();
    emit trackChanged();
    emit queueChanged();
}

/// The last track ended with nothing after it.
void Player::reachedEnd() {
    finishListen();
    if (m_stopAfter) {
        // Stop after this track: the next one waits, paused.
        m_stopAfter = false;
        emit stopAfterCurrentChanged();
        if (m_pos + 1 < int(m_order.size())) { m_pos += 1; startCurrent(true); return; }
    }
    m_engine->stop();
    m_pos = -1;
    m_position = 0;
    m_lyrics.clear();
    beginListen();
    emit lyricsChanged();
    emit trackChanged();
    emit playingChanged();
    emit positionChanged();
}

void Player::loadLyrics() {
    m_lyrics.clear();
    m_times.clear();
    m_line = -1;
    m_synced = false;
    if (const Track *t = lib()->at(trackIndex()); t && !t->filePath.startsWith("gen:")) {
        const QString raw = LibraryFiles::rawLyrics(t->filePath);
        if (!raw.trimmed().isEmpty()) {
            char *json = i2s_lyrics_read_json(raw.toUtf8().constData());
            const QJsonObject o = QJsonDocument::fromJson(QByteArray(json ? json : "{}")).object();
            i2s_free(json);
            m_synced = o["synced"].toBool();
            for (const QJsonValue &v : o["lines"].toArray()) {
                const QJsonObject l = v.toObject();
                m_lyrics << QVariantMap{{"text", l["text"].toString()}, {"time", l["time"].toDouble(-1)}};
                m_times.push_back(l["time"].toDouble(-1));
            }
        }
    }
    emit lyricsChanged();
    emit lyricLineChanged();
}

void Player::tick() {
    if (!m_engine || m_pos < 0) return;
    const double t = m_engine->currentTime();
    if (std::abs(t - m_position) > 0.0005) {
        m_position = t;
        emit positionChanged();
        updateLine();
    }
}

void Player::updateLine() {
    if (!m_synced || m_times.empty()) return;
    const int line = i2s_lyrics_line_at(m_times.data(), int(m_times.size()), m_position);
    if (line != m_line) { m_line = line; emit lyricLineChanged(); }
}

// MARK: - Listen tracking

void Player::beginListen() {
    if (currentID() == m_listenID && !m_listenID.isEmpty()) return;
    m_listenID = currentID();
    m_listenStarted = 0;
    m_heard = 0;
    m_audibleSince = -1;
    audibleChanged();
}

void Player::audibleChanged() {
    const bool audible = !m_listenID.isEmpty() && m_engine && m_engine->isPlaying() && m_engine->volume() > 0;
    if (audible && m_audibleSince < 0) {
        m_audibleSince = m_uptime.elapsed();
        if (m_listenStarted == 0) m_listenStarted = now();
    } else if (!audible && m_audibleSince >= 0) {
        m_heard += double(m_uptime.elapsed() - m_audibleSince) / 1000.0;
        m_audibleSince = -1;
    }
}

/// Ends the current listen; seals it if it was heard long enough.
void Player::finishListen() {
    if (m_audibleSince >= 0) m_heard += double(m_uptime.elapsed() - m_audibleSince) / 1000.0;
    const QString id = m_listenID;
    const double started = m_listenStarted, heard = m_heard;
    m_listenID.clear();
    m_listenStarted = 0;
    m_heard = 0;
    m_audibleSince = -1;
    if (id.isEmpty() || started == 0 || !lib()->history()) return;
    char *err = nullptr;
    const int r = i2s_history_record_track(lib()->history(), lib()->handle(), id.toUtf8().constData(), started, now(), heard, &err);
    if (r == 0) lib()->recordPlay(id, now());
    else if (r == 1) { qWarning("i2s: listen not recorded: %s", err ? err : "?"); i2s_free(err); }
}

// MARK: - Session

void Player::saveSession() {
    if (m_pos < 0 || m_queue.empty()) { QFile::remove(defaultsFile("com.meimei.player.session.v1")); return; }
    QJsonArray ids, order;
    for (const QString &id : m_queue) ids << id;
    for (int i : m_order) order << i;
    writeDefault("com.meimei.player.session.v1", QJsonObject{{"trackIDs", ids}, {"order", order}, {"position", m_pos},
                                                             {"time", m_engine ? m_engine->currentTime() : m_position}});
}

void Player::restoreSession() {
    m_shuffle = readDefault("com.meimei.player.shuffle").toBool();
    const QString repeat = readDefault("com.meimei.player.repeatMode").toString("off");
    m_repeat = repeat == "all" || repeat == "one" ? repeat : "off";
    const QJsonValue vol = readDefault("com.meimei.player.volume");
    if (vol.isDouble() && m_engine) m_engine->setVolume(float(vol.toDouble()));
    const QJsonObject s = readDefault("com.meimei.player.session.v1").toObject();
    if (s.isEmpty()) return;
    std::vector<int> remap;
    std::vector<QString> queue;
    for (const QJsonValue &v : s["trackIDs"].toArray()) {
        if (lib()->indexOf(v.toString().toUpper()) >= 0) { remap.push_back(int(queue.size())); queue.push_back(v.toString().toUpper()); }
        else remap.push_back(-1);
    }
    std::vector<int> order;
    const QJsonArray saved = s["order"].toArray();
    const int position = s["position"].toInt(-1);
    int pos = -1;
    for (int i = 0; i < saved.size(); ++i) {
        const int q = saved[i].toInt(-1);
        if (q < 0 || q >= int(remap.size()) || remap[size_t(q)] < 0) continue;
        if (i == position) pos = int(order.size());
        order.push_back(remap[size_t(q)]);
    }
    if (pos < 0) return;
    m_queue = queue;
    m_order = order;
    m_pos = pos;
    startCurrent(true, s["time"].toDouble());
    emit shuffleChanged();
    emit repeatModeChanged();
}
