#include "SelfTest.h"
#include "CoreBridge.h"
#include "Typography.h"
#include "Glyph.h"
#include "AudioEngine.h"
#include "MediaSession.h"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QQuickItem>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QStyleHints>
#include <QTextStream>
#include <QTimer>
#include <QWheelEvent>
#include <memory>

namespace {
void after(int ms, QObject *ctx, std::function<void()> f) { QTimer::singleShot(ms, ctx, std::move(f)); }

/// Sends one wheel event to the window at the item's centre.
void wheel(QQuickWindow *w, QQuickItem *item, QPoint angle, QPoint pixel = {}) {
    const QPointF local(item->width() / 2, item->height() / 2);
    const QPointF pos = item->mapToScene(local);
    QWheelEvent ev(pos, w->mapToGlobal(pos.toPoint()), pixel, angle, Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false);
    QCoreApplication::sendEvent(w, &ev);
}
}

SelfTest::SelfTest(QQuickWindow *window, AudioEngine *audio, const QString &out, QObject *parent)
    : QObject(parent), m_window(window), m_audio(audio), m_out(out) {
    QFile::remove(m_out);

    // The core: loaded, the interface this build expects.
    m_steps << [this](auto next) {
        note("core");
        const QVariantMap v = Core::instance()->version();
        check(Core::instance()->compatible(), "core interface", QJsonDocument::fromVariant(v).toJson(QJsonDocument::Compact));
        check(Core::instance()->starterThemes().size() == 15, "15 starter themes", QString::number(Core::instance()->starterThemes().size()));
        check(Core::instance()->settings().size() > 50, "settings defaults", QString::number(Core::instance()->settings().size()) + " keys");
        const QVariantMap skin = Core::instance()->skin();
        check(skin.value("colors").toMap().size() == 18, "the core resolves the skin (18 colours)",
              QStringLiteral("glass %1, panel %2, content %3, backdrop %4").arg(skin.value("isGlass").toBool()).arg(skin.value("panelOpacity").toDouble())
                  .arg(skin.value("contentOpacity").toDouble()).arg(skin.value("backdrop").toString()));
        check(!Core::instance()->themes().isEmpty() && !Core::instance()->activeThemeID().isEmpty(), "theme library and active theme",
              QStringLiteral("%1 themes, active %2").arg(Core::instance()->themes().size()).arg(Core::instance()->activeTheme().value("name").toString()));
        check(Core::instance()->customize().contains("tokens") && Core::instance()->customize().contains("layout"), "customize state defaults");
        next();
    };

    // Type: every face the core names is registered under that PostScript name.
    m_steps << [this](auto next) {
        note("type");
        const QVariantMap faces = Type::instance()->registeredFaces();
        QStringList missing;
        for (const QVariant &f : Core::instance()->fonts())
            for (const QVariant &face : f.toMap().value("faces").toMap()) if (!faces.contains(face.toString())) missing << face.toString();
        check(missing.isEmpty(), "every bundled face resolves by PostScript name", missing.join(", "));
        check(!Type::instance()->symbolsPath().isEmpty(), "symbols face found");
        // The face rule: light by default, regular below 11 pt and for medium, bold for bold.
        Type *t = Type::instance();
        check(t->faceName(12, "regular") == "GeistMonoNF-Light" && t->faceName(10.5, "regular") == "GeistMonoNF"
              && t->faceName(12, "semibold") == "GeistMonoNF" && t->faceName(12, "bold") == "GeistMonoNF-Bold",
              "face rule (light ≥ 11 pt, regular below and for medium, bold)");
        // Metrics, for comparing with the Mac's numbers for the same text.
        for (const QString &fam : {QStringLiteral("geistMono"), QStringLiteral("inter")}) {
            const QFont f = t->font(12, "regular", fam);
            const QFontMetricsF m(f);
            note(QStringLiteral("  metrics %1 12pt light: ascent %2, descent %3, line %4, width of \"0123456789\" %5, of \"All Music\" %6")
                     .arg(fam).arg(m.ascent(), 0, 'f', 2).arg(m.descent(), 0, 'f', 2).arg(m.lineSpacing(), 0, 'f', 2)
                     .arg(m.horizontalAdvance("0123456789"), 0, 'f', 2).arg(m.horizontalAdvance("All Music"), 0, 'f', 2));
        }
        // What Text items actually lay out, per renderer, against the Mac's
        // CoreText advances (Geist Mono Light 12: digits 72.00, "All Music" 64.80;
        // Inter Light 12 tabular: "All Music" 50.63).
        if (QQmlEngine *engine = qmlEngine(m_window->contentItem()->childItems().value(0))) {
            for (const char *r : {"NativeRendering", "QtRendering", "CurveRendering"}) {
                QQmlComponent c(engine);
                c.setData(QStringLiteral("import QtQuick; import I2S; Item { property real digits: a.contentWidth; property real words: b.contentWidth; property real inter: d.contentWidth;"
                                         " Text { id: a; font: Type.font(12, 'regular', 'geistMono'); text: '0123456789'; renderType: Text.%1 }"
                                         " Text { id: b; font: Type.font(12, 'regular', 'geistMono'); text: 'All Music'; renderType: Text.%1 }"
                                         " Text { id: d; font: Type.font(12, 'regular', 'inter'); text: 'All Music'; renderType: Text.%1 } }").arg(r).toUtf8(), QUrl());
                std::unique_ptr<QObject> o(c.create());
                if (!o) { note("  layout " + QString(r) + ": " + c.errorString()); continue; }
                note(QStringLiteral("  layout %1: geist digits %2, geist \"All Music\" %3, inter \"All Music\" %4")
                         .arg(r).arg(o->property("digits").toDouble(), 0, 'f', 2).arg(o->property("words").toDouble(), 0, 'f', 2).arg(o->property("inter").toDouble(), 0, 'f', 2));
            }
        }
        next();
    };

    // Icons: every role in every pack draws an outline.
    m_steps << [this](auto next) {
        note("icons");
        const QVariantMap icons = Core::instance()->icons();
        int total = 0;
        QStringList missing;
        for (const QVariant &p : icons.value("packs").toList()) {
            const QVariantMap pack = p.toMap();
            const QVariantMap codes = pack.value("codes").toMap();
            for (auto it = codes.begin(); it != codes.end(); ++it) {
                ++total;
                if (GlyphItem::outline(it.value().toUInt()).isEmpty()) missing << pack.value("id").toString() + ":" + it.key();
            }
        }
        check(missing.isEmpty(), QStringLiteral("every pack's icons have outlines (%1)").arg(total), missing.mid(0, 12).join(", "));
        QStringList unresolved;
        for (const QVariant &r : icons.value("roles").toList())
            if (!Core::instance()->iconCode(r.toMap().value("role").toString())) unresolved << r.toMap().value("role").toString();
        check(unresolved.isEmpty(), "every role resolves in the chosen pack", unresolved.join(", "));
        next();
    };

    // Settings: a change is written through the core and reads back.
    m_steps << [this](auto next) {
        note("settings");
        Core *core = Core::instance();
        const double before = core->settings().value("glassTintStrength").toDouble();
        core->setSetting("glassTintStrength", 0.31);
        core->flush();
        QFile f(Core::supportDir() + "/defaults/com.meimei.player.appSettings.v1.json");
        const bool opened = f.open(QIODevice::ReadOnly);
        const QVariantMap stored = QJsonDocument::fromJson(f.readAll()).toVariant().toMap();
        check(opened && qFuzzyCompare(stored.value("glassTintStrength").toDouble(), 0.31) && stored.size() == core->settings().size(),
              "settings written whole and read back", f.fileName());
        core->setSetting("glassTintStrength", before);
        core->flush();
        next();
    };

    // Audio: gapless hand-over to the next track, the end, then the device idles.
    m_steps << [this](auto next) {
        note("audio");
        auto t = std::make_shared<QElapsedTimer>();
        auto advancedAt = std::make_shared<double>(-1);
        auto conns = std::make_shared<QList<QMetaObject::Connection>>();
        auto done = std::make_shared<bool>(false);
        *conns << connect(m_audio, &AudioEngine::advanced, this, [=](const QString &id) { if (id == "b") *advancedAt = t->elapsed() / 1000.0; });
        *conns << connect(m_audio, &AudioEngine::ended, this, [=] {
            *done = true;
            for (auto &c : *conns) disconnect(c);
            const double endedAt = t->elapsed() / 1000.0;
            check(*advancedAt > 1.7 && *advancedAt < 2.4, "gapless: the next track starts as the first ends", QStringLiteral("at %1 s (2.0 expected)").arg(*advancedAt, 0, 'f', 2));
            check(endedAt > 2.7 && endedAt < 3.5, "the queue ends after both tracks", QStringLiteral("at %1 s (3.0 expected)").arg(endedAt, 0, 'f', 2));
            check(!m_audio->isPlaying(), "stopped at the end");
            after(1800, this, [=] {
                check(!m_audio->deviceRunning(), "the output device closes when idle");
                next();
            });
        });
        const bool started = m_audio->start("gen:1:2", "a");
        m_audio->setNext("gen:1:1", "b");
        t->start();
        check(started && m_audio->isPlaying(), "a generated track starts");
        after(600, this, [=] {
            const double p = m_audio->currentTime();
            check(p > 0.35 && p < 0.8, "the playhead follows the device", QStringLiteral("%1 s after 0.6 s").arg(p, 0, 'f', 2));
            check(m_audio->deviceRunning(), "the device runs while playing");
        });
        after(6000, this, [=] {
            // Safety net if `ended` never comes.
            if (*done) return;
            *done = true;
            for (auto &c : *conns) disconnect(c);
            check(false, "the queue ends", "no end after 6 s");
            next();
        });
    };

    // Media keys: the session connects and reports what plays.
    m_steps << [this](auto next) {
        note("media keys");
        MediaSession *m = MediaSession::instance();
        check(m->active(), "media session connected to the window");
        m->setTrack("Glass Harbor", "Neon Rooms", "Static", "Neon Rooms");
        m->setPlaying(true);
        m->setTimeline(52, 240);
        const QString d = m->describe();
        check(d.startsWith("status playing") && d.contains("Glass Harbor"), "media session shows the track", d);
        m->setStopped();
        next();
    };

    // Wheel glide: one notch moves lines × line height, eased; quick notches add up.
    m_steps << [this](auto next) {
        note("wheel glide");
        QQuickItem *list = m_window->findChild<QQuickItem *>("glideList");
        if (!list) { check(false, "glide list found"); next(); return; }
        const int lines = QGuiApplication::styleHints()->wheelScrollLines();
        const double line = 21, notch = lines * line;
        list->setProperty("contentY", 0.0);
        wheel(m_window, list, QPoint(0, -120));
        after(60, this, [=] {
            const double mid = list->property("contentY").toDouble();
            check(mid > 0 && mid < notch, "a notch glides (part way after 60 ms)", QStringLiteral("%1 of %2").arg(mid, 0, 'f', 1).arg(notch));
            after(200, this, [=] {
                const double y = list->property("contentY").toDouble();
                check(qAbs(y - notch) < 0.5, "a notch moves the system's wheel lines × the line height", QStringLiteral("%1 (expected %2: %3 lines × %4)").arg(y, 0, 'f', 1).arg(notch).arg(lines).arg(line));
                wheel(m_window, list, QPoint(0, -120));
                after(30, this, [=] {
                    wheel(m_window, list, QPoint(0, -120));
                    after(30, this, [=] {
                        wheel(m_window, list, QPoint(0, -120));
                        after(260, this, [=] {
                            const double y2 = list->property("contentY").toDouble();
                            check(qAbs(y2 - 4 * notch) < 0.5, "notches in quick succession add to the target", QStringLiteral("%1 (expected %2)").arg(y2, 0, 'f', 1).arg(4 * notch));
                            wheel(m_window, list, QPoint(0, 30), QPoint(0, 0));
                            const double y3 = list->property("contentY").toDouble();
                            check(qAbs(y3 - (4 * notch - 30.0 / 120 * notch)) < 0.5, "fine-grained (touchpad) input moves at once",
                                  QStringLiteral("%1").arg(y3, 0, 'f', 1));
                            next();
                        });
                    });
                });
            });
        });
    };
}

void SelfTest::note(const QString &line) {
    QFile f(m_out);
    if (f.open(QIODevice::Append | QIODevice::Text)) QTextStream(&f) << line << "\n";
}

void SelfTest::check(bool ok, const QString &name, const QString &detail) {
    ok ? ++m_passed : ++m_failed;
    note(QStringLiteral("  %1 %2%3").arg(ok ? "✓" : "✗", name, detail.isEmpty() ? QString() : " — " + detail));
}

void SelfTest::run() {
    note("i2s windows self-test");
    step(0);
}

void SelfTest::step(int i) {
    if (i >= m_steps.size()) { finish(); return; }
    m_steps[i]([this, i] { QTimer::singleShot(0, this, [this, i] { step(i + 1); }); });
}

void SelfTest::finish() {
    note(m_failed ? QStringLiteral("%1 passed, %2 failed.").arg(m_passed).arg(m_failed) : QStringLiteral("All %1 checks passed.").arg(m_passed));
    emit finished(m_failed);
}
