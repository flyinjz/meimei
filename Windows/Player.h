#pragma once
// The play queue and transport (the Mac's PlayerController): play a list
// from a track, shuffle order, repeat off/all/one, previous restarts after
// 3 s, play next / add to queue, stop after current, the session saved
// between launches; the engine plays gaplessly. The listen tracker times
// audible playback on a monotonic clock and seals listens into the history
// through the core. Lyrics come from the core's parser.
#include <QElapsedTimer>
#include <QObject>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QJSEngine>
#include <qqmlintegration.h>
#include <vector>

class AudioEngine;

class Player : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int trackIndex READ trackIndex NOTIFY trackChanged)
    Q_PROPERTY(bool hasTrack READ hasTrack NOTIFY trackChanged)
    Q_PROPERTY(QVariantMap track READ track NOTIFY trackChanged)
    Q_PROPERTY(double duration READ duration NOTIFY trackChanged)
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
    Q_PROPERTY(bool shuffle READ shuffle WRITE setShuffle NOTIFY shuffleChanged)
    Q_PROPERTY(QString repeatMode READ repeatMode WRITE setRepeatMode NOTIFY repeatModeChanged)
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(QVariantList upNext READ upNext NOTIFY queueChanged)
    Q_PROPERTY(bool stopAfterCurrent READ stopAfterCurrent WRITE setStopAfterCurrent NOTIFY stopAfterCurrentChanged)
    Q_PROPERTY(QVariantList lyrics READ lyrics NOTIFY lyricsChanged)
    Q_PROPERTY(bool lyricsSynced READ lyricsSynced NOTIFY lyricsChanged)
    Q_PROPERTY(int lyricLine READ lyricLine NOTIFY lyricLineChanged)
public:
    static Player *instance();
    static Player *create(class QQmlEngine *, QJSEngine *) { auto *p = instance(); QJSEngine::setObjectOwnership(p, QJSEngine::CppOwnership); return p; }
    void attach(AudioEngine *engine);

    int trackIndex() const;
    bool hasTrack() const { return m_pos >= 0; }
    QVariantMap track() const;
    double duration() const;
    double position() const { return m_position; }
    bool playing() const;
    bool shuffle() const { return m_shuffle; }
    void setShuffle(bool s);
    QString repeatMode() const { return m_repeat; }
    void setRepeatMode(const QString &m);
    double volume() const;
    void setVolume(double v);
    QVariantList upNext() const;
    bool stopAfterCurrent() const { return m_stopAfter; }
    void setStopAfterCurrent(bool s);
    QVariantList lyrics() const { return m_lyrics; }
    bool lyricsSynced() const { return m_synced; }
    int lyricLine() const { return m_line; }

    /// Replaces the queue with `tracks` (track indexes) and plays from `start`.
    Q_INVOKABLE void play(const QVariantList &tracks, int start = 0);
    /// Plays the table as shown, starting at this track.
    Q_INVOKABLE void playFromTable(int trackIndex);
    Q_INVOKABLE void shuffleTable();
    Q_INVOKABLE void playNext(const QVariantList &tracks);
    Q_INVOKABLE void addToQueue(const QVariantList &tracks);
    Q_INVOKABLE void jumpToUpNext(int offset);
    Q_INVOKABLE void removeFromUpNext(int offset);
    Q_INVOKABLE void clearUpNext();
    Q_INVOKABLE void togglePlayPause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void next();
    Q_INVOKABLE void previous();
    Q_INVOKABLE void seek(double seconds);
    Q_INVOKABLE void cycleRepeat();
    Q_INVOKABLE void toggleMute();
    Q_INVOKABLE void toggleLiked();
    Q_INVOKABLE QString clock(double seconds) const;

    void restoreSession();
    void saveSession();
    /// Ends the current listen (on quit).
    void finishListen();

signals:
    void trackChanged();
    void positionChanged();
    void playingChanged();
    void volumeChanged();
    void shuffleChanged();
    void repeatModeChanged();
    void queueChanged();
    void stopAfterCurrentChanged();
    void lyricsChanged();
    void lyricLineChanged();

private:
    explicit Player(QObject *parent = nullptr);
    QString currentID() const;
    int indexAt(int orderIndex) const;
    void startCurrent(bool paused = false, double at = 0);
    void rebuildOrder();
    void insert(const QVariantList &tracks, bool afterCurrent);
    int nextOrderIndex() const;
    void prepareNext();
    void engineAdvanced(const QString &id);
    void reachedEnd();
    void loadLyrics();
    void tick();
    void updateLine();
    void libraryChanged();
    void writeDefault(const QString &key, const QJsonValue &value);

    // Listen tracking (the Mac's ListenTracker).
    void beginListen();
    void audibleChanged();

    AudioEngine *m_engine = nullptr;
    std::vector<QString> m_queue;   // track ids (indexes move when the library changes)
    std::vector<int> m_order;
    int m_pos = -1;
    double m_position = 0, m_beforeMute = 0.7;
    bool m_shuffle = false, m_stopAfter = false, m_wasPlaying = false, m_synced = false;
    QString m_repeat = "off";
    QTimer m_clock, m_saveSoon;
    QVariantList m_lyrics;
    std::vector<double> m_times;
    int m_line = -1;

    QString m_listenID;
    double m_listenStarted = 0, m_heard = 0;
    qint64 m_audibleSince = -1;
    QElapsedTimer m_uptime;
};
