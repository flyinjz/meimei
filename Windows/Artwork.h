#pragma once
// Cover images for QML. image://art/<path>: the cover decoded off the main
// thread at the size shown. image://backdrop/<path>: the cover shrunk to
// 72 px, blurred (sigma 6) and desaturated to 0.9, like the Mac's album-art
// backdrop (BlurredArtwork).
#include <QQuickImageProvider>

class ArtProvider : public QQuickImageProvider {
public:
    ArtProvider() : QQuickImageProvider(QQuickImageProvider::Image, ForceAsynchronousImageLoading) {}
    QImage requestImage(const QString &id, QSize *size, const QSize &requested) override;
    static QImage load(const QString &path, int side);
};

class BackdropProvider : public QQuickImageProvider {
public:
    BackdropProvider() : QQuickImageProvider(QQuickImageProvider::Image, ForceAsynchronousImageLoading) {}
    QImage requestImage(const QString &id, QSize *size, const QSize &requested) override;
};
