#include "CoreBridge.h"
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QColor>
#include <QSaveFile>
#include <QStandardPaths>
#include "i2s_core.h"

namespace {
QByteArray take(char *p) { QByteArray b(p ? p : ""); i2s_free(p); return b; }
QVariant parse(const QByteArray &json) { return QJsonDocument::fromJson(json).toVariant(); }
// The Mac's UserDefaults keys, one file each.
const char *settingsKey = "com.meimei.player.appSettings.v1";
const char *themesKey = "com.meimei.player.themes.v1";
const char *activeThemeKey = "com.meimei.player.activeThemeID.v1";
const char *customizeKey = "com.meimei.player.customize.v2";
QByteArray json(const QVariant &v) { return QJsonDocument::fromVariant(v).toJson(QJsonDocument::Compact); }
const char *orNull(const QByteArray &b) { return b.isEmpty() ? nullptr : b.constData(); }

QString defaultsPath(const QString &key) { return Core::supportDir() + "/defaults/" + key + ".json"; }
QByteArray readDefaults(const QString &key) {
    QFile f(defaultsPath(key));
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}
void writeDefaults(const QString &key, const QByteArray &json) {
    QDir().mkpath(Core::supportDir() + "/defaults");
    QSaveFile f(defaultsPath(key));
    if (f.open(QIODevice::WriteOnly)) { f.write(json); f.commit(); }
}
}

Core *Core::instance() {
    static Core *core = new Core;
    return core;
}

QString Core::supportDir() {
    const QString env = qEnvironmentVariable("I2S_SUPPORT_DIR");
    if (!env.isEmpty()) return env;
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/MeimeiPlayer";
}

Core::Core(QObject *parent) : QObject(parent) {
    m_version = parse(take(i2s_core_version())).toMap();
    m_fonts = parse(take(i2s_fonts_json())).toList();
    m_icons = parse(take(i2s_icons_json())).toMap();
    m_starters = parse(take(i2s_theme_starters_json())).toList();
    m_categories = parse(take(i2s_theme_categories_json())).toStringList();
    m_layout = parse(take(i2s_customize_standard_layout_json())).toMap();
    for (const QVariant &p : m_icons.value("packs").toList()) {
        const QVariantMap pack = p.toMap();
        QHash<QString, uint> codes;
        const QVariantMap table = pack.value("codes").toMap();
        for (auto it = table.begin(); it != table.end(); ++it) codes.insert(it.key(), it.value().toUInt());
        m_packCodes.insert(pack.value("id").toString(), codes);
    }
    m_saveSoon.setSingleShot(true);
    m_saveSoon.setInterval(400);
    connect(&m_saveSoon, &QTimer::timeout, this, &Core::saveSettings);
    loadSettings();
}

bool Core::compatible() const { return m_version.value("interface").toInt() == interfaceVersion; }

void Core::loadSettings() {
    const QByteArray stored = readDefaults(settingsKey);
    m_settings = parse(take(i2s_settings_normalize_json(orNull(stored)))).toMap();
    // The active id is a plain string in the Mac's defaults; kept as a JSON string here.
    const QByteArray themes = readDefaults(themesKey);
    const QString active = parse(readDefaults(activeThemeKey)).toString();
    const QVariantMap lib = parse(take(i2s_themes_normalize_json(orNull(themes), active.isEmpty() ? nullptr : active.toUtf8().constData()))).toMap();
    m_themes = lib.value("themes").toList();
    m_activeThemeID = lib.value("activeID").toString();
    const QByteArray customize = readDefaults(customizeKey);
    m_customize = parse(take(i2s_customize_normalize_json(orNull(customize)))).toMap();
    rebuildIconTable();
    resolveSkin();
}

void Core::saveSettings() {
    // Round-trip through the core so what's written is always a valid payload.
    if (m_settingsDirty) writeDefaults(settingsKey, take(i2s_settings_normalize_json(json(m_settings).constData())));
    if (m_themesDirty) {
        writeDefaults(themesKey, json(m_themes));
        writeDefaults(activeThemeKey, json(m_activeThemeID));
    }
    if (m_customizeDirty) writeDefaults(customizeKey, take(i2s_customize_normalize_json(json(m_customize).constData())));
    m_settingsDirty = m_themesDirty = m_customizeDirty = false;
}

void Core::flush() {
    if (m_saveSoon.isActive()) { m_saveSoon.stop(); saveSettings(); }
}

void Core::setSetting(const QString &key, const QVariant &value) {
    if (m_settings.value(key) == value) return;
    m_settings.insert(key, value);
    if (key == "iconPack" || key == "iconOverrides") rebuildIconTable();
    m_settingsDirty = true;
    emit settingsChanged();
    resolveSkin();
    m_saveSoon.start();
}

void Core::resetSettings() {
    m_settings = parse(take(i2s_settings_normalize_json(nullptr))).toMap();
    rebuildIconTable();
    m_settingsDirty = true;
    emit settingsChanged();
    resolveSkin();
    m_saveSoon.start();
}

QVariantMap Core::activeTheme() const {
    for (const QVariant &t : m_themes) if (t.toMap().value("id").toString() == m_activeThemeID) return t.toMap();
    return m_themes.isEmpty() ? QVariantMap() : m_themes.first().toMap();
}

void Core::setActiveTheme(const QString &id) {
    if (id == m_activeThemeID) return;
    bool known = false;
    for (const QVariant &t : m_themes) known |= t.toMap().value("id").toString() == id;
    if (!known) return;
    m_activeThemeID = id;
    m_themesDirty = true;
    emit themesChanged();
    resolveSkin();
    m_saveSoon.start();
}

void Core::setCustomize(const QVariantMap &state) {
    const QVariantMap normalized = parse(take(i2s_customize_normalize_json(json(state).constData()))).toMap();
    if (normalized == m_customize) return;
    m_customize = normalized;
    m_customizeDirty = true;
    emit customizeChanged();
    resolveSkin();
    m_saveSoon.start();
}

QVariantMap Core::customizeDefaults() const {
    return parse(take(i2s_customize_normalize_json(nullptr))).toMap();
}

void Core::resolveSkin() {
    const QVariantMap theme = activeTheme();
    char *err = nullptr;
    QVariantMap skin = parse(take(i2s_skin_json(orNull(json(theme)), json(m_settings).constData(),
                                                m_peek ? nullptr : orNull(json(m_customize.value("tokens"))), theme.value("isAlbumReactive").toBool() ? 1 : 0, &err))).toMap();
    if (err) { qWarning("i2s: skin: %s", err); i2s_free(err); return; }
    // Colours as QColor, so QML binds them directly.
    QVariantMap colors;
    const QVariantMap raw = skin.value("colors").toMap();
    for (auto it = raw.begin(); it != raw.end(); ++it) {
        const QVariantMap c = it.value().toMap();
        colors.insert(it.key(), QColor::fromRgbF(c.value("r").toFloat(), c.value("g").toFloat(), c.value("b").toFloat(), c.value("a").toFloat()));
    }
    skin.insert("colors", colors);
    if (skin != m_skin) { m_skin = skin; emit skinChanged(); }
}

QVariantMap Core::generateTheme(const QVariantList &colors, const QString &name, bool light) {
    const QByteArray json = QJsonDocument::fromVariant(colors).toJson(QJsonDocument::Compact);
    char *err = nullptr;
    const QByteArray out = take(i2s_theme_generate_json(json.constData(), name.toUtf8().constData(), light ? 1 : 0, &err));
    if (err) { qWarning("i2s: %s", err); i2s_free(err); return {}; }
    return parse(out).toMap();
}

void Core::rebuildIconTable() {
    // The user's own choices, then the pack, then Material fills any gap.
    QHash<QString, uint> codes = m_packCodes.value("material");
    const QString pack = m_settings.value("iconPack").toString();
    if (pack != "material") {
        const auto table = m_packCodes.value(pack);
        for (auto it = table.begin(); it != table.end(); ++it) codes.insert(it.key(), it.value());
    }
    const QVariantMap overrides = m_settings.value("iconOverrides").toMap();
    for (auto it = overrides.begin(); it != overrides.end(); ++it) codes.insert(it.key(), it.value().toUInt());
    if (codes != m_activeCodes) { m_activeCodes = codes; emit iconsChanged(); }
}

uint Core::iconCode(const QString &role) const { return m_activeCodes.value(role, 0); }
