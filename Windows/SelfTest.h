#pragma once
// The Windows platform self-test (as the Mac's DebugHooks self-test): the
// core loads and matches, every bundled face resolves, every icon role in
// every pack has an outline, settings survive a round trip, audio plays
// gaplessly and goes idle, media keys connect, and the wheel glide moves
// the distance it should. Headless; results go to a file, one per line.
#include <QObject>
#include <QStringList>
#include <functional>

class QQuickWindow;
class AudioEngine;

class SelfTest : public QObject {
    Q_OBJECT
public:
    SelfTest(QQuickWindow *window, AudioEngine *audio, const QString &out, QObject *parent = nullptr);
    void run();

signals:
    void finished(int failed);

private:
    using Step = std::function<void(std::function<void()> next)>;
    void check(bool ok, const QString &name, const QString &detail = {});
    void note(const QString &line);
    void step(int i);
    void finish();

    QQuickWindow *m_window;
    AudioEngine *m_audio;
    QString m_out;
    QList<Step> m_steps;
    int m_failed = 0, m_passed = 0;
};
