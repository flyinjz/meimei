#pragma once
// The shared Swift core, as QML sees it. Everything here is a thin call
// through the core's C interface (Core/include/i2s_core.h): JSON in, JSON out, nothing
// reimplemented. Also owns the stored preferences (each Mac defaults key is
// one JSON file under the support folder), always read through the core.
#include <QObject>
#include <QVariant>
#include <QTimer>
#include <QJSEngine>
#include <qqmlintegration.h>

class Core : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantMap version READ version CONSTANT)
    Q_PROPERTY(QVariantList fonts READ fonts CONSTANT)
    Q_PROPERTY(QVariantMap icons READ icons CONSTANT)
    Q_PROPERTY(QVariantList starterThemes READ starterThemes CONSTANT)
    Q_PROPERTY(QStringList themeCategories READ themeCategories CONSTANT)
    Q_PROPERTY(QVariantMap standardLayout READ standardLayout CONSTANT)
    /// The app's settings (AppSettingsData), normalized by the core.
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY settingsChanged)
    /// The user's theme library and the active theme's id.
    Q_PROPERTY(QVariantList themes READ themes NOTIFY themesChanged)
    Q_PROPERTY(QString activeThemeID READ activeThemeID NOTIFY themesChanged)
    /// Customize state: styles, layout, tokens, workspaces, activeWorkspaceID.
    Q_PROPERTY(QVariantMap customize READ customize NOTIFY customizeChanged)
    /// What every view draws with, resolved by the core: "colors" (QColor
    /// each), isGlass, panelOpacity, contentOpacity, borderWidth, showTicks,
    /// tickLength, backdrop, gap, textScale.
    Q_PROPERTY(QVariantMap skin READ skin NOTIFY skinChanged)
    /// While true (⌥ held in customize mode) the skin resolves with the
    /// default design tokens: everything renders as originally designed.
    Q_PROPERTY(bool peekOriginal READ peekOriginal WRITE setPeekOriginal NOTIFY peekOriginalChanged)
public:
    static Core *instance();
    static Core *create(class QQmlEngine *, class QJSEngine *) { auto *p = instance(); QJSEngine::setObjectOwnership(p, QJSEngine::CppOwnership); return p; }

    /// Where the app keeps its files (%APPDATA%/MeimeiPlayer, or I2S_SUPPORT_DIR).
    static QString supportDir();
    /// The interface version this build was written against.
    static constexpr int interfaceVersion = 4;
    /// False when the core DLL is older or newer than this build expects.
    bool compatible() const;

    QVariantMap version() const { return m_version; }
    QVariantList fonts() const { return m_fonts; }
    QVariantMap icons() const { return m_icons; }
    QVariantList starterThemes() const { return m_starters; }
    QStringList themeCategories() const { return m_categories; }
    QVariantMap standardLayout() const { return m_layout; }
    QVariantMap settings() const { return m_settings; }
    QVariantList themes() const { return m_themes; }
    QString activeThemeID() const { return m_activeThemeID; }
    QVariantMap customize() const { return m_customize; }
    QVariantMap skin() const { return m_skin; }
    QVariantMap activeTheme() const;
    bool peekOriginal() const { return m_peek; }
    void setPeekOriginal(bool on) { if (on == m_peek) return; m_peek = on; emit peekOriginalChanged(); resolveSkin(); }

    Q_INVOKABLE void setActiveTheme(const QString &id);
    /// Replaces the customize state (the core normalizes it); saved shortly after.
    Q_INVOKABLE void setCustomize(const QVariantMap &state);
    /// The customize state as shipped (default tokens, standard layout, no styles).
    Q_INVOKABLE QVariantMap customizeDefaults() const;

    /// Changes one setting; written to disk shortly after.
    Q_INVOKABLE void setSetting(const QString &key, const QVariant &value);
    Q_INVOKABLE void resetSettings();
    /// A theme from at least 8 colours (24-bit RGB); empty map + error when it can't.
    Q_INVOKABLE QVariantMap generateTheme(const QVariantList &colors, const QString &name, bool light);
    /// The code point an icon role draws with the given pack and overrides
    /// (the user's choice, then the pack, then Material). 0 if none.
    Q_INVOKABLE uint iconCode(const QString &role) const;

    /// Saves pending changes now (on quit).
    void flush();

signals:
    void settingsChanged();
    void iconsChanged();
    void themesChanged();
    void customizeChanged();
    void skinChanged();
    void peekOriginalChanged();

private:
    explicit Core(QObject *parent = nullptr);
    void loadSettings();
    void saveSettings();
    void rebuildIconTable();
    void resolveSkin();

    QVariantMap m_version, m_icons, m_layout, m_settings, m_customize, m_skin;
    QVariantList m_themes;
    QString m_activeThemeID;
    bool m_settingsDirty = false, m_themesDirty = false, m_customizeDirty = false, m_peek = false;
    QVariantList m_fonts, m_starters;
    QStringList m_categories;
    QHash<QString, QHash<QString, uint>> m_packCodes;  // pack id → role → code
    QHash<QString, uint> m_activeCodes;                // resolved for the current settings
    QTimer m_saveSoon;
};
