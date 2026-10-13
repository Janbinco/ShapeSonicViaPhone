/*
 * ShapeSonic core: platform-neutral geometry, sonification and audio mixing.
 *
 * Plain C API over a C++17 implementation so that it can be called from Swift
 * (iOS) and from Kotlin via JNI (Android). Nothing here depends on a platform
 * SDK. All lengths are in metres, in the shape's local frame.
 *
 * Threading: an ss_shape is not internally synchronized. Build it on any one
 * thread, then query it from one thread at a time (queries are const and may
 * run concurrently with each other). The mixer's set_* calls may come from any
 * thread while ss_mixer_render runs on the audio thread; render never locks or
 * allocates.
 */
#ifndef SHAPESONIC_H
#define SHAPESONIC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SS_HANDS 2   /* 0 = left, 1 = right */
#define SS_FINGERS 5 /* pentatonic slots per hand */

/* ---- Shapes --------------------------------------------------------------- */

typedef struct ss_shape ss_shape;

typedef struct {
  float fit_size;        /* > 0: scale uniformly so the longest bbox side is this; 0: keep units */
  float leaf_size;       /* finest SDF octree cell (default 0.002) */
  float margin;          /* SDF domain margin around the bbox (default 0.5, the guidance range) */
  float sharp_angle_deg; /* dihedral angle beyond which an edge is sharp (default 30) */
  int threads;           /* worker threads for the build; 0 = all cores */
} ss_build_options;

void ss_build_options_default(ss_build_options *options);

/* Parse Wavefront OBJ text (v and f records; polygons are fan-triangulated).
 * On failure returns NULL and writes a message into err. */
ss_shape *ss_shape_from_obj(const char *text, size_t length, char *err, size_t err_length);

/* A triangle soup: vertex_count xyz triples and triangle_count index triples. */
ss_shape *ss_shape_from_triangles(const float *xyz, size_t vertex_count, const uint32_t *indices,
                                  size_t triangle_count, char *err, size_t err_length);

/* Weld, normalize, and build the BVH, the SDF octree and the sharp features.
 * Takes on the order of a second; call it off the UI thread. Returns 0 on success. */
int ss_shape_build(ss_shape *shape, const ss_build_options *options, char *err, size_t err_length);

/* Re-detect sharp edges and corners with a new threshold (fast; mesh only). */
void ss_shape_detect_features(ss_shape *shape, float sharp_angle_deg);

void ss_shape_destroy(ss_shape *shape);

typedef struct {
  float bbox_min[3], bbox_max[3];
  size_t vertex_count, triangle_count;
  size_t sharp_edge_count, corner_count;
  size_t octree_nodes, octree_leaves, sdf_bytes;
  float min_sdf; /* most negative SDF value: minus the largest inscribed radius */
  int watertight;
  double build_seconds;
} ss_shape_info;

void ss_shape_get_info(const ss_shape *shape, ss_shape_info *info);

/* Geometry for visualization, valid until the next build or detect call. */
const float *ss_shape_vertices(const ss_shape *shape);      /* 3 * vertex_count */
const uint32_t *ss_shape_triangles(const ss_shape *shape);  /* 3 * triangle_count */
const float *ss_shape_sharp_edges(const ss_shape *shape);   /* 6 * sharp_edge_count (two endpoints) */
const float *ss_shape_corners(const ss_shape *shape);       /* 3 * corner_count */

/* Signed distance, negative inside: from the octree (fast), or exact (BVH). */
float ss_shape_sdf(const ss_shape *shape, float x, float y, float z);
float ss_shape_sdf_exact(const ss_shape *shape, float x, float y, float z);
/* Distance to the nearest sharp edge / corner; INFINITY if farther than max_distance. */
float ss_shape_edge_distance(const ss_shape *shape, float x, float y, float z, float max_distance);
float ss_shape_corner_distance(const ss_shape *shape, float x, float y, float z, float max_distance);

/* ---- Sonification ---------------------------------------------------------- */

/* Sound levels in [0, 1] for one hand. */
typedef struct {
  float guidance;
  float contact[SS_FINGERS];
  float edge;
  float corner;
} ss_hand_levels;

typedef struct {
  float x, y, z; /* shape-local position */
  int32_t hand;  /* 0 or 1 */
  int32_t slot;  /* 0..4: pentatonic note */
} ss_finger;

typedef struct {
  float sdf, edge, corner; /* measured distances (edge/corner INFINITY when out of range) */
} ss_finger_probe;

/* Ranges D of the volume falloff (supplemental Table 1 of the paper). */
typedef struct {
  float guidance_range; /* default 0.5 */
  float contact_range;  /* 0 = |min SDF| (default) */
  float edge_range;     /* default 0.02 */
  float corner_range;   /* default 0.02 */
} ss_sonify_params;

void ss_sonify_params_default(ss_sonify_params *params);

/* V(x) = a + b exp(-5x/D) for 0 <= x < D, else 0. */
float ss_falloff(float x, float range, float a, float b);

/* Measure each fingertip and compute both hands' levels. per_finger may be NULL. */
void ss_probe(const ss_shape *shape, const ss_sonify_params *params, const ss_finger *fingers,
              size_t finger_count, ss_hand_levels levels[SS_HANDS], ss_finger_probe *per_finger);

/* ---- Mixer ----------------------------------------------------------------- */

typedef enum {
  SS_SOUND_GUIDANCE = 0, /* stereo ambient loop, shared by both hands */
  SS_SOUND_CONTACT_LEFT,
  SS_SOUND_CONTACT_RIGHT,
  SS_SOUND_EDGE_LEFT,
  SS_SOUND_EDGE_RIGHT,
  SS_SOUND_CORNER_LEFT,
  SS_SOUND_CORNER_RIGHT,
  SS_SOUND_COUNT
} ss_sound;

typedef struct ss_mixer ss_mixer;

ss_mixer *ss_mixer_create(double output_sample_rate);
void ss_mixer_destroy(ss_mixer *mixer);

/* Copy a decoded sound in (1 or 2 channels), trimming silence at both ends.
 * Not real-time safe: load every sound before the first render. Returns 0 on success. */
int ss_mixer_load(ss_mixer *mixer, ss_sound sound, const float *const *channels, int channel_count,
                  size_t frames, double sample_rate);

/* Any thread, lock-free. */
void ss_mixer_set_levels(ss_mixer *mixer, const ss_hand_levels levels[SS_HANDS]);
void ss_mixer_set_master(ss_mixer *mixer, float gain);
void ss_mixer_set_output_rate(ss_mixer *mixer, double output_sample_rate);

/* Audio thread: render frames of non-interleaved stereo (overwrites the buffers). */
void ss_mixer_render(ss_mixer *mixer, float *left, float *right, size_t frames);

#ifdef __cplusplus
}
#endif

#endif /* SHAPESONIC_H */
