#include "Library.h"
#include "CoreBridge.h"
#include "i2s_core.h"
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QSaveFile>
#include <QSet>
#include <QUrl>
#include <QUuid>
#include <mutex>
#include <taglib/fileref.h>
#include <taglib/tpropertymap.h>
#include <taglib/flacfile.h>
#include <taglib/mpegfile.h>
#include <taglib/mp4file.h>
#include <taglib/wavfile.h>
#include <taglib/aifffile.h>
#include <taglib/vorbisfile.h>
#include <taglib/opusfile.h>

namespace {
// The app's JSON dates are seconds since 2001-01-01 (Foundation's default).
constexpr double kReferenceEpoch = 978307200;

QByteArray utf8(const QString &s) { return s.toUtf8(); }
QString take(char *p) { if (!p) return {}; QString s = QString::fromUtf8(p); i2s_free(p); return s; }
QJsonDocument takeJSON(char *p) { if (!p) return {}; QJsonDocument d = QJsonDocument::fromJson(QByteArray(p)); i2s_free(p); return d; }
QByteArray idsJSON(const QVariantList &tracks, const Library *l) {
    QJsonArray a;
    for (const QVariant &v : tracks) if (const Track *t = l->at(v.toInt())) a << t->id;
    return QJsonDocument(a).toJson(QJsonDocument::Compact);
}
QString defaultsFile(const QString &key) { return Core::supportDir() + "/defaults/" + key + ".json"; }
}

bool Track::lossless() const {
    const QString f = fileFormat.toUpper();
    return f == "FLAC" || f == "ALAC" || f == "WAV" || f == "AIFF" || f == "PCM";
}

QString Track::clock(double s) {
    if (!(s >= 0) || !std::isfinite(s)) s = 0;
    const int total = int(s);
    const int h = total / 3600, m = (total % 3600) / 60, sec = total % 60;
    return h > 0 ? QStringLiteral("%1:%2:%3").arg(h).arg(m, 2, 10, QChar('0')).arg(sec, 2, 10, QChar('0'))
                 : QStringLiteral("%1:%2").arg(m).arg(sec, 2, 10, QChar('0'));
}

QString Track::rate(double hz) {
    const double k = hz / 1000.0;
    return (std::fmod(k, 1.0) == 0 ? QString::number(int(k)) : QString::number(k, 'f', 1)) + " kHz";
}

// MARK: - Library

Library *Library::instance() {
    static Library *s = new Library;
    return s;
}

Library::Library(QObject *parent) : QObject(parent), m_rows(new LibraryRows(this)) {
    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(800);
    connect(&m_saveTimer, &QTimer::timeout, this, &Library::save);
    // Typing in the filter re-queries once the keys settle.
    m_viewTimer.setSingleShot(true);
    m_viewTimer.setInterval(60);
    connect(&m_viewTimer, &QTimer::timeout, this, &Library::rebuildView);
    m_rescanSoon.setSingleShot(true);
    m_rescanSoon.setInterval(1500);
    connect(&m_rescanSoon, &QTimer::timeout, this, &Library::rescan);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] { m_rescanSoon.start(); });
    connect(Core::instance(), &Core::settingsChanged, this, [this] {
        static QString last;
        if (groupBy() != last) { last = groupBy(); rebuildView(); }
    });
}

Library::~Library() {
    m_cancel = true;
    if (m_thread.joinable()) m_thread.join();
    flush();
    if (m_lib) i2s_library_close(m_lib);
    if (m_history) i2s_history_close(m_history);
}

QString Library::groupBy() const { return Core::instance()->settings().value("groupBy").toString(); }

void Library::open() {
    const QString dir = Core::supportDir();
    QDir().mkpath(dir);
    m_path = dir + "/library.json";
    char *err = nullptr;
    m_lib = i2s_library_open(utf8(m_path).constData(), &err);
    if (!m_lib) {
        // Never overwrite a library file this build can't read.
        qWarning("i2s: library: %s", err ? err : "unreadable");
        i2s_free(err);
        QFile::copy(m_path, dir + "/library.unreadable.json");
        QFile::remove(m_path);
        m_lib = i2s_library_open(utf8(m_path).constData(), nullptr);
    }
    // The starter smart playlists, once.
    const QString seeded = defaultsFile("com.meimei.player.smartPlaylistsSeeded.v1");
    if (!QFile::exists(seeded)) {
        i2s_library_seed_starter_playlists(m_lib);
        QDir().mkpath(QFileInfo(seeded).absolutePath());
        QSaveFile f(seeded);
        if (f.open(QIODevice::WriteOnly)) { f.write("true"); f.commit(); }
        saveSoon();
    }
    // Play counts come only from the listening history.
    err = nullptr;
    m_history = i2s_history_open(utf8(dir + "/History").constData(), &err);
    if (!m_history) { qWarning("i2s: history: %s", err ? err : "unavailable"); i2s_free(err); }
    else i2s_library_apply_history(m_lib, m_history);

    QFile folders(dir + "/library-folders.json");
    if (folders.open(QIODevice::ReadOnly))
        for (const QJsonValue &v : QJsonDocument::fromJson(folders.readAll()).object()["folders"].toArray())
            m_folders << v.toObject()["path"].toString();
    for (const QString &d : m_folders) if (QDir(d).exists()) m_watcher.addPath(d);

    reloadTracks();
    reloadPlaylists();
    rebuildView();
    if (!m_folders.isEmpty()) QTimer::singleShot(1500, this, &Library::rescan);
}

void Library::reloadTracks() {
    const QJsonArray list = takeJSON(i2s_library_tracks_json(m_lib)).array();
    std::vector<Track> tracks;
    tracks.reserve(size_t(list.size()));
    QHash<QString, int> index;
    QSet<QString> albums, artists;
    QHash<QString, int> genres;
    m_totalDuration = 0;
    m_likedCount = 0;
    for (const QJsonValue &v : list) {
        const QJsonObject o = v.toObject();
        Track t;
        t.id = o["id"].toString();
        t.filePath = o["filePath"].toString();
        t.title = o["title"].toString();
        t.artist = o["artist"].toString();
        t.album = o["album"].toString();
        t.albumArtist = o["albumArtist"].toString();
        t.genre = o["genre"].toString();
        t.fileFormat = o["fileFormat"].toString();
        t.artwork = o["artworkFilePath"].toString();
        t.year = o["year"].toInt();
        t.trackNumber = o["trackNumber"].toInt();
        t.discNumber = o["discNumber"].toInt();
        t.duration = o["duration"].toDouble();
        t.sampleRate = o["sampleRate"].toDouble(44100);
        t.bitDepth = o["bitDepth"].toInt(16);
        t.channelCount = o["channelCount"].toInt(2);
        t.bitrate = o["estimatedBitrateKbps"].toInt();
        t.playCount = o["playCount"].toInt();
        t.liked = o["liked"].toBool();
        t.dateAdded = o["dateAdded"].toDouble() + kReferenceEpoch;
        if (o.contains("lastPlayedAt")) t.lastPlayed = o["lastPlayedAt"].toDouble() + kReferenceEpoch;
        index.insert(t.id, int(tracks.size()));
        albums.insert(t.albumKey());
        artists.insert((t.albumArtist.isEmpty() ? t.artist : t.albumArtist).toLower());
        if (!t.genre.isEmpty()) genres[t.genre] += 1;
        m_totalDuration += t.duration;
        if (t.liked) ++m_likedCount;
        tracks.push_back(std::move(t));
    }
    m_tracks = std::move(tracks);
    m_index = std::move(index);
    m_albumCount = int(albums.size());
    m_artistCount = int(artists.size());
    QStringList names = genres.keys();
    std::sort(names.begin(), names.end(), [](const QString &a, const QString &b) { return QString::localeAwareCompare(a, b) < 0; });
    m_genres.clear();
    for (const QString &g : names) m_genres << QVariantMap{{"name", g}, {"count", genres.value(g)}};
    emit tracksChanged();
}

void Library::reloadPlaylists() {
    m_playlistData = takeJSON(i2s_library_playlists_json(m_lib)).array().toVariantList();
    m_playlistList.clear();
    for (const QVariant &v : m_playlistData) {
        const QVariantMap p = v.toMap();
        const QString key = "playlist:" + p.value("id").toString();
        const QJsonArray items = takeJSON(i2s_library_view_json(m_lib, utf8(key).constData(), nullptr, nullptr, 1, nullptr)).array();
        QString artwork;
        for (const QJsonValue &i : items) if (const Track *t = at(i.toInt()); t && !t->artwork.isEmpty()) { artwork = t->artwork; break; }
        m_playlistList << QVariantMap{{"id", p.value("id")}, {"name", p.value("name")}, {"smart", p.value("isSmart")},
                                      {"builtIn", p.value("isBuiltIn")}, {"count", items.size()}, {"artwork", artwork}};
    }
    emit playlistsChanged();
}

void Library::rebuildView() {
    if (!m_lib) return;
    char *err = nullptr;
    const QJsonArray rows = takeJSON(i2s_library_rows_json(m_lib, utf8(m_source).constData(), utf8(m_filter).constData(),
                                                           utf8(m_sortKey).constData(), m_ascending ? 1 : 0,
                                                           utf8(groupBy()).constData(), &err)).array();
    if (err) { qWarning("i2s: library view: %s", err); i2s_free(err); }
    std::vector<LibraryRows::Row> out;
    out.reserve(size_t(rows.size()));
    m_visible.clear();
    m_visibleDuration = 0;
    for (const QJsonValue &v : rows) {
        const QJsonObject o = v.toObject();
        LibraryRows::Row r;
        if (o.contains("h")) { r.title = o["h"].toString(); r.detail = o["d"].toString(); }
        else {
            r.track = o["t"].toInt(-1);
            r.stripe = o["s"].toInt() == 1;
            if (const Track *t = at(r.track)) { m_visible.push_back(r.track); m_visibleDuration += t->duration; }
        }
        out.push_back(std::move(r));
    }
    m_rows->reset(std::move(out));
    emit viewChanged();
}

void Library::setSource(const QString &s) {
    if (s == m_source) return;
    m_source = s;
    emit sourceChanged();
    rebuildView();
}

void Library::setFilterText(const QString &t) {
    if (t == m_filter) return;
    m_filter = t;
    emit filterTextChanged();
    m_viewTimer.start();
}

void Library::toggleSort(const QString &key) {
    if (m_sortKey != key) { m_sortKey = key; m_ascending = true; }
    else if (m_ascending) m_ascending = false;
    else { m_sortKey.clear(); m_ascending = true; }
    rebuildView();
}

QString Library::sourceTitle() const {
    if (m_source == "all") return "All Music";
    if (m_source == "albums") return "Albums";
    if (m_source == "artists") return "Artists";
    if (m_source == "liked") return "Liked Songs";
    if (m_source == "recentlyAdded") return "Recently Added";
    if (m_source == "recentlyPlayed") return "Recently Played";
    if (m_source == "mostPlayed") return "Most Played";
    if (m_source == "profile") return "Profile";
    if (m_source.startsWith("artist:")) return m_source.mid(7);
    if (m_source.startsWith("genre:")) return m_source.mid(6);
    if (m_source.startsWith("playlist:")) {
        for (const QVariant &v : m_playlistList) if ("playlist:" + v.toMap().value("id").toString() == m_source) return v.toMap().value("name").toString();
        return "Playlist";
    }
    return m_source;
}

QString Library::eyebrow() const {
    if (m_source.startsWith("artist:")) return "Artist";
    if (m_source.startsWith("genre:")) return "Genre";
    if (m_source.startsWith("playlist:")) {
        for (const QVariant &v : m_playlistList) {
            const QVariantMap p = v.toMap();
            if ("playlist:" + p.value("id").toString() == m_source) return p.value("smart").toBool() ? "Smart Playlist" : "Playlist";
        }
        return "Playlist";
    }
    if (m_source == "recentlyAdded" || m_source == "recentlyPlayed" || m_source == "mostPlayed") return "Collection";
    return {};
}

namespace {
QString longDuration(double seconds) {
    const int minutes = int(seconds / 60);
    if (minutes < 60) return QStringLiteral("%1 min").arg(minutes);
    const int h = minutes / 60, m = minutes % 60;
    return m == 0 ? QStringLiteral("%1 hr").arg(h) : QStringLiteral("%1 hr %2 min").arg(h).arg(m);
}
}

QString Library::summary() const {
    if (m_visible.empty()) return m_filter.isEmpty() ? "No tracks" : "No matches";
    QStringList parts;
    if (m_source.startsWith("artist:")) {
        QSet<QString> albums;
        for (int i : m_visible) albums.insert(m_tracks[size_t(i)].albumKey());
        parts << (albums.size() == 1 ? QStringLiteral("1 album") : QStringLiteral("%1 albums").arg(albums.size()));
    }
    parts << (m_visible.size() == 1 ? QStringLiteral("1 track") : QStringLiteral("%1 tracks").arg(m_visible.size()));
    parts << longDuration(m_visibleDuration);
    if (!m_filter.isEmpty()) parts << "filtered";
    return parts.join(" · ");
}

QVariantMap Library::track(int index) const {
    const Track *t = at(index);
    if (!t) return {};
    return {{"index", index}, {"id", t->id}, {"title", t->title}, {"artist", t->artist}, {"album", t->album},
            {"albumArtist", t->albumArtist}, {"genre", t->genre}, {"year", t->year}, {"duration", t->duration},
            {"format", t->fileFormat}, {"artwork", t->artwork}, {"liked", t->liked}, {"plays", t->playCount},
            {"hiRes", t->hiRes()}, {"lossless", t->lossless()}, {"bitDepth", t->bitDepth}, {"sampleRate", t->sampleRate},
            {"bitrate", t->bitrate}, {"filePath", t->filePath}};
}

QVariantList Library::visibleTracks() const {
    QVariantList out;
    out.reserve(qsizetype(m_visible.size()));
    for (int i : m_visible) out << i;
    return out;
}

void Library::setLiked(const QVariantList &tracks, bool liked) {
    i2s_library_set_liked(m_lib, idsJSON(tracks, this).constData(), liked ? 1 : 0);
    for (const QVariant &v : tracks) if (v.toInt() >= 0 && v.toInt() < int(m_tracks.size())) m_tracks[size_t(v.toInt())].liked = liked;
    m_likedCount = 0;
    for (const Track &t : m_tracks) if (t.liked) ++m_likedCount;
    m_rows->refreshAll();
    emit tracksChanged();
    if (m_source == "liked") rebuildView();
    saveSoon();
}

void Library::removeTracks(const QVariantList &tracks) {
    i2s_library_remove_tracks(m_lib, idsJSON(tracks, this).constData());
    reloadTracks();
    reloadPlaylists();
    rebuildView();
    saveSoon();
}

QString Library::createPlaylist(const QString &name, const QVariantList &tracks) {
    QJsonObject op{{"op", "create"}, {"name", name}, {"trackIDs", QJsonDocument::fromJson(idsJSON(tracks, this)).array()}};
    const QString id = take(i2s_library_playlist_edit_json(m_lib, QJsonDocument(op).toJson(QJsonDocument::Compact).constData(), nullptr));
    reloadPlaylists();
    saveSoon();
    return id;
}

void Library::editPlaylist(const QString &op, const QString &id, const QVariantList &tracks, const QString &name, int index) {
    QJsonObject o{{"op", op}, {"id", id}, {"name", name}, {"index", index},
                  {"trackIDs", QJsonDocument::fromJson(idsJSON(tracks, this)).array()}};
    char *err = nullptr;
    i2s_free(i2s_library_playlist_edit_json(m_lib, QJsonDocument(o).toJson(QJsonDocument::Compact).constData(), &err));
    if (err) { qWarning("i2s: playlist: %s", err); i2s_free(err); }
    reloadPlaylists();
    if (op == "delete" && m_source == "playlist:" + id) setSource("all");
    else if (m_source == "playlist:" + id) rebuildView();
    saveSoon();
}

void Library::showInExplorer(int index) const {
    if (const Track *t = at(index)) QProcess::startDetached("explorer.exe", {"/select,", QDir::toNativeSeparators(t->filePath)});
}

void Library::recordPlay(const QString &id, double at) {
    // The core already counted it (i2s_history_record_track); mirror it in the display copy.
    const int i = indexOf(id);
    if (i >= 0) { m_tracks[size_t(i)].playCount += 1; m_tracks[size_t(i)].lastPlayed = std::max(m_tracks[size_t(i)].lastPlayed, at); }
    m_rows->refreshAll();
    emit tracksChanged();
    if (m_source == "recentlyPlayed" || m_source == "mostPlayed") rebuildView();
}

void Library::saveSoon() { m_saveTimer.start(); }

void Library::save() {
    if (!m_lib) return;
    char *err = nullptr;
    if (i2s_library_save(m_lib, utf8(m_path).constData(), &err) != 0) { qWarning("i2s: save: %s", err ? err : "failed"); i2s_free(err); }
}

void Library::flush() { if (m_saveTimer.isActive()) { m_saveTimer.stop(); save(); } }

// MARK: - Scanning

void Library::saveFolders() {
    QJsonArray list;
    for (const QString &p : m_folders)
        list << QJsonObject{{"id", QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper()}, {"path", p},
                            {"added", double(QDateTime::currentSecsSinceEpoch()) - kReferenceEpoch}, {"watched", true}, {"included", true}};
    QSaveFile f(Core::supportDir() + "/library-folders.json");
    if (f.open(QIODevice::WriteOnly)) { f.write(QJsonDocument(QJsonObject{{"folders", list}}).toJson()); f.commit(); }
}

void Library::importItems(const QVariantList &items) {
    QStringList roots;
    for (const QVariant &v : items) {
        QString path = v.toUrl().isLocalFile() ? v.toUrl().toLocalFile() : v.toString();
        if (path.startsWith("file:")) path = QUrl(path).toLocalFile();
        if (path.isEmpty()) continue;
        path = QDir::cleanPath(path);
        if (QFileInfo(path).isDir() && !m_folders.contains(path)) { m_folders << path; m_watcher.addPath(path); }
        roots << path;
    }
    saveFolders();
    emit foldersChanged();
    scan(roots);
}

void Library::rescan() { scan(m_folders); }

void Library::removeFolder(const QString &folder) {
    m_folders.removeAll(folder);
    m_watcher.removePath(folder);
    saveFolders();
    emit foldersChanged();
}

void Library::scan(QStringList roots) {
    if (roots.isEmpty()) return;
    if (m_scanning) { m_queued += roots; return; }
    if (m_thread.joinable()) m_thread.join();
    m_scanning = true;
    m_scanDone = m_scanTotal = 0;
    m_scanLabel = roots.size() == 1 ? QFileInfo(roots.first()).fileName() : QStringLiteral("your folders");
    emit scanChanged();
    QSet<QString> known;
    for (const QJsonValue &v : takeJSON(i2s_library_file_paths_json(m_lib)).array()) known.insert(QDir::fromNativeSeparators(v.toString()).toLower());
    m_thread = std::thread([this, roots, known] {
        // Find the new audio files first, then read them in batches so the table fills while importing.
        QStringList files;
        for (const QString &root : roots) {
            if (QFileInfo(root).isFile()) { if (LibraryFiles::isAudioFile(root) && !known.contains(root.toLower())) files << root; continue; }
            QDirIterator it(root, QDir::Files, QDirIterator::Subdirectories);
            while (it.hasNext() && !m_cancel) {
                const QString p = it.next();
                if (LibraryFiles::isAudioFile(p) && !known.contains(p.toLower())) files << p;
            }
        }
        QMetaObject::invokeMethod(this, [this, n = files.size()] { m_scanTotal = int(n); emit scanChanged(); }, Qt::QueuedConnection);
        QJsonArray batch;
        int done = 0;
        for (const QString &p : files) {
            if (m_cancel) return;
            const QJsonObject t = LibraryFiles::readFile(p);
            if (!t.isEmpty()) batch << t;
            ++done;
            if (batch.size() >= 400 || done == files.size()) {
                const QByteArray json = QJsonDocument(batch).toJson(QJsonDocument::Compact);
                batch = QJsonArray();
                QMetaObject::invokeMethod(this, [this, json, done] {
                    char *err = nullptr;
                    if (i2s_library_add_tracks_json(m_lib, json.constData(), &err) < 0) { qWarning("i2s: import: %s", err ? err : "failed"); i2s_free(err); }
                    reloadTracks();
                    reloadPlaylists();
                    rebuildView();
                    saveSoon();
                    m_scanDone = done;
                    emit scanChanged();
                }, Qt::QueuedConnection);
            } else if (done % 25 == 0) {
                QMetaObject::invokeMethod(this, [this, done] { m_scanDone = done; emit scanChanged(); }, Qt::QueuedConnection);
            }
        }
        QMetaObject::invokeMethod(this, [this] {
            m_scanning = false;
            emit scanChanged();
            if (!m_queued.isEmpty()) { const QStringList q = m_queued; m_queued.clear(); scan(q); }
        }, Qt::QueuedConnection);
    });
}

// MARK: - Rows

QHash<int, QByteArray> LibraryRows::roleNames() const {
    return {{IsHeader, "isHeader"}, {HeaderTitle, "headerTitle"}, {HeaderDetail, "headerDetail"}, {TrackIndex, "track"},
            {Stripe, "stripe"}, {Title, "title"}, {Artist, "artist"}, {Album, "album"}, {AlbumArtist, "albumArtist"},
            {TrackNo, "trackNo"}, {Year, "year"}, {Time, "time"}, {Genre, "genre"}, {Plays, "plays"}, {Format, "format"},
            {HiRes, "hiRes"}, {Liked, "liked"}, {Quality, "quality"}};
}

QVariant LibraryRows::data(const QModelIndex &index, int role) const {
    if (!index.isValid() || index.row() >= int(m_rows.size())) return {};
    const Row &r = m_rows[size_t(index.row())];
    if (role == IsHeader) return r.track < 0;
    if (role == HeaderTitle) return r.title;
    if (role == HeaderDetail) return r.detail;
    if (role == TrackIndex) return r.track;
    if (role == Stripe) return r.stripe;
    const Track *t = m_library->at(r.track);
    if (!t) return {};
    switch (role) {
    case Title: return t->title;
    case Artist: return t->artist;
    case Album: return t->album;
    case AlbumArtist: return t->albumArtist;
    case TrackNo: return t->trackNumber > 0 ? QString::number(t->trackNumber) : QString();
    case Year: return t->year > 0 ? QString::number(t->year) : QString();
    case Time: return Track::clock(t->duration);
    case Genre: return t->genre;
    case Plays: return t->playCount > 0 ? QString::number(t->playCount) : QString();
    case Format: return t->fileFormat;
    case HiRes: return t->hiRes();
    case Liked: return t->liked;
    case Quality: return t->lossless() ? QStringLiteral("%1/%2").arg(t->bitDepth).arg(Track::rate(t->sampleRate))
                                       : (t->bitrate > 0 ? QStringLiteral("%1 kbps").arg(t->bitrate) : QString());
    }
    return {};
}

void LibraryRows::reset(std::vector<Row> rows) {
    beginResetModel();
    m_rows = std::move(rows);
    m_rowOf.clear();
    for (int i = 0; i < int(m_rows.size()); ++i) if (m_rows[size_t(i)].track >= 0) m_rowOf.insert(m_rows[size_t(i)].track, i);
    endResetModel();
}

void LibraryRows::refreshAll() {
    if (!m_rows.empty()) emit dataChanged(index(0), index(int(m_rows.size()) - 1));
}

// MARK: - Files

namespace {
const QStringList kAudio = {"mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "aifc", "caf", "alac", "ogg", "opus", "wv", "ape"};
QString str(const TagLib::String &s) { return QString::fromStdWString(s.toWString()).trimmed(); }

QString artworkDir() {
    const QString d = Core::supportDir() + "/Artwork";
    QDir().mkpath(d);
    return d;
}

/// Stores cover bytes once, named by their hash, so every track of a record shares one file.
QString storeArtwork(const QByteArray &bytes, const QString &mime) {
    if (bytes.isEmpty()) return {};
    const QString hash = QString::fromLatin1(QCryptographicHash::hash(bytes, QCryptographicHash::Sha256).toHex().left(32));
    const QString path = artworkDir() + "/" + hash + (mime.contains("png") ? ".png" : ".jpg");
    if (!QFile::exists(path)) {
        QSaveFile f(path);
        if (f.open(QIODevice::WriteOnly)) { f.write(bytes); f.commit(); }
    }
    return QDir::toNativeSeparators(path);
}

/// A cover image beside the files (cover.jpg, folder.png, ...), cached per folder.
QString folderArtwork(const QString &dir) {
    static QHash<QString, QString> cache;
    static std::mutex lock;
    std::lock_guard l(lock);
    auto it = cache.constFind(dir);
    if (it != cache.constEnd()) return *it;
    QString found;
    const QStringList names = {"cover", "folder", "front", "album", "artwork"};
    for (const QFileInfo &fi : QDir(dir).entryInfoList({"*.jpg", "*.jpeg", "*.png"}, QDir::Files)) {
        if (!names.contains(fi.completeBaseName().toLower())) continue;
        QFile f(fi.absoluteFilePath());
        if (f.open(QIODevice::ReadOnly)) found = storeArtwork(f.readAll(), fi.suffix().toLower() == "png" ? "image/png" : "image/jpeg");
        break;
    }
    cache.insert(dir, found);
    return found;
}
}

bool LibraryFiles::isAudioFile(const QString &path) { return kAudio.contains(QFileInfo(path).suffix().toLower()); }

QJsonObject LibraryFiles::readFile(const QString &path) {
    TagLib::FileRef f(reinterpret_cast<const wchar_t *>(path.utf16()));
    if (f.isNull()) return {};
    const TagLib::PropertyMap props = f.properties();
    auto get = [&](const char *key) { auto it = props.find(key); return it == props.end() || it->second.isEmpty() ? QString() : str(it->second.front()); };
    auto number = [](const QString &s) { return s.section('/', 0, 0).trimmed().toInt(); };
    QString title = get("TITLE");
    if (title.isEmpty()) title = QFileInfo(path).completeBaseName();
    const QString artist = get("ARTIST");
    QString albumArtist = get("ALBUMARTIST");
    if (albumArtist.isEmpty()) albumArtist = artist;
    int year = get("DATE").left(4).toInt();
    if (!year) year = get("ORIGINALDATE").left(4).toInt();
    double duration = 0, sampleRate = 44100;
    int channels = 2, bitrate = 0, bitDepth = 0;
    if (const TagLib::AudioProperties *ap = f.audioProperties()) {
        duration = ap->lengthInMilliseconds() / 1000.0;
        if (ap->sampleRate() > 0) sampleRate = ap->sampleRate();
        channels = ap->channels();
        bitrate = ap->bitrate();
    }
    QString format;
    TagLib::File *file = f.file();
    if (auto *x = dynamic_cast<TagLib::FLAC::File *>(file)) { format = "FLAC"; bitDepth = x->audioProperties()->bitsPerSample(); }
    else if (dynamic_cast<TagLib::MPEG::File *>(file)) format = "MP3";
    else if (auto *x = dynamic_cast<TagLib::MP4::File *>(file)) {
        const bool alac = x->audioProperties() && x->audioProperties()->codec() == TagLib::MP4::Properties::ALAC;
        format = alac ? "ALAC" : "AAC";
        if (alac) bitDepth = x->audioProperties()->bitsPerSample();
    }
    else if (auto *x = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) { format = "WAV"; bitDepth = x->audioProperties()->bitsPerSample(); }
    else if (auto *x = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) { format = "AIFF"; bitDepth = x->audioProperties()->bitsPerSample(); }
    else if (dynamic_cast<TagLib::Ogg::Vorbis::File *>(file)) format = "OGG";
    else if (dynamic_cast<TagLib::Ogg::Opus::File *>(file)) format = "OPUS";
    else format = QFileInfo(path).suffix().toUpper();
    const bool lossless = format == "FLAC" || format == "ALAC" || format == "WAV" || format == "AIFF";
    if (!lossless || bitDepth <= 0) bitDepth = 16;
    if (lossless) bitrate = 0;
    // Embedded cover (front cover first), else a cover image in the folder.
    QByteArray bytes;
    QString mime;
    for (const auto &pic : f.complexProperties("PICTURE")) {
        const auto data = pic.value("data").toByteVector();
        if (data.isEmpty()) continue;
        const bool front = pic.value("pictureType").toString() == "Front Cover";
        if (bytes.isEmpty() || front) { bytes = QByteArray(data.data(), qsizetype(data.size())); mime = str(pic.value("mimeType").toString()); }
        if (front) break;
    }
    const QString artwork = bytes.isEmpty() ? folderArtwork(QFileInfo(path).absolutePath()) : storeArtwork(bytes, mime);

    QJsonObject o{{"id", QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper()}, {"filePath", QDir::toNativeSeparators(path)},
                  {"title", title}, {"artist", artist}, {"album", get("ALBUM")}, {"albumArtist", albumArtist},
                  {"genre", get("GENRE")}, {"composer", get("COMPOSER")}, {"duration", duration}, {"sampleRate", sampleRate},
                  {"bitDepth", bitDepth}, {"channelCount", channels}, {"estimatedBitrateKbps", bitrate}, {"fileFormat", format},
                  {"dateAdded", double(QDateTime::currentMSecsSinceEpoch()) / 1000.0 - kReferenceEpoch}, {"playCount", 0}, {"liked", false}};
    if (year) o["year"] = year;
    if (const int n = number(get("TRACKNUMBER"))) o["trackNumber"] = n;
    if (const int n = number(get("DISCNUMBER"))) o["discNumber"] = n;
    if (!artwork.isEmpty()) o["artworkFilePath"] = artwork;
    return o;
}

QString LibraryFiles::rawLyrics(const QString &path) {
    const QFileInfo fi(path);
    QFile lrc(fi.absolutePath() + "/" + fi.completeBaseName() + ".lrc");
    if (lrc.open(QIODevice::ReadOnly)) {
        const QString text = QString::fromUtf8(lrc.readAll());
        if (!text.trimmed().isEmpty()) return text;
    }
    TagLib::FileRef f(reinterpret_cast<const wchar_t *>(path.utf16()), false);
    if (f.isNull()) return {};
    const auto props = f.properties();
    auto it = props.find("LYRICS");
    return it != props.end() && !it->second.isEmpty() ? str(it->second.front()) : QString();
}
