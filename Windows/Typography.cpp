#include "Typography.h"
#include "CoreBridge.h"
#include <QDir>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QRawFont>
#include <QScreen>
#include <QtEndian>

namespace {
/// The PostScript name (name table, id 6) of a font.
QString postScriptName(const QRawFont &raw) {
    const QByteArray t = raw.fontTable("name");
    if (t.size() < 6) return {};
    const auto u16 = [&](int at) { return at + 2 <= t.size() ? qFromBigEndian<quint16>(t.constData() + at) : quint16(0); };
    const int count = u16(2), strings = u16(4);
    QString mac;
    for (int i = 0; i < count; ++i) {
        const int r = 6 + i * 12;
        const int platform = u16(r), nameID = u16(r + 6), len = u16(r + 8), off = u16(r + 10);
        if (nameID != 6 || strings + off + len > t.size()) continue;
        const char *s = t.constData() + strings + off;
        if (platform == 3 || platform == 0) {
            QString out;
            for (int k = 0; k + 1 < len; k += 2) out += QChar(qFromBigEndian<quint16>(s + k));
            return out;
        }
        if (platform == 1) mac = QString::fromLatin1(s, len);
    }
    return mac;
}
}

Type *Type::instance() {
    static Type *type = new Type;
    return type;
}

Type::Type(QObject *parent) : QObject(parent) {
    if (QScreen *s = QGuiApplication::primaryScreen()) m_ptToPointSize = 72.0 / s->logicalDotsPerInch();
    for (const QVariant &v : Core::instance()->fonts()) {
        const QVariantMap f = v.toMap();
        m_families.insert(f.value("id").toString(), f);
    }
    followSettings();
    connect(Core::instance(), &Core::settingsChanged, this, &Type::followSettings);
    connect(Core::instance(), &Core::skinChanged, this, &Type::followSettings);
}

void Type::followSettings() {
    const QString f = Core::instance()->settings().value("fontFamily").toString();
    const qreal scale = Core::instance()->skin().value("textScale", 1.0).toDouble();
    bool change = false;
    if (!f.isEmpty() && f != m_family && m_families.contains(f)) { m_family = f; change = true; }
    if (scale > 0 && !qFuzzyCompare(scale, m_textScale)) { m_textScale = scale; change = true; }
    if (change) emit changed();
}

void Type::setTextScale(qreal s) {
    if (qFuzzyCompare(s, m_textScale)) return;
    m_textScale = s;
    emit changed();
}

int Type::registerFonts(const QString &dir) {
    int faces = 0;
    for (const QFileInfo &fi : QDir(dir).entryInfoList(QDir::Files)) {
        const int id = QFontDatabase::addApplicationFont(fi.absoluteFilePath());
        if (id < 0) continue;
        const QRawFont raw(fi.absoluteFilePath(), 16);
        if (!raw.isValid()) continue;
        const QString ps = postScriptName(raw);
        const QString family = QFontDatabase::applicationFontFamilies(id).value(0, raw.familyName());
        Face face{family, raw.styleName(), raw.weight(), raw.style() != QFont::StyleNormal};
        if (!ps.isEmpty()) m_faces.insert(ps, face);
        if (ps.startsWith("SymbolsNF")) { m_symbolsPath = fi.absoluteFilePath(); m_symbolsFamily = family; }
        ++faces;
    }
    return faces;
}

QString Type::faceName(qreal pt, const QString &weight, const QString &family) const {
    // The core's face rule (the Mac's AppFont.face), read as data so it costs
    // nothing per text: bold weights → bold, medium/semibold → regular,
    // anything else light, except below `regularBelow` points.
    const QVariantMap entry = m_families.value(family.isEmpty() ? m_family : family, m_families.value("geistMono"));
    const QVariantMap faces = entry.value("faces").toMap(), rule = entry.value("faceRule").toMap();
    if (rule.value("boldWeights").toStringList().contains(weight)) return faces.value("bold").toString();
    if (rule.value("regularWeights").toStringList().contains(weight)) return faces.value("regular").toString();
    if (pt < rule.value("regularBelow", 11).toDouble()) return faces.value("regular").toString();
    return faces.value(rule.value("otherwise", "light").toString()).toString();
}

QFont Type::face(const QString &postScriptName, qreal pt) const {
    const Face f = m_faces.value(postScriptName);
    QFont font(f.family);
    font.setStyleName(f.style);
    font.setWeight(QFont::Weight(f.weight));
    font.setPointSizeF(pt * m_ptToPointSize);
    // Mac text isn't hinted; match its glyph shapes and advances.
    font.setHintingPreference(QFont::PreferNoHinting);
    // Greyscale anti-aliasing, as macOS draws: ClearType's colour fringes
    // would make the same text look different (and change on glass).
    font.setStyleStrategy(QFont::NoSubpixelAntialias);
    font.setKerning(true);
    // Tabular figures everywhere, as `.monospacedDigit()` on the Mac.
    font.setFeature(QFont::Tag("tnum"), 1);
    return font;
}

QFont Type::font(qreal pt, const QString &weight, const QString &family) const {
    const qreal scaled = pt * m_textScale;
    return face(faceName(scaled, weight, family), scaled);
}

QVariantMap Type::registeredFaces() const {
    QVariantMap out;
    for (auto it = m_faces.begin(); it != m_faces.end(); ++it)
        out.insert(it.key(), QStringLiteral("%1|%2|%3").arg(it->family, it->style).arg(it->weight));
    return out;
}
