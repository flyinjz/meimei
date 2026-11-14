#include "Glyph.h"
#include "CoreBridge.h"
#include <QPainter>
#include <QRawFont>
#include <QHash>

namespace {
QRawFont &symbols() {
    static QRawFont font;
    return font;
}
}

GlyphItem::GlyphItem(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setAntialiasing(true);
    // A pack, override or icon-scale change redraws every icon.
    connect(Core::instance(), &Core::iconsChanged, this, [this] { update(); });
    connect(Core::instance(), &Core::settingsChanged, this, [this] { if (!m_name.isEmpty()) update(); });
}

void GlyphItem::setSymbolsFont(const QString &path) {
    symbols() = QRawFont(path, 64);
}

QPainterPath GlyphItem::outline(uint code) {
    static QHash<uint, QPainterPath> cache;
    auto hit = cache.constFind(code);
    if (hit != cache.constEnd()) return *hit;
    QPainterPath path;
    if (code && symbols().isValid()) {
        const char32_t cp = code;
        const auto indexes = symbols().glyphIndexesForString(QString::fromUcs4(&cp, 1));
        if (!indexes.isEmpty() && indexes[0] != 0) path = symbols().pathForGlyph(indexes[0]);
    }
    cache.insert(code, path);
    return path;
}

void GlyphItem::paint(QPainter *p) {
    const QRectF box(0, 0, width(), height());
    const bool themed = !m_name.isEmpty();
    const uint code = themed ? Core::instance()->iconCode(m_name) : m_code;
    const qreal scale = themed ? Core::instance()->settings().value("iconScale", 1.0).toDouble() : 1.0;
    const QPainterPath path = outline(code);
    p->setRenderHint(QPainter::Antialiasing);
    if (path.isEmpty()) {
        // As on the Mac: a square inset 20% when there's no outline.
        p->fillRect(box.adjusted(box.width() * 0.2, box.height() * 0.2, -box.width() * 0.2, -box.height() * 0.2), m_color);
        return;
    }
    const QRectF b = path.boundingRect();
    if (b.width() <= 0 || b.height() <= 0) return;
    // Qt's glyph paths already run y-down, so no flip (the Mac flips CoreText's).
    const qreal s = std::min(box.width() / b.width(), box.height() / b.height()) * 0.88 * scale;
    QTransform t;
    t.translate(box.center().x(), box.center().y());
    t.scale(s, s);
    t.translate(-b.center().x(), -b.center().y());
    p->fillPath(t.map(path), m_color);
}

void GlyphItem::setName(const QString &n) { if (n != m_name) { m_name = n; emit nameChanged(); update(); } }
void GlyphItem::setCode(uint c) { if (c != m_code) { m_code = c; emit codeChanged(); update(); } }
void GlyphItem::setColor(const QColor &c) { if (c != m_color) { m_color = c; emit colorChanged(); update(); } }
