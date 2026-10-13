// Fingertips -> per-hand sound levels, following the paper's Method section
// and supplemental Table 1:
//
// | Sound    | plays when                       | x                       | a   | b   | D          |
// |----------|----------------------------------|-------------------------|-----|-----|------------|
// | Guidance | some fingertip of the hand is out| closest outside SDF     | 0   | 1   | 50 cm      |
// | Contact  | this fingertip is inside         | its depth, -SDF         | 0   | 0.8 | |min SDF|  |
// | Edge     | some fingertip near a sharp edge | closest edge distance   | 0.6 | 0.4 | 2 cm       |
// | Corner   | some fingertip near a corner     | closest corner distance | 0.6 | 0.4 | 2 cm       |

#include <limits>

#include "internal.hpp"

void ss_sonify_params_default(ss_sonify_params *p) {
  p->guidance_range = 0.5f;
  p->contact_range = 0;
  p->edge_range = 0.02f;
  p->corner_range = 0.02f;
}

float ss_falloff(float x, float range, float a, float b) {
  return x >= 0 && x < range ? a + b * std::exp(-5 * x / range) : 0;
}

void ss_probe(const ss_shape *shape, const ss_sonify_params *params, const ss_finger *fingers,
              size_t finger_count, ss_hand_levels levels[SS_HANDS], ss_finger_probe *per_finger) {
  ss_sonify_params p;
  ss_sonify_params_default(&p);
  if (params) p = *params;
  const float inf = std::numeric_limits<float>::infinity();
  float outside[SS_HANDS] = {inf, inf}, edge[SS_HANDS] = {inf, inf}, corner[SS_HANDS] = {inf, inf};
  for (int h = 0; h < SS_HANDS; h++) levels[h] = ss_hand_levels{};
  if (!shape || !shape->built) {
    for (size_t i = 0; per_finger && i < finger_count; i++) per_finger[i] = {inf, inf, inf};
    return;
  }
  const float contact_range = p.contact_range > 0 ? p.contact_range : std::fabs(shape->sdf.min_value());
  for (size_t i = 0; i < finger_count; i++) {
    const ss_finger &f = fingers[i];
    if (f.hand < 0 || f.hand >= SS_HANDS) continue;
    ss::Vec3 x(f.x, f.y, f.z);
    ss_finger_probe m;
    m.sdf = shape->sdf.sample(x);
    m.edge = shape->edge_grid.nearest(x, p.edge_range);
    m.corner = shape->corner_grid.nearest(x, p.corner_range);
    if (per_finger) per_finger[i] = m;
    if (m.sdf > 0)
      outside[f.hand] = std::fmin(outside[f.hand], m.sdf);
    else if (f.slot >= 0 && f.slot < SS_FINGERS)
      levels[f.hand].contact[f.slot] = ss_falloff(-m.sdf, contact_range, 0, 0.8f);
    edge[f.hand] = std::fmin(edge[f.hand], m.edge);
    corner[f.hand] = std::fmin(corner[f.hand], m.corner);
  }
  for (int h = 0; h < SS_HANDS; h++) {
    levels[h].guidance = ss_falloff(outside[h], p.guidance_range, 0, 1);
    levels[h].edge = ss_falloff(edge[h], p.edge_range, 0.6f, 0.4f);
    levels[h].corner = ss_falloff(corner[h], p.corner_range, 0.6f, 0.4f);
  }
}
