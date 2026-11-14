#pragma once
// The app's type, matched to the Mac's AppFont: every bundled font file
// registered for this process, faces found by their PostScript names (the
// names the core's font list uses), sizes in Mac points (one point = one
// logical pixel), tabular figures, and the light/regular/bold face rule.
#include <QObject>
#include <QFont>
#include <QHash>
#include <QJSEngine>
#include <qqmlintegration.h>

class Type : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    /// The family chosen in settings (the core's font id, e.g. "geistMono").
    Q_PROPERTY(QString family READ family NOTIFY changed)
    /// The global text scale design token.
    Q_PROPERTY(qreal textScale READ textScale WRITE setTextScale NOTIFY changed)
    /// The Nerd Fonts symbols face, for text-drawn icons.
    Q_PROPERTY(QString symbolsFamily READ symbolsFamily CONSTANT)
public:
    static Type *instance();
    static Type *create(class QQmlEngine *, class QJSEngine *) { auto *p = instance(); QJSEngine::setObjectOwnership(p, QJSEngine::CppOwnership); return p; }

    /// Registers every file in `dir`. Returns how many faces were found.
    int registerFonts(const QString &dir);
    /// Path of the symbols face file (for icon outlines).
    QString symbolsPath() const { return m_symbolsPath; }

    QString family() const { return m_family; }
    qreal textScale() const { return m_textScale; }
    void setTextScale(qreal s);
    QString symbolsFamily() const { return m_symbolsFamily; }

    /// The font for text at `pt` Mac points: weight is "ultralight"…"black",
    /// as SwiftUI names them. `family` overrides the chosen family.
    Q_INVOKABLE QFont font(qreal pt, const QString &weight = QStringLiteral("regular"), const QString &family = QString()) const;
    /// A face by PostScript name at `pt` points, unscaled (previews).
    Q_INVOKABLE QFont face(const QString &postScriptName, qreal pt) const;
    /// Which PostScript face `font()` picks, for checks.
    Q_INVOKABLE QString faceName(qreal pt, const QString &weight, const QString &family = QString()) const;
    /// Every registered face: PostScript name → "family|style|weight".
    Q_INVOKABLE QVariantMap registeredFaces() const;

signals:
    void changed();

private:
    explicit Type(QObject *parent = nullptr);
    void followSettings();
    struct Face { QString family, style; int weight = 400; bool italic = false; };
    QHash<QString, Face> m_faces;          // PostScript name → registered face
    QHash<QString, QVariantMap> m_families; // core font id → its entry
    QString m_family = QStringLiteral("geistMono");
    QString m_symbolsPath, m_symbolsFamily;
    qreal m_textScale = 1;
    qreal m_ptToPointSize = 0.75;          // 72 / logical DPI
};
