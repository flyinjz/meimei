#pragma once
// Icons, as the Mac's Glyph view: a Nerd Font glyph's vector outline fitted
// into the item's square at 88% of the box on its longer side and centered,
// filled with `color`. `name` is an icon role (resolved through the user's
// icon pack and overrides, then the icon scale); `code` draws one code point
// directly, ignoring the icon theme, as the Mac's CodeGlyph.
#include <QQuickPaintedItem>
#include <QColor>
#include <QPainterPath>
#include <qqmlintegration.h>

class GlyphItem : public QQuickPaintedItem {
    Q_OBJECT
    QML_NAMED_ELEMENT(Glyph)
    Q_PROPERTY(QString name READ name WRITE setName NOTIFY nameChanged)
    Q_PROPERTY(uint code READ code WRITE setCode NOTIFY codeChanged)
    Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
public:
    explicit GlyphItem(QQuickItem *parent = nullptr);
    void paint(QPainter *painter) override;

    QString name() const { return m_name; }
    void setName(const QString &n);
    uint code() const { return m_code; }
    void setCode(uint c);
    QColor color() const { return m_color; }
    void setColor(const QColor &c);

    /// Loads the symbols face once for the process.
    static void setSymbolsFont(const QString &path);
    /// The outline of one code point in font units (cached); empty if the face lacks it.
    static QPainterPath outline(uint code);

signals:
    void nameChanged();
    void codeChanged();
    void colorChanged();

private:
    QString m_name;
    uint m_code = 0;
    QColor m_color = Qt::white;
};
