// Real-time sonification mixer. The same graph as the web demo's audio.js:
//
// * Guidance: one ambient loop per hand, summed to mono and sent only to that
//   hand's ear; the left hand's copy is 2 semitones lower.
// * Contact: 5 loops per hand at major pentatonic rates (C D E G A); the
//   recordings are already hard-panned and differ in pitch between hands.
// * Edge (pluck) and corner (bell): re-triggered every kPluckInterval while
//   the hand is in range, through a per-hand gain that follows the distance.
//   Entering the range plucks immediately.
//
// Every voice runs all the time; levels only move gain targets, which are
// approached per sample with a one-pole filter (no clicks, no start/stop).
// Targets are atomics, so the render thread never locks or allocates.

#include <algorithm>
#include <atomic>
#include <cstring>

#include "internal.hpp"

namespace {

constexpr int kPentatonic[SS_FINGERS] = {0, 2, 4, 7, 9};
constexpr float kLeftGuidanceSemitones = -2;
constexpr double kPluckInterval = 0.45;  // s
constexpr int kPluckVoices = 6;          // per hand and kind; plucks last ~2 s
constexpr float kSilence = 1e-4f;
// Gain smoothing time constants (s). Contact is the most abrupt by design.
constexpr float kTauGuidance = 0.008f, kTauContact = 0.003f, kTauFeature = 0.006f, kTauMaster = 0.02f;
// Relative loudness of each family (the recordings differ in level).
constexpr float kMixGuidance = 0.5f, kMixContact = 0.45f, kMixFeature = 0.9f;

struct Buffer {
  std::vector<float> l, r;
  double rate = 48000;
  size_t frames() const { return l.size(); }
};

struct Smoothed {
  std::atomic<float> target{0};
  float value = 0;
};

struct Loop {
  const Buffer *buf = nullptr;
  double pos = 0, rate = 1;  // rate: playback-rate multiplier
};

struct Pluck {
  double pos = -1;  // < 0: idle
};

float semitones(float s) { return std::pow(2.f, s / 12); }

}  // namespace

struct ss_mixer {
  Buffer sounds[SS_SOUND_COUNT];
  std::atomic<double> out_rate{48000};
  Smoothed master;
  // Per hand: guidance, 5 contacts, edge, corner.
  Smoothed guidance[SS_HANDS], contact[SS_HANDS][SS_FINGERS], feature[SS_HANDS][2];
  Loop guidance_loop[SS_HANDS], contact_loop[SS_HANDS][SS_FINGERS];
  Pluck plucks[SS_HANDS][2][kPluckVoices];
  double since_pluck[SS_HANDS][2];  // seconds since the last pluck; infinity when out of range
  uint32_t seed = 12345;
};

ss_mixer *ss_mixer_create(double rate) {
  auto *m = new ss_mixer;
  m->out_rate = rate;
  m->master.target = 0.8f;
  m->master.value = 0.8f;
  for (int h = 0; h < SS_HANDS; h++) {
    m->guidance_loop[h].buf = &m->sounds[SS_SOUND_GUIDANCE];
    m->guidance_loop[h].rate = h == 0 ? semitones(kLeftGuidanceSemitones) : 1;
    for (int f = 0; f < SS_FINGERS; f++) {
      m->contact_loop[h][f].buf = &m->sounds[h == 0 ? SS_SOUND_CONTACT_LEFT : SS_SOUND_CONTACT_RIGHT];
      m->contact_loop[h][f].rate = semitones((float)kPentatonic[f]);
    }
    for (int k = 0; k < 2; k++) m->since_pluck[h][k] = INFINITY;
  }
  return m;
}

void ss_mixer_destroy(ss_mixer *m) { delete m; }

int ss_mixer_load(ss_mixer *m, ss_sound sound, const float *const *ch, int channels, size_t frames,
                  double rate) {
  if (sound < 0 || sound >= SS_SOUND_COUNT || channels < 1 || !ch || !ch[0]) return 1;
  const float *l = ch[0], *r = channels > 1 && ch[1] ? ch[1] : ch[0];
  auto loud = [&](size_t i) { return std::fabs(l[i]) > kSilence || std::fabs(r[i]) > kSilence; };
  size_t begin = 0, end = frames;
  while (begin < end && !loud(begin)) begin++;
  while (end > begin && !loud(end - 1)) end--;
  if (end <= begin) return 1;
  Buffer &b = m->sounds[sound];
  b.l.assign(l + begin, l + end);
  b.r.assign(r + begin, r + end);
  b.rate = rate;
  // Loops start at random offsets so the ten contact voices are not in phase.
  for (int h = 0; h < SS_HANDS; h++) {
    Loop *loops[1 + SS_FINGERS] = {&m->guidance_loop[h]};
    for (int f = 0; f < SS_FINGERS; f++) loops[1 + f] = &m->contact_loop[h][f];
    for (Loop *lp : loops)
      if (lp->buf == &b) {
        m->seed = m->seed * 1664525u + 1013904223u;
        lp->pos = double(m->seed >> 8) / double(1 << 24) * double(b.frames());
      }
  }
  return 0;
}

void ss_mixer_set_levels(ss_mixer *m, const ss_hand_levels levels[SS_HANDS]) {
  for (int h = 0; h < SS_HANDS; h++) {
    const ss_hand_levels &lv = levels[h];
    m->guidance[h].target.store(kMixGuidance * lv.guidance, std::memory_order_relaxed);
    for (int f = 0; f < SS_FINGERS; f++)
      m->contact[h][f].target.store(kMixContact * lv.contact[f], std::memory_order_relaxed);
    m->feature[h][0].target.store(kMixFeature * lv.edge, std::memory_order_relaxed);
    m->feature[h][1].target.store(kMixFeature * lv.corner, std::memory_order_relaxed);
  }
}

void ss_mixer_set_master(ss_mixer *m, float gain) { m->master.target.store(gain, std::memory_order_relaxed); }
void ss_mixer_set_output_rate(ss_mixer *m, double rate) { m->out_rate.store(rate); }

static inline void read_loop(Loop &lp, double step, float &l, float &r) {
  const Buffer &b = *lp.buf;
  const size_t n = b.frames();
  size_t i = (size_t)lp.pos;
  size_t j = i + 1 == n ? 0 : i + 1;
  float t = float(lp.pos - double(i));
  l = b.l[i] + (b.l[j] - b.l[i]) * t;
  r = b.r[i] + (b.r[j] - b.r[i]) * t;
  lp.pos += step;
  if (lp.pos >= double(n)) lp.pos -= double(n) * std::floor(lp.pos / double(n));
}

void ss_mixer_render(ss_mixer *m, float *left, float *right, size_t frames) {
  std::memset(left, 0, frames * sizeof(float));
  std::memset(right, 0, frames * sizeof(float));
  const double sr = m->out_rate.load(std::memory_order_relaxed);
  auto coef = [sr](float tau) { return 1 - std::exp(float(-1 / (tau * sr))); };
  const float kg = coef(kTauGuidance), kc = coef(kTauContact), kf = coef(kTauFeature), km = coef(kTauMaster);
  const double block = double(frames) / sr;

  // Pluck triggers, at block granularity (a few ms).
  for (int h = 0; h < SS_HANDS; h++)
    for (int k = 0; k < 2; k++) {
      const Buffer &b = m->sounds[h == 0 ? (k == 0 ? SS_SOUND_EDGE_LEFT : SS_SOUND_CORNER_LEFT)
                                         : (k == 0 ? SS_SOUND_EDGE_RIGHT : SS_SOUND_CORNER_RIGHT)];
      if (m->feature[h][k].target.load(std::memory_order_relaxed) <= 0) {
        m->since_pluck[h][k] = INFINITY;
        continue;
      }
      if (m->since_pluck[h][k] >= kPluckInterval && b.frames()) {
        // Take an idle voice, or else the one that has played longest.
        Pluck *voice = &m->plucks[h][k][0];
        for (Pluck &p : m->plucks[h][k]) {
          if (p.pos < 0) {
            voice = &p;
            break;
          }
          if (p.pos > voice->pos) voice = &p;
        }
        voice->pos = 0;
        m->since_pluck[h][k] = 0;
      } else {
        m->since_pluck[h][k] += block;
      }
    }

  for (int h = 0; h < SS_HANDS; h++) {
    float *ear = h == 0 ? left : right;
    // Guidance: mono sum to this hand's ear.
    Loop &g = m->guidance_loop[h];
    if (g.buf->frames()) {
      const double step = g.rate * g.buf->rate / sr;
      Smoothed &gain = m->guidance[h];
      const float target = gain.target.load(std::memory_order_relaxed);
      for (size_t i = 0; i < frames; i++) {
        float l, r;
        read_loop(g, step, l, r);
        gain.value += (target - gain.value) * kg;
        ear[i] += (l + r) * gain.value;
      }
    }
    for (int f = 0; f < SS_FINGERS; f++) {
      Loop &c = m->contact_loop[h][f];
      if (!c.buf->frames()) continue;
      const double step = c.rate * c.buf->rate / sr;
      Smoothed &gain = m->contact[h][f];
      const float target = gain.target.load(std::memory_order_relaxed);
      if (target == 0 && gain.value < 1e-6f) {  // silent: just advance the playhead
        gain.value = 0;
        c.pos = std::fmod(c.pos + step * double(frames), double(c.buf->frames()));
        continue;
      }
      for (size_t i = 0; i < frames; i++) {
        float l, r;
        read_loop(c, step, l, r);
        gain.value += (target - gain.value) * kc;
        left[i] += l * gain.value;
        right[i] += r * gain.value;
      }
    }
    for (int k = 0; k < 2; k++) {
      const Buffer &b = m->sounds[h == 0 ? (k == 0 ? SS_SOUND_EDGE_LEFT : SS_SOUND_CORNER_LEFT)
                                         : (k == 0 ? SS_SOUND_EDGE_RIGHT : SS_SOUND_CORNER_RIGHT)];
      Smoothed &gain = m->feature[h][k];
      const float target = gain.target.load(std::memory_order_relaxed);
      const double step = b.rate / sr;
      const size_t n = b.frames();
      for (Pluck &p : m->plucks[h][k]) {
        if (p.pos < 0) continue;
        float value = gain.value;  // every voice follows the same gain trajectory
        for (size_t i = 0; i < frames; i++) {
          size_t s = (size_t)p.pos;
          if (s + 1 >= n) {
            p.pos = -1;
            break;
          }
          float t = float(p.pos - double(s));
          value += (target - value) * kf;
          left[i] += (b.l[s] + (b.l[s + 1] - b.l[s]) * t) * value;
          right[i] += (b.r[s] + (b.r[s + 1] - b.r[s]) * t) * value;
          p.pos += step;
        }
      }
      // Advance the shared gain by one block whether or not a voice is playing.
      gain.value += (target - gain.value) * (1 - std::pow(1 - kf, float(frames)));
    }
  }

  const float target = m->master.target.load(std::memory_order_relaxed);
  for (size_t i = 0; i < frames; i++) {
    m->master.value += (target - m->master.value) * km;
    left[i] *= m->master.value;
    right[i] *= m->master.value;
  }
}
