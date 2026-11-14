// i2s for Windows: the entry point. Loads the shared core, the bundled type,
// the audio engine and media keys, then the window. Test switches (all
// headless: nothing is shown, no focus is taken):
//   --headless                 never show a window
//   --snapshot <file.png>      render the window offscreen, save, quit
//   --size <w>x<h>             window size in points (snapshots)
//   --open <a,b,c>             states to put the window in first
//   --delay <s>                wait before the snapshot (default 1.5)
//   --self-test <file>         run the platform checks, write results, quit
//   --metrics <file>           append timings and memory
//   --exit-after <s>           quit after s seconds
//   --blur acrylic|blur|system|none   which behind-window blur glass uses
//   --support-dir <dir>        keep settings there (tests), as I2S_SUPPORT_DIR
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QTextStream>
#include <QTimer>
#include <windows.h>
#include <werapi.h>
#include <psapi.h>
#include "CoreBridge.h"
#include "Platform.h"
#include "Typography.h"
#include "Glyph.h"
#include "AudioEngine.h"
#include "MediaSession.h"
#include "SelfTest.h"
#include "Library.h"
#include "Player.h"
#include "Artwork.h"

namespace {
QString gMetrics;
void metric(const QString &line) {
    if (gMetrics.isEmpty()) return;
    QFile f(gMetrics);
    if (f.open(QIODevice::Append | QIODevice::Text)) QTextStream(&f) << line << "\n";
}
double msSinceProcessStart() {
    FILETIME create, exit, kernel, user, now;
    GetProcessTimes(GetCurrentProcess(), &create, &exit, &kernel, &user);
    GetSystemTimePreciseAsFileTime(&now);
    auto v = [](FILETIME t) { return (quint64(t.dwHighDateTime) << 32) | t.dwLowDateTime; };
    return double(v(now) - v(create)) / 10000.0;
}
QString memoryLine() {
    PROCESS_MEMORY_COUNTERS_EX pmc{};
    GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&pmc), sizeof(pmc));
    return QStringLiteral("memory: working set %1 MB, private %2 MB").arg(pmc.WorkingSetSize / 1048576.0, 0, 'f', 1).arg(pmc.PrivateUsage / 1048576.0, 0, 'f', 1);
}
/// The bundled fonts: next to the app when installed, the repository's font folder in development.
QString fontDir() {
    const QString installed = QCoreApplication::applicationDirPath() + "/Fonts";
    if (QDir(installed).exists()) return installed;
    return qEnvironmentVariable("I2S_FONT_DIR", QStringLiteral(I2S_FONT_DIR));
}
}

int main(int argc, char *argv[]) {
    // A crash never opens Windows' error dialog (tests run unattended).
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    WerSetFlags(WER_FAULT_REPORTING_NO_UI);
    // Text as macOS draws it: FreeType, unhinted, greyscale. DirectWrite would
    // hint and draw ClearType colour fringes whatever the font asks for.
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) qputenv("QT_QPA_PLATFORM", "windows:fontengine=freetype");

    QGuiApplication app(argc, argv);
    app.setOrganizationName("i2s");
    app.setApplicationName("i2s");
    const QStringList args = app.arguments();
    auto arg = [&](const QString &name) { const int i = int(args.indexOf(name)); return i >= 0 && i + 1 < args.size() ? args[i + 1] : QString(); };
    gMetrics = arg("--metrics");
    metric(QStringLiteral("--- i2s %1").arg(QDateTime::currentDateTime().toString(Qt::ISODate)));
    // A GUI app has no console: Qt's warnings (QML errors) go to the metrics file.
    if (!gMetrics.isEmpty()) qInstallMessageHandler([](QtMsgType type, const QMessageLogContext &, const QString &msg) {
        if (type != QtDebugMsg) metric(QStringLiteral("qt: ") + msg);
    });
    if (!arg("--support-dir").isEmpty()) qputenv("I2S_SUPPORT_DIR", QDir::toNativeSeparators(arg("--support-dir")).toUtf8());

    const QString selfTestOut = arg("--self-test");
    const QString snapshot = arg("--snapshot");
    const bool headless = args.contains("--headless") || !snapshot.isEmpty() || !selfTestOut.isEmpty();
    Platform *platform = Platform::instance();
    platform->setHeadless(headless);
    platform->setForceFallback(!snapshot.isEmpty());
    if (!arg("--blur").isEmpty()) platform->setBlurKind(arg("--blur"));

    metric(QStringLiteral("app object at %1 ms").arg(msSinceProcessStart(), 0, 'f', 1));
    Core *core = Core::instance();
    metric(QStringLiteral("core ready at %1 ms").arg(msSinceProcessStart(), 0, 'f', 1));
    if (!core->compatible()) {
        const QString why = QStringLiteral("The core library doesn't match this build (interface %1, expected %2).")
                                .arg(core->version().value("interface").toInt()).arg(Core::interfaceVersion);
        metric(why);
        if (!headless) MessageBoxW(nullptr, reinterpret_cast<const wchar_t *>(why.utf16()), L"i2s", MB_ICONERROR);
        return 2;
    }
    Type *type = Type::instance();
    const int faces = type->registerFonts(fontDir());
    GlyphItem::setSymbolsFont(type->symbolsPath());
    metric(QStringLiteral("core interface %1; %2 font faces; at %3 ms").arg(core->version().value("interface").toInt()).arg(faces).arg(msSinceProcessStart(), 0, 'f', 1));

    AudioEngine audio;
    // The library (and the history) open before the window, so the first frame shows them.
    Library *library = Library::instance();
    Player *player = Player::instance();
    player->attach(&audio);
    if (selfTestOut.isEmpty()) {
        library->open();
        player->restoreSession();
        if (!arg("--import").isEmpty()) library->importItems({arg("--import")});
        metric(QStringLiteral("library: %1 tracks at %2 ms").arg(library->count()).arg(msSinceProcessStart(), 0, 'f', 1));
    }

    QQmlApplicationEngine engine;
    engine.addImageProvider("art", new ArtProvider);
    engine.addImageProvider("backdrop", new BackdropProvider);
    engine.rootContext()->setContextProperty("openStates", arg("--open").split(',', Qt::SkipEmptyParts));
    // The phase-1 platform window and the component gallery stay reachable for tests.
    const QStringList states = arg("--open").split(',', Qt::SkipEmptyParts);
    engine.loadFromModule("I2S", states.contains("gallery") || states.contains("platform") || !selfTestOut.isEmpty() ? "Shell" : "MainWindow");
    if (engine.rootObjects().isEmpty()) return 1;
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!window) return 1;
    const QString size = arg("--size");
    if (!size.isEmpty()) window->resize(size.section('x', 0, 0).toInt(), size.section('x', 1, 1).toInt());
    platform->setup(window, true);
    metric(QStringLiteral("qml loaded at %1 ms").arg(msSinceProcessStart(), 0, 'f', 1));

    bool first = true;
    QObject::connect(window, &QQuickWindow::frameSwapped, window, [&] {
        if (!first) return;
        first = false;
        metric(QStringLiteral("first frame at %1 ms").arg(msSinceProcessStart(), 0, 'f', 1));
        metric(memoryLine() + " (first frame)");
    }, Qt::DirectConnection);

    // Media keys: Windows ties the session to the main window.
    MediaSession *media = MediaSession::instance();
    media->attach(window);
    QObject::connect(media, &MediaSession::playRequested, &audio, &AudioEngine::play);
    QObject::connect(media, &MediaSession::pauseRequested, &audio, &AudioEngine::pause);
    QObject::connect(media, &MediaSession::toggleRequested, player, &Player::togglePlayPause);
    QObject::connect(media, &MediaSession::stopRequested, player, &Player::stop);
    QObject::connect(media, &MediaSession::nextRequested, player, &Player::next);
    QObject::connect(media, &MediaSession::previousRequested, player, &Player::previous);
    QObject::connect(player, &Player::trackChanged, media, [&] {
        const QVariantMap t = player->track();
        media->setTrack(t.value("title").toString(), t.value("artist").toString(), t.value("album").toString(), t.value("albumArtist").toString());
    });
    QObject::connect(media, &MediaSession::seekRequested, &audio, &AudioEngine::seek);
    QObject::connect(&audio, &AudioEngine::playingChanged, media, [&] {
        if (audio.currentID().isEmpty()) media->setStopped(); else media->setPlaying(audio.isPlaying());
        media->setTimeline(audio.currentTime(), audio.duration());
    });

    if (!headless) window->show();

    if (!snapshot.isEmpty()) {
        const int delay = int((arg("--delay").isEmpty() ? 1.5 : arg("--delay").toDouble()) * 1000);
        QTimer::singleShot(delay, window, [&] {
            const QImage img = window->grabWindow();
            img.save(snapshot);
            metric(QStringLiteral("snapshot: %1 (%2x%3)").arg(snapshot).arg(img.width()).arg(img.height()));
            app.quit();
        });
    }
    if (!selfTestOut.isEmpty()) {
        auto *test = new SelfTest(window, &audio, selfTestOut, &app);
        QObject::connect(test, &SelfTest::finished, &app, [&](int failed) { app.exit(failed); });
        QTimer::singleShot(300, test, &SelfTest::run);
    }
    if (!arg("--exit-after").isEmpty()) QTimer::singleShot(int(arg("--exit-after").toDouble() * 1000), &app, [&] {
        metric(memoryLine() + " (after " + arg("--exit-after") + " s)");
        app.quit();
    });
    QObject::connect(&app, &QCoreApplication::aboutToQuit, core, &Core::flush);
    QObject::connect(&app, &QCoreApplication::aboutToQuit, player, [&] {
        player->finishListen();
        player->saveSession();
        library->flush();
    });
    return app.exec();
}
