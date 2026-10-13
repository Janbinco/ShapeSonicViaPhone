// Shapes: OBJ parsing, welding and normalization, pseudonormals for the SDF
// sign, the SDF octree, and sharp edge / corner detection.

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <tuple>

#include "internal.hpp"

using namespace ss;

static void set_error(char *err, size_t n, const char *msg) {
  if (err && n) std::snprintf(err, n, "%s", msg);
}

// ---- Construction -----------------------------------------------------------------

ss_shape *ss_shape_from_triangles(const float *xyz, size_t vertex_count, const uint32_t *indices,
                                  size_t triangle_count, char *err, size_t err_length) {
  auto *s = new ss_shape;
  s->verts.resize(vertex_count);
  for (size_t i = 0; i < vertex_count; i++) s->verts[i] = Vec3(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]);
  s->tris.reserve(triangle_count);
  for (size_t t = 0; t < triangle_count; t++) {
    Tri tri{{indices[3 * t], indices[3 * t + 1], indices[3 * t + 2]}};
    if (tri.v[0] >= vertex_count || tri.v[1] >= vertex_count || tri.v[2] >= vertex_count) {
      set_error(err, err_length, "Triangle index out of range.");
      delete s;
      return nullptr;
    }
    s->tris.push_back(tri);
  }
  if (s->tris.empty()) {
    set_error(err, err_length, "The model has no triangles.");
    delete s;
    return nullptr;
  }
  return s;
}

ss_shape *ss_shape_from_obj(const char *text, size_t length, char *err, size_t err_length) {
  std::vector<float> xyz;
  std::vector<uint32_t> idx;
  std::vector<long> poly;
  std::string line;
  size_t pos = 0, line_no = 0;
  char msg[160];
  while (pos < length) {
    size_t end = pos;
    while (end < length && text[end] != '\n' && text[end] != '\r') end++;
    line.assign(text + pos, end - pos);
    pos = end + 1;
    line_no++;
    const char *c = line.c_str();
    while (*c == ' ' || *c == '\t') c++;
    if (c[0] == 'v' && (c[1] == ' ' || c[1] == '\t')) {
      char *e;
      const char *p = c + 2;
      for (int k = 0; k < 3; k++) {
        float v = std::strtof(p, &e);
        if (e == p) {
          std::snprintf(msg, sizeof msg, "Bad vertex on line %zu.", line_no);
          set_error(err, err_length, msg);
          return nullptr;
        }
        xyz.push_back(v);
        p = e;
      }
    } else if (c[0] == 'f' && (c[1] == ' ' || c[1] == '\t')) {
      poly.clear();
      const char *p = c + 2;
      for (;;) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        char *e;
        long v = std::strtol(p, &e, 10);
        if (e == p) break;
        long nv = (long)(xyz.size() / 3);
        long i = v > 0 ? v - 1 : nv + v;  // negative indices are relative to the end
        if (v == 0 || i < 0 || i >= nv) {
          std::snprintf(msg, sizeof msg, "Bad face index on line %zu.", line_no);
          set_error(err, err_length, msg);
          return nullptr;
        }
        poly.push_back(i);
        p = e;
        while (*p && *p != ' ' && *p != '\t') p++;  // skip /vt/vn
      }
      for (size_t k = 2; k < poly.size(); k++) {
        idx.push_back((uint32_t)poly[0]);
        idx.push_back((uint32_t)poly[k - 1]);
        idx.push_back((uint32_t)poly[k]);
      }
    }
  }
  return ss_shape_from_triangles(xyz.data(), xyz.size() / 3, idx.data(), idx.size() / 3, err, err_length);
}

void ss_shape_destroy(ss_shape *shape) { delete shape; }

void ss_build_options_default(ss_build_options *o) {
  o->fit_size = 0.4f;  // the paper's study shapes fit a 0.4 m box
  o->leaf_size = 0.002f;
  o->margin = 0.5f;
  o->sharp_angle_deg = 30;
  o->threads = 0;
}

// ---- Build ---------------------------------------------------------------------------

static uint64_t edge_key(uint32_t a, uint32_t b) {
  if (a > b) std::swap(a, b);
  return (uint64_t(a) << 32) | b;
}

static void weld(ss_shape *s) {
  Vec3 lo = s->verts[0], hi = lo;
  for (Vec3 v : s->verts) lo = vmin(lo, v), hi = vmax(hi, v);
  float eps = std::fmax(length(hi - lo) * 1e-6f, 1e-12f);
  std::map<std::tuple<long long, long long, long long>, uint32_t> ids;
  std::vector<Vec3> out;
  std::vector<uint32_t> remap(s->verts.size());
  for (size_t i = 0; i < s->verts.size(); i++) {
    Vec3 v = s->verts[i];
    auto key = std::make_tuple(std::llround(v.x / eps), std::llround(v.y / eps), std::llround(v.z / eps));
    auto it = ids.find(key);
    if (it == ids.end()) {
      it = ids.emplace(key, (uint32_t)out.size()).first;
      out.push_back(v);
    }
    remap[i] = it->second;
  }
  std::vector<Tri> tris;
  tris.reserve(s->tris.size());
  for (Tri t : s->tris) {
    for (auto &v : t.v) v = remap[v];
    if (t.v[0] != t.v[1] && t.v[1] != t.v[2] && t.v[2] != t.v[0]) tris.push_back(t);
  }
  // Drop unreferenced vertices.
  std::vector<uint32_t> used(out.size(), UINT32_MAX);
  std::vector<Vec3> verts;
  for (Tri &t : tris)
    for (auto &v : t.v) {
      if (used[v] == UINT32_MAX) used[v] = (uint32_t)verts.size(), verts.push_back(out[v]);
      v = used[v];
    }
  s->verts = std::move(verts);
  s->tris = std::move(tris);
}

static void compute_normals(ss_shape *s) {
  const size_t nt = s->tris.size();
  // Orient outward: flip everything if the signed volume is negative.
  double volume = 0;
  for (const Tri &t : s->tris)
    volume += dot(s->verts[t.v[0]], cross(s->verts[t.v[1]], s->verts[t.v[2]]));
  if (volume < 0)
    for (Tri &t : s->tris) std::swap(t.v[1], t.v[2]);

  s->face_normals.resize(nt);
  for (size_t f = 0; f < nt; f++) {
    const Tri &t = s->tris[f];
    s->face_normals[f] = normalize(cross(s->verts[t.v[1]] - s->verts[t.v[0]], s->verts[t.v[2]] - s->verts[t.v[0]]));
  }
  std::unordered_map<uint64_t, std::pair<Vec3, int>> edges;
  edges.reserve(nt * 2);
  for (size_t f = 0; f < nt; f++)
    for (int e = 0; e < 3; e++) {
      auto &entry = edges[edge_key(s->tris[f].v[e], s->tris[f].v[(e + 1) % 3])];
      entry.first += s->face_normals[f];
      entry.second++;
    }
  s->watertight = true;
  for (auto &kv : edges)
    if (kv.second.second != 2) s->watertight = false;
  s->edge_normals.resize(3 * nt);
  for (size_t f = 0; f < nt; f++)
    for (int e = 0; e < 3; e++)
      s->edge_normals[3 * f + e] = edges[edge_key(s->tris[f].v[e], s->tris[f].v[(e + 1) % 3])].first;
  s->vertex_normals.assign(s->verts.size(), Vec3());
  for (size_t f = 0; f < nt; f++) {
    const Tri &t = s->tris[f];
    for (int k = 0; k < 3; k++) {
      Vec3 a = normalize(s->verts[t.v[(k + 1) % 3]] - s->verts[t.v[k]]);
      Vec3 b = normalize(s->verts[t.v[(k + 2) % 3]] - s->verts[t.v[k]]);
      float angle = std::acos(std::clamp(dot(a, b), -1.f, 1.f));
      s->vertex_normals[t.v[k]] += s->face_normals[f] * angle;
    }
  }
}

float ss_shape::signed_distance(Vec3 p) const {
  uint32_t t = 0;
  Vec3 q;
  int region = 0;
  float d = std::sqrt(bvh.closest(p, t, q, region));
  if (!(d > 0)) return 0;
  if (watertight) {
    Vec3 n = region == 0   ? face_normals[t]
             : region <= 3 ? edge_normals[3 * t + (region - 1)]
                           : vertex_normals[tris[t].v[region - 4]];
    return dot(p - q, n) < 0 ? -d : d;
  }
  // Not watertight: majority vote of ray parities along three skewed directions.
  static const Vec3 dirs[3] = {normalize(Vec3(0.5773f, 0.5774f, 0.5775f)), normalize(Vec3(-0.71f, 0.31f, 0.63f)),
                               normalize(Vec3(0.23f, -0.91f, 0.35f))};
  int inside = 0;
  for (const Vec3 &dir : dirs) inside += bvh.count_hits(p, dir) & 1;
  return inside >= 2 ? -d : d;
}

static void detect_features(ss_shape *s, float sharp_angle_deg);

int ss_shape_build(ss_shape *s, const ss_build_options *options, char *err, size_t err_length) {
  auto start = std::chrono::steady_clock::now();
  ss_build_options o;
  ss_build_options_default(&o);
  if (options) o = *options;
  if (s->tris.empty()) {
    set_error(err, err_length, "The model has no triangles.");
    return 1;
  }
  weld(s);
  if (s->tris.empty()) {
    set_error(err, err_length, "The model has only degenerate triangles.");
    return 1;
  }
  Vec3 lo = s->verts[0], hi = lo;
  for (Vec3 v : s->verts) lo = vmin(lo, v), hi = vmax(hi, v);
  Vec3 ext = hi - lo, center = (lo + hi) * 0.5f;
  float longest = std::fmax(ext.x, std::fmax(ext.y, ext.z));
  if (!(longest > 0)) {
    set_error(err, err_length, "The model is flat or empty.");
    return 1;
  }
  float scale = o.fit_size > 0 ? o.fit_size / longest : 1;
  for (Vec3 &v : s->verts) v = (v - center) * scale;
  s->lo = (lo - center) * scale;
  s->hi = (hi - center) * scale;

  compute_normals(s);
  s->bvh.build(s->verts, s->tris);
  ext = s->hi - s->lo;
  float half = 0.5f * std::fmax(ext.x, std::fmax(ext.y, ext.z)) + o.margin;
  s->sdf.mesh_lo_ = s->lo;
  s->sdf.mesh_hi_ = s->hi;
  s->sdf.build(
      Vec3(), half, o.leaf_size, o.threads,
      [s](Vec3 p) {
        uint32_t t;
        Vec3 q;
        int r;
        return std::sqrt(s->bvh.closest(p, t, q, r));
      },
      [s](Vec3 p) { return s->signed_distance(p); });
  detect_features(s, o.sharp_angle_deg);
  s->built = true;
  s->build_seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
  return 0;
}

// ---- Sharp features ------------------------------------------------------------------
//
// In the spirit of libigl's sharp_edges, as used in the paper: an edge is sharp
// if the angle between its two faces' normals exceeds the threshold (boundary
// and non-manifold edges count as sharp). A vertex is a corner if three or more
// sharp edges meet there, if a chain of sharp edges turns there by more than the
// threshold, or if it is a cone-like point: its angle deficit (2 pi minus the
// sum of its face angles) is large, as at the apex of a cone.

static constexpr float kCornerDeficitDeg = 70;
static constexpr float kFeatureCell = 0.02f;

static void detect_features(ss_shape *s, float sharp_angle_deg) {
  const float cos_sharp = std::cos(sharp_angle_deg * float(M_PI) / 180);
  const size_t nv = s->verts.size();
  std::unordered_map<uint64_t, std::vector<uint32_t>> edge_faces;
  edge_faces.reserve(s->tris.size() * 2);
  for (uint32_t f = 0; f < s->tris.size(); f++)
    for (int e = 0; e < 3; e++) edge_faces[edge_key(s->tris[f].v[e], s->tris[f].v[(e + 1) % 3])].push_back(f);

  std::vector<std::vector<uint32_t>> sharp_nbrs(nv);
  std::vector<char> boundary(nv, 0);
  s->sharp_edges.clear();
  for (auto &kv : edge_faces) {
    uint32_t a = uint32_t(kv.first >> 32), b = uint32_t(kv.first & 0xffffffffu);
    const auto &faces = kv.second;
    bool sharp;
    if (faces.size() != 2) {
      sharp = true;
      boundary[a] = boundary[b] = 1;
    } else {
      Vec3 n0 = s->face_normals[faces[0]], n1 = s->face_normals[faces[1]];
      sharp = dot(n0, n0) > 0 && dot(n1, n1) > 0 && dot(n0, n1) < cos_sharp;
    }
    if (!sharp) continue;
    s->sharp_edges.push_back(s->verts[a]);
    s->sharp_edges.push_back(s->verts[b]);
    sharp_nbrs[a].push_back(b);
    sharp_nbrs[b].push_back(a);
  }

  std::vector<float> angle_sum(nv, 0);
  for (const Tri &t : s->tris)
    for (int k = 0; k < 3; k++) {
      Vec3 a = normalize(s->verts[t.v[(k + 1) % 3]] - s->verts[t.v[k]]);
      Vec3 b = normalize(s->verts[t.v[(k + 2) % 3]] - s->verts[t.v[k]]);
      angle_sum[t.v[k]] += std::acos(std::clamp(dot(a, b), -1.f, 1.f));
    }

  s->corners.clear();
  const float deficit_threshold = kCornerDeficitDeg * float(M_PI) / 180;
  for (uint32_t v = 0; v < nv; v++) {
    const auto &nb = sharp_nbrs[v];
    bool corner = nb.size() >= 3;
    if (nb.size() == 2) {
      Vec3 a = normalize(s->verts[nb[0]] - s->verts[v]), b = normalize(s->verts[nb[1]] - s->verts[v]);
      // Straight chain: a = -b. Turning angle = pi - angle(a, b).
      corner = -dot(a, b) < cos_sharp;
    }
    if (!corner && !boundary[v] && std::fabs(2 * float(M_PI) - angle_sum[v]) > deficit_threshold) corner = true;
    if (corner) s->corners.push_back(s->verts[v]);
  }
  s->edge_grid.build_segments(s->sharp_edges, kFeatureCell);
  s->corner_grid.build_points(s->corners, kFeatureCell);
}

void ss_shape_detect_features(ss_shape *s, float sharp_angle_deg) {
  if (s->built) detect_features(s, sharp_angle_deg);
}

// ---- Queries ----------------------------------------------------------------------------

void ss_shape_get_info(const ss_shape *s, ss_shape_info *info) {
  std::memset(info, 0, sizeof *info);
  for (int i = 0; i < 3; i++) info->bbox_min[i] = s->lo[i], info->bbox_max[i] = s->hi[i];
  info->vertex_count = s->verts.size();
  info->triangle_count = s->tris.size();
  info->sharp_edge_count = s->sharp_edges.size() / 2;
  info->corner_count = s->corners.size();
  info->octree_nodes = s->sdf.node_count();
  info->octree_leaves = s->sdf.leaf_count();
  info->sdf_bytes = s->sdf.bytes();
  info->min_sdf = s->sdf.min_value();
  info->watertight = s->watertight;
  info->build_seconds = s->build_seconds;
}

const float *ss_shape_vertices(const ss_shape *s) { return &s->verts.data()->x; }
const uint32_t *ss_shape_triangles(const ss_shape *s) { return s->tris.data()->v; }
const float *ss_shape_sharp_edges(const ss_shape *s) { return s->sharp_edges.empty() ? nullptr : &s->sharp_edges.data()->x; }
const float *ss_shape_corners(const ss_shape *s) { return s->corners.empty() ? nullptr : &s->corners.data()->x; }

float ss_shape_sdf(const ss_shape *s, float x, float y, float z) { return s->sdf.sample(Vec3(x, y, z)); }
float ss_shape_sdf_exact(const ss_shape *s, float x, float y, float z) { return s->signed_distance(Vec3(x, y, z)); }
float ss_shape_edge_distance(const ss_shape *s, float x, float y, float z, float max_distance) {
  return s->edge_grid.nearest(Vec3(x, y, z), max_distance);
}
float ss_shape_corner_distance(const ss_shape *s, float x, float y, float z, float max_distance) {
  return s->corner_grid.nearest(Vec3(x, y, z), max_distance);
}
