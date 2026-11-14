/*
 * i2s core: the C interface the Qt app calls (Windows, later Linux).
 * Implemented in Swift; the core is built as a shared library (I2SCore).
 *
 * Rules for every function:
 * - Strings in and out are UTF-8. Every char* the core returns belongs to
 *   the caller and must be freed with i2s_free, never with anything else.
 * - Structured data is JSON text. Dates in JSON are milliseconds since 1970
 *   (UTC); UUIDs are uppercase strings. Tracks passed in have the shape of
 *   the "tracks" array in the app's library.json.
 * - Handles are not thread-safe: use each one from a single thread.
 * - On failure a function returns NULL (or non-zero) and, when `error` is
 *   not NULL, sets *error to a message the caller frees with i2s_free.
 * - i2s_core_version reports "interface"; it changes whenever a function's
 *   meaning or a JSON shape changes. Check it at startup.
 */
#ifndef I2S_CORE_H
#define I2S_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void  i2s_free(char *p);

/* {"interface": 4, "history": "I2SH 1"} */
char *i2s_core_version(void);

/* Runs the core's checks in scratch_dir, printing each result to stdout.
   Returns the number that failed; -1 in release builds. */
int32_t i2s_core_check(const char *scratch_dir);

/* ---- Listening history (sealed, signed, append-only) ---- */

typedef struct i2s_history i2s_history;

/* Opens or starts the history in dir. Keys are files in dir until the
   platform secret store and TPM key are wired in. */
i2s_history *i2s_history_open(const char *dir, char **error);
void         i2s_history_close(i2s_history *h);

/* {"accepted","rejected","implausible","gaps","trustedPrefix","clean",
    "account","device","created","hardwareKey"} */
char   *i2s_history_report_json(i2s_history *h);

/* JSON array of every verified listen, oldest first. A listen:
   {"id","trackID","trackKey","title","artist","album","albumArtist",
    "trackDuration","startedAt","endedAt","heardSeconds","device"} */
char   *i2s_history_listens_json(i2s_history *h);

/* This installation's device id (record it in each new listen). */
char   *i2s_history_device(i2s_history *h);

/* Seals one listen (a listen JSON object). 0 on success; 1 with *error set
   when it can't be real, the clock reads earlier than the latest listen,
   the JSON is malformed (the message names the field), or the write failed. */
int32_t i2s_history_append_json(i2s_history *h, const char *listen_json, char **error);

/* 1 if hearing `heard` seconds of a `duration`-second track is a listen
   (half the track or 4 minutes; tracks of 30 s or more), else 0. */
int32_t i2s_listen_counts(double heard, double duration);

/* Records a listen of a library track (interface 4): `heard` audible seconds
   between started_at and ended_at (seconds since 1970). The core builds the
   listen (track key, artist, this device), seals it and counts the play in
   the library. 0 = recorded, 2 = too short to count, 1 = error (*error). */
typedef struct i2s_library i2s_library;
int32_t i2s_history_record_track(i2s_history *h, i2s_library *l, const char *track_id,
                                 double started_at, double ended_at, double heard, char **error);

/* ---- Profile ---- */

/* range: 0 = 7 days, 1 = 30 days, 2 = 90 days, 3 = 12 months, 4 = all time.
   tracks_json: the library's tracks (may be NULL or empty). Returns every
   statistic the profile page shows, as one JSON object. */
char *i2s_profile_stats_json(i2s_history *h, const char *tracks_json, int32_t range, char **error);

/* ---- Themes, settings, fonts, icons (interface 2) ----
   Themes use the app's stored shape: {"id","name","category",
   "isAlbumReactive","bgVoid",...}, every colour a 24-bit RGB integer. */

/* The built-in themes in catalog order (JSON array of themes). */
char *i2s_theme_starters_json(void);

/* Category order for the theme list (JSON array of strings). */
char *i2s_theme_categories_json(void);

/* A theme from at least 8 colours (colors_json: JSON array of 24-bit RGB
   integers); light != 0 for a light theme. NULL with *error when too few. */
char *i2s_theme_generate_json(const char *colors_json, const char *name, int32_t light, char **error);

/* Settings read leniently (unknown or bad keys fall back to defaults) and
   written back whole. Pass NULL for the defaults. */
char *i2s_settings_normalize_json(const char *settings_json);

/* The main window's standard pane layout (customize layout format). */
char *i2s_customize_standard_layout_json(void);

/* Bundled type families: [{"id","label","note","monospaced",
   "faces":{"light","regular","bold"}, "faceRule":{"regularBelow","regularWeights",
   "boldWeights","otherwise"}}], faces as PostScript names. */
char *i2s_fonts_json(void);

/* {"roles":[{"role","name","usedFor"}],"packs":[{"id","label","codes":{role:code}}]} */
char *i2s_icons_json(void);

/* Times the history with `count` listens in scratch_dir (works in release):
   {"listens","fullCheckListens","appendMs","readMs","fullCheckMs"}. */
char *i2s_core_bench_history(const char *scratch_dir, int32_t count);

/* ---- Skin, stored themes, customize state, faces (interface 3) ---- */

/* The skin every view draws with. theme_json: the active theme (stored
   shape; NULL = first starter). settings_json, tokens_json: stored settings
   and DesignTokens (NULL = defaults). live_cover != 0 for the live cover
   theme (pass the cover's accent colours in theme_json). Returns
   {"colors":{name:{"r","g","b","a"}}, "isGlass","allowsBackdropBleed",
    "panelOpacity","contentOpacity","borderWidth","showTicks","tickLength",
    "backdrop","gap","textScale"}; colours are sRGB 0..1. */
char *i2s_skin_json(const char *theme_json, const char *settings_json, const char *tokens_json,
                    int32_t live_cover, char **error);

/* Stored theme list made usable + the active id: {"themes":[...],"activeID"}.
   Either argument may be NULL. */
char *i2s_themes_normalize_json(const char *stored_json, const char *active_id);

/* Customize state (styles, layout, tokens, workspaces, activeWorkspaceID)
   read the app's way; unreadable or NULL gives the defaults. */
char *i2s_customize_normalize_json(const char *state_json);

/* The PostScript face for weight ("light","regular","medium","semibold",
   "bold","heavy","black",...) at size points in family ("geistMono", ...). */
char *i2s_font_face(const char *family, double size, const char *weight);

/* ---- Lyrics (interface 3) ---- */

/* {"synced": bool, "lines":[{"id","time","text"}]} from .lrc or plain text. */
char   *i2s_lyrics_read_json(const char *raw);

/* Index of the line sung at `time` (offset added) given the synced lines'
   start times in order; -1 before the first. */
int32_t i2s_lyrics_line_at(const double *times, int32_t count, double time);

/* ---- Equalizer (interface 3) ---- */

char *i2s_eq_profiles_json(void);                       /* built-in profiles */
char *i2s_eq_normalize_json(const char *state_json);    /* NULL = defaults */
/* Total gain in dB at each frequency of hz_json (JSON array of numbers). */
char *i2s_eq_response_json(const char *state_json, const char *hz_json);
/* A profile from parametric EQ text (AutoEQ / Equalizer APO), or NULL + *error. */
char *i2s_eq_parse_json(const char *text, const char *name, char **error);
/* The state as parametric EQ text. */
char *i2s_eq_export(const char *state_json);

/* ---- Library (interface 3) ---- */

typedef struct i2s_library i2s_library;

/* Opens library.json (missing = empty). Play counts in the file are ignored. */
i2s_library *i2s_library_open(const char *path, char **error);
void         i2s_library_close(i2s_library *l);
/* Every track in library order (library.json shape, dates seconds since 2001). */
char   *i2s_library_tracks_json(i2s_library *l);
char   *i2s_library_playlists_json(i2s_library *l);
/* Play counts and last-played from the history's verified listens. 0 = ok. */
int32_t i2s_library_apply_history(i2s_library *l, i2s_history *h);
/* JSON array of indices into the track list for a source ("all", "liked",
   "artist:Name", "genre:Name", "playlist:UUID", "recentlyAdded",
   "recentlyPlayed", "mostPlayed", ...), after filter_text and, when sort_key
   is not NULL/empty, the column sort ("title","artist","album","genre",
   "format","track","year","time","plays","quality"). */
char   *i2s_library_view_json(i2s_library *l, const char *source_key, const char *filter_text,
                              const char *sort_key, int32_t ascending, char **error);
/* [{"key","title","artist","year","artworkFilePath","trackCount","duration"}] */
char   *i2s_library_albums_json(i2s_library *l);

/* ---- Library changes (interface 4) ---- */

/* Adds tracks read from files (library.json track shape, JSON array); files
   already in the library are skipped; library order kept; tracks without a
   cover take their album's. Returns the number added, or -1 + *error. */
int32_t i2s_library_add_tracks_json(i2s_library *l, const char *tracks_json, char **error);
/* JSON array of the file paths already in the library. */
char   *i2s_library_file_paths_json(i2s_library *l);
/* ids_json: JSON array of track ids. */
void    i2s_library_set_liked(i2s_library *l, const char *ids_json, int32_t liked);
/* One more play for a track, last played at `at` (seconds since 1970). */
void    i2s_library_record_play(i2s_library *l, const char *track_id, double at);
/* Removes tracks from the library and every playlist (files untouched). */
void    i2s_library_remove_tracks(i2s_library *l, const char *ids_json);
/* Adds the starter smart playlists (Hi-Res, Recently Added, Unplayed) if missing. */
void    i2s_library_seed_starter_playlists(i2s_library *l);
/* Playlist changes: {"op":"create","name","trackIDs"}, {"op":"rename","id","name"},
   {"op":"delete","id"}, {"op":"add"|"remove","id","trackIDs"},
   {"op":"move","id","trackIDs","index"}. Returns the playlist id or NULL + *error. */
char   *i2s_library_playlist_edit_json(i2s_library *l, const char *op_json, char **error);
/* Writes library.json atomically. 0 = ok, else 1 + *error. */
int32_t i2s_library_save(i2s_library *l, const char *path, char **error);
/* The table's rows: the view (as i2s_library_view_json) grouped by group_by
   ("none","album","albumArtist","genre","year"):
   [{"t":index,"s":stripe} | {"h":title,"d":detail}]. */
char   *i2s_library_rows_json(i2s_library *l, const char *source_key, const char *filter_text,
                              const char *sort_key, int32_t ascending, const char *group_by, char **error);

#ifdef __cplusplus
}
#endif

#endif
