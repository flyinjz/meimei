#pragma once
// The music library as the app shows it: tracks and playlists held by the
// shared core (library.json), the browse selection (source, filter, sort,
// grouping), the track table's rows, and folder scanning (TagLib) that feeds
// new files into the core. Every rule (views, filter, sort, grouping,
// playlists, the file) is the core's; this class only holds display copies.
#include <QAbstractListModel>
#include <QFileSystemWatcher>
#include <QHash>
#include <QJsonObject>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <atomic>
#include <thread>
#include <vector>
#include <qqmlintegration.h>
#include <QJSEngine>

struct i2s_library;
struct i2s_history;
class LibraryRows;

/// One track's display fields (parsed from the core's track JSON).
struct Track {
    QString id, filePath, title, artist, album, albumArtist, genre, fileFormat, artwork;
    int year = 0, trackNumber = 0, discNumber = 0, bitDepth = 16, channelCount = 2, bitrate = 0, playCount = 0;
    double duration = 0, sampleRate = 44100, dateAdded = 0, lastPlayed = 0;   // dates: seconds since 1970
    bool liked = false;

    bool lossless() const;
    bool hiRes() const { return sampleRate > 44100 || bitDepth > 16; }
    QString albumKey() const { return albumArtist.toLower() + "::" + album.toLower(); }
    static QString clock(double seconds);
    static QString rate(double hz);
};

class Library : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceTitle READ sourceTitle NOTIFY viewChanged)
    Q_PROPERTY(QString eyebrow READ eyebrow NOTIFY viewChanged)
    Q_PROPERTY(QString summary READ summary NOTIFY viewChanged)
    Q_PROPERTY(QString filterText READ filterText WRITE setFilterText NOTIFY filterTextChanged)
    Q_PROPERTY(QString sortKey READ sortKey NOTIFY viewChanged)
    Q_PROPERTY(bool sortAscending READ sortAscending NOTIFY viewChanged)
    Q_PROPERTY(int count READ count NOTIFY tracksChanged)
    Q_PROPERTY(int albumCount READ albumCount NOTIFY tracksChanged)
    Q_PROPERTY(int artistCount READ artistCount NOTIFY tracksChanged)
    Q_PROPERTY(int likedCount READ likedCount NOTIFY tracksChanged)
    Q_PROPERTY(int visibleCount READ visibleCount NOTIFY viewChanged)
    Q_PROPERTY(double visibleDuration READ visibleDuration NOTIFY viewChanged)
    Q_PROPERTY(double totalDuration READ totalDuration NOTIFY tracksChanged)
    Q_PROPERTY(QVariantList genres READ genres NOTIFY tracksChanged)
    Q_PROPERTY(QVariantList playlists READ playlists NOTIFY playlistsChanged)
    Q_PROPERTY(LibraryRows *rows READ rows CONSTANT)
    Q_PROPERTY(bool scanning READ scanning NOTIFY scanChanged)
    Q_PROPERTY(int scanDone READ scanDone NOTIFY scanChanged)
    Q_PROPERTY(int scanTotal READ scanTotal NOTIFY scanChanged)
    Q_PROPERTY(QString scanLabel READ scanLabel NOTIFY scanChanged)
    Q_PROPERTY(QStringList folders READ folders NOTIFY foldersChanged)
public:
    static Library *instance();
    static Library *create(class QQmlEngine *, QJSEngine *) { auto *p = instance(); QJSEngine::setObjectOwnership(p, QJSEngine::CppOwnership); return p; }
    ~Library() override;

    /// Opens library.json in the support folder (and the history, for play counts).
    void open();
    /// Writes pending changes now (on quit).
    void flush();
    i2s_history *history() const { return m_history; }
    i2s_library *handle() const { return m_lib; }

    QString source() const { return m_source; }
    void setSource(const QString &s);
    QString sourceTitle() const;
    QString eyebrow() const;
    QString summary() const;
    QString filterText() const { return m_filter; }
    void setFilterText(const QString &t);
    QString sortKey() const { return m_sortKey; }
    bool sortAscending() const { return m_ascending; }
    int count() const { return int(m_tracks.size()); }
    int albumCount() const { return m_albumCount; }
    int artistCount() const { return m_artistCount; }
    int likedCount() const { return m_likedCount; }
    int visibleCount() const { return int(m_visible.size()); }
    double visibleDuration() const { return m_visibleDuration; }
    double totalDuration() const { return m_totalDuration; }
    QVariantList genres() const { return m_genres; }
    QVariantList playlists() const { return m_playlistList; }
    LibraryRows *rows() const { return m_rows; }
    bool scanning() const { return m_scanning; }
    int scanDone() const { return m_scanDone; }
    int scanTotal() const { return m_scanTotal; }
    QString scanLabel() const { return m_scanLabel; }
    QStringList folders() const { return m_folders; }

    // Lookups (track indexes are positions in the core's track list).
    int indexOf(const QString &id) const { return m_index.value(id, -1); }
    const Track *at(int i) const { return i >= 0 && i < int(m_tracks.size()) ? &m_tracks[size_t(i)] : nullptr; }
    /// Track indexes in table order (what Play plays).
    const std::vector<int> &visible() const { return m_visible; }

    Q_INVOKABLE QVariantMap track(int index) const;
    Q_INVOKABLE QVariantList visibleTracks() const;
    /// Column header click: ascending first, then descending, then the library order.
    Q_INVOKABLE void toggleSort(const QString &key);
    Q_INVOKABLE void setLiked(const QVariantList &tracks, bool liked);
    Q_INVOKABLE void removeTracks(const QVariantList &tracks);
    Q_INVOKABLE QString createPlaylist(const QString &name, const QVariantList &tracks);
    Q_INVOKABLE void editPlaylist(const QString &op, const QString &id, const QVariantList &tracks, const QString &name = {}, int index = 0);
    Q_INVOKABLE void showInExplorer(int index) const;
    /// Folders or files (local paths or file URLs): remembered and scanned.
    Q_INVOKABLE void importItems(const QVariantList &items);
    Q_INVOKABLE void rescan();
    Q_INVOKABLE void removeFolder(const QString &folder);
    /// A listen was sealed: one more play for the track (display only; the history is the record).
    void recordPlay(const QString &id, double at);

signals:
    void sourceChanged();
    void filterTextChanged();
    void viewChanged();
    void tracksChanged();
    void playlistsChanged();
    void scanChanged();
    void foldersChanged();

private:
    explicit Library(QObject *parent = nullptr);
    void reloadTracks();
    void reloadPlaylists();
    void rebuildView();
    void saveSoon();
    void save();
    void scan(QStringList roots);
    void saveFolders();
    QString groupBy() const;

    i2s_library *m_lib = nullptr;
    i2s_history *m_history = nullptr;
    QString m_path;
    std::vector<Track> m_tracks;
    QHash<QString, int> m_index;
    QVariantList m_playlistData, m_playlistList, m_genres;
    std::vector<int> m_visible;
    QString m_source = "all", m_filter, m_sortKey;
    bool m_ascending = true;
    double m_visibleDuration = 0, m_totalDuration = 0;
    int m_albumCount = 0, m_artistCount = 0, m_likedCount = 0;
    LibraryRows *m_rows;
    QTimer m_saveTimer, m_viewTimer;

    // Scanning
    QStringList m_folders, m_queued;
    QFileSystemWatcher m_watcher;
    QTimer m_rescanSoon;
    std::thread m_thread;
    std::atomic<bool> m_cancel{false};
    bool m_scanning = false;
    int m_scanDone = 0, m_scanTotal = 0;
    QString m_scanLabel;
};

/// The table's rows: group headers and tracks (stripes restart per group).
class LibraryRows : public QAbstractListModel {
    Q_OBJECT
    QML_ANONYMOUS
public:
    enum Role { IsHeader = Qt::UserRole + 1, HeaderTitle, HeaderDetail, TrackIndex, Stripe, Title, Artist, Album, AlbumArtist,
                TrackNo, Year, Time, Genre, Plays, Format, HiRes, Liked, Quality };
    struct Row { int track = -1; bool stripe = false; QString title, detail; };

    explicit LibraryRows(Library *library) : QAbstractListModel(library), m_library(library) {}
    int rowCount(const QModelIndex & = {}) const override { return int(m_rows.size()); }
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;
    void reset(std::vector<Row> rows);
    void refreshAll();
    Q_INVOKABLE int rowOfTrack(int track) const { return m_rowOf.value(track, -1); }
    Q_INVOKABLE int trackAt(int row) const { return row >= 0 && row < int(m_rows.size()) ? m_rows[size_t(row)].track : -1; }

private:
    Library *m_library;
    std::vector<Row> m_rows;
    QHash<int, int> m_rowOf;
};

namespace LibraryFiles {
/// Tags, technical facts and the cover of one audio file, as the core's track JSON.
QJsonObject readFile(const QString &path);
bool isAudioFile(const QString &path);
/// The raw lyrics for a file: a .lrc beside it, else its lyrics tag.
QString rawLyrics(const QString &path);
}
