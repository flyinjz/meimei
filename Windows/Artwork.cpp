#include "Artwork.h"
#include <QImageReader>
#include <QUrl>
#include <algorithm>
#include <cmath>
#include <vector>

QImage ArtProvider::load(const QString &path, int side) {
    QImageReader reader(path);
    reader.setAutoTransform(true);
    const QSize s = reader.size();
    if (s.isValid() && side > 0 && std::max(s.width(), s.height()) > side)
        reader.setScaledSize(s.scaled(side, side, Qt::KeepAspectRatioByExpanding));
    return reader.read();
}

QImage ArtProvider::requestImage(const QString &id, QSize *size, const QSize &requested) {
    const int side = std::max(16, std::max(requested.width(), requested.height()));
    QImage img = load(QUrl::fromPercentEncoding(id.toUtf8()), std::min(side, 1024));
    if (size) *size = img.size();
    return img;
}
namespace {
void blurChannel(std::vector<float> &v, int w, int h, const std::vector<float> &k) {
    const int r = int(k.size() / 2);
    std::vector<float> tmp(v.size());
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            float s = 0;
            for (int i = -r; i <= r; ++i) s += v[size_t(y * w + std::clamp(x + i, 0, w - 1))] * k[size_t(i + r)];
            tmp[size_t(y * w + x)] = s;
        }
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            float s = 0;
            for (int i = -r; i <= r; ++i) s += tmp[size_t(std::clamp(y + i, 0, h - 1) * w + x)] * k[size_t(i + r)];
            v[size_t(y * w + x)] = s;
        }
}
}

QImage BackdropProvider::requestImage(const QString &id, QSize *size, const QSize &) {
    const QImage small = ArtProvider::load(QUrl::fromPercentEncoding(id.toUtf8()), 256).scaled(72, 72, Qt::KeepAspectRatio, Qt::SmoothTransformation)
                             .convertToFormat(QImage::Format_ARGB32);
    const int w = small.width(), h = small.height();
    const double sigma = 6;
    std::vector<float> k;
    const int r = int(std::ceil(sigma * 3));
    float sum = 0;
    for (int i = -r; i <= r; ++i) { float v = float(std::exp(-(i * i) / (2 * sigma * sigma))); k.push_back(v); sum += v; }
    for (auto &v : k) v /= sum;
    std::vector<float> R(size_t(w * h)), G(R.size()), B(R.size());
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            const QRgb c = small.pixel(x, y);
            R[size_t(y * w + x)] = float(qRed(c)); G[size_t(y * w + x)] = float(qGreen(c)); B[size_t(y * w + x)] = float(qBlue(c));
        }
    blurChannel(R, w, h, k); blurChannel(G, w, h, k); blurChannel(B, w, h, k);
    QImage out(w, h, QImage::Format_RGB32);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            const size_t i = size_t(y * w + x);
            // CIColorControls saturation 0.9: mix toward luma.
            const float l = 0.2126f * R[i] + 0.7152f * G[i] + 0.0722f * B[i];
            auto mix = [&](float c) { return std::clamp(int(std::lround(l + (c - l) * 0.9f)), 0, 255); };
            out.setPixel(x, y, qRgb(mix(R[i]), mix(G[i]), mix(B[i])));
        }
    if (size) *size = out.size();
    return out;
}
