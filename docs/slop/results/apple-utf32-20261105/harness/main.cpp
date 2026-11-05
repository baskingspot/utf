// Interleaved A/B of Ghostty's two simdutf call sites (src/simd/vt.cpp's
// DecodeUTF8 and src/simd/base64.cpp's decode) against utf at a base
// revision and at this tree, in one process. Each round times every row on
// every arm back to back, in an order that rotates by row and round; round 0
// sizes the loops. Output is Go benchmark format, for benchstat -col /arm.
#include <simdutf.h>

#include <pthread.h>
#include <sys/qos.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <random>
#include <string>
#include <vector>

extern "C" size_t base_decode_utf8(const uint8_t*, size_t, uint32_t*);
extern "C" size_t new_decode_utf8(const uint8_t*, size_t, uint32_t*);
extern "C" ptrdiff_t base_b64_decode(const char*, size_t, char*);
extern "C" ptrdiff_t new_b64_decode(const char*, size_t, char*);
extern "C" size_t alt_decode_utf8(const uint8_t*, size_t, uint32_t*);
extern "C" ptrdiff_t alt_b64_decode(const char*, size_t, char*);
extern "C" size_t base_to_utf16(const uint8_t*, size_t, uint16_t*);
extern "C" size_t new_to_utf16(const uint8_t*, size_t, uint16_t*);
extern "C" size_t alt_to_utf16(const uint8_t*, size_t, uint16_t*);

// ---- Ghostty's code, verbatim apart from formatting ----
static size_t MaximalSubpart(const unsigned char* p, size_t len) {
  if (len == 0) return 0;
  unsigned char b0 = p[0];
  if (b0 < 0xC2 || b0 > 0xF4) return 1;
  size_t seq_len;
  unsigned char lo[3], hi[3];
  if (b0 <= 0xDF) { seq_len = 2; lo[0] = 0x80; hi[0] = 0xBF; }
  else if (b0 == 0xE0) { seq_len = 3; lo[0] = 0xA0; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; }
  else if (b0 <= 0xEC) { seq_len = 3; lo[0] = 0x80; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; }
  else if (b0 == 0xED) { seq_len = 3; lo[0] = 0x80; hi[0] = 0x9F; lo[1] = 0x80; hi[1] = 0xBF; }
  else if (b0 <= 0xEF) { seq_len = 3; lo[0] = 0x80; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; }
  else if (b0 == 0xF0) { seq_len = 4; lo[0] = 0x90; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; lo[2] = 0x80; hi[2] = 0xBF; }
  else if (b0 <= 0xF3) { seq_len = 4; lo[0] = 0x80; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; lo[2] = 0x80; hi[2] = 0xBF; }
  else { seq_len = 4; lo[0] = 0x80; hi[0] = 0x8F; lo[1] = 0x80; hi[1] = 0xBF; lo[2] = 0x80; hi[2] = 0xBF; }
  size_t valid = 1;
  for (size_t i = 0; i < seq_len - 1 && valid < len; i++) {
    unsigned char cb = p[valid];
    if (cb < lo[i] || cb > hi[i]) break;
    valid++;
  }
  return valid;
}

static size_t simdutf_decode_utf8(const uint8_t* input, size_t count, uint32_t* output) {
  if (count == 0) return 0;
  const char* in = reinterpret_cast<const char*>(input);
  size_t remaining = count;
  char32_t* out = reinterpret_cast<char32_t*>(output);
  while (remaining > 0) {
    auto r = simdutf::convert_utf8_to_utf32_with_errors(in, remaining, out);
    if (r.error == simdutf::SUCCESS) { out += r.count; break; }
    out += simdutf::count_utf8(in, r.count);
    const unsigned char* err_pos = reinterpret_cast<const unsigned char*>(in + r.count);
    size_t skip = r.count + MaximalSubpart(err_pos, remaining - r.count);
    *out++ = 0xFFFD;
    in += skip;
    remaining -= skip;
  }
  return static_cast<size_t>(out - reinterpret_cast<char32_t*>(output));
}

static ptrdiff_t simdutf_b64_decode(const char* input, size_t length, char* output) {
  simdutf::result r = simdutf::base64_to_binary(input, length, output);
  if (r.error) return -1;
  return r.count;
}
// ---- end Ghostty's code ----

static std::mt19937_64 rng(0xf00dface);
static uint64_t rnd(uint64_t n) { return rng() % n; }

static void put_cp(std::string& s, uint32_t cp) {
  if (cp < 0x80) s += char(cp);
  else if (cp < 0x800) { s += char(0xC0 | cp >> 6); s += char(0x80 | (cp & 63)); }
  else if (cp < 0x10000) { s += char(0xE0 | cp >> 12); s += char(0x80 | (cp >> 6 & 63)); s += char(0x80 | (cp & 63)); }
  else { s += char(0xF0 | cp >> 18); s += char(0x80 | (cp >> 12 & 63)); s += char(0x80 | (cp >> 6 & 63)); s += char(0x80 | (cp & 63)); }
}

static std::string random_utf8_input(size_t len) {
  std::string s;
  int style = rnd(6);
  while (s.size() < len) {
    switch (style) {
      case 0:
        s += rnd(20) == 0 ? char(rng()) : char(0x20 + rnd(95));
        break;
      case 1:
        switch (rnd(4)) {
          case 0: s += char(0x80 + rnd(0x40)); break;
          case 1: s += char(0xC0 + rnd(0x40)); break;
          default: s += char(0x20 + rnd(95));
        }
        break;
      case 2:
        s += char(rng());
        break;
      case 3: {
        uint32_t r = rnd(4);
        uint32_t cp = r == 0 ? rnd(0x80) : r == 1 ? 0x80 + rnd(0x780) : r == 2 ? 0x800 + rnd(0xF800) : 0x10000 + rnd(0x100000);
        if (cp >= 0xD800 && cp < 0xE000) cp = 'x';
        put_cp(s, cp);
        if (rnd(200) == 0) s[s.size() - 1 - rnd(std::min<size_t>(s.size(), 3))] = char(rng());
        break;
      }
      case 4: {  // runs of one length, as CJK and emoji text, rare ASCII and corruption
        uint32_t r = rnd(16);
        uint32_t cp = r == 0 ? 0x20 : r < 10 ? 0x4E00 + rnd(0x5000) : r < 12 ? 0x1F300 + rnd(0x300) : 0x400 + rnd(0x100);
        put_cp(s, cp);
        if (rnd(400) == 0) s[s.size() - 1 - rnd(std::min<size_t>(s.size(), 3))] = char(rng());
        break;
      }
      default: {
        std::string t;
        put_cp(t, 0x800 + rnd(0x10000));
        if (rnd(30) == 0) t.resize(t.size() - 1);
        s += t;
      }
    }
  }
  s.resize(len);
  return s;
}

static int difftest() {
  int failures = 0;
  std::vector<uint32_t> a(70000), b(70000);
  for (int iter = 0; iter < 300000; iter++) {
    size_t len = iter % 10 == 0 ? rnd(5000) : rnd(300);
    std::string s = random_utf8_input(len);
    auto in = reinterpret_cast<const uint8_t*>(s.data());
    size_t na = simdutf_decode_utf8(in, s.size(), a.data());
    size_t nb = new_decode_utf8(in, s.size(), b.data());
    if (na != nb || memcmp(a.data(), b.data(), na * 4) != 0) {
      if (failures++ < 5) fprintf(stderr, "decode mismatch len=%zu simdutf=%zu utf=%zu\n", s.size(), na, nb);
    }
  }
  printf("utf8 decode: 300000 random inputs, %d mismatches\n", failures);
  int b64fail = 0;
  const char* alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  for (int iter = 0; iter < 300000; iter++) {
    size_t n = iter % 10 == 0 ? rnd(20000) : rnd(400);
    std::string raw(n, 0);
    for (auto& c : raw) c = char(rng());
    std::string enc(simdutf::base64_length_from_binary(n), 0);
    simdutf::binary_to_base64(raw.data(), n, enc.data());
    int mode = rnd(6);
    if (mode == 1) while (!enc.empty() && enc.back() == '=') enc.pop_back();
    if (mode == 2 && !enc.empty()) enc[rnd(enc.size())] = "!-_=*\x80"[rnd(6)];
    if (mode == 3) for (int k = 0; k < 5; k++) enc.insert(rnd(enc.size() + 1), 1, " \n\r\t"[rnd(4)]);
    if (mode == 4 && !enc.empty()) enc.resize(rnd(enc.size()));
    if (mode == 5) for (auto& c : enc) if (rnd(50) == 0) c = alpha[rnd(64)];
    size_t m = enc.size() / 4 * 3 + 3;
    std::string oa(m + 64, 0), ob(m + 64, 0);
    ptrdiff_t ra = simdutf_b64_decode(enc.data(), enc.size(), oa.data());
    ptrdiff_t rb = new_b64_decode(enc.data(), enc.size(), ob.data());
    if (ra != rb || (ra > 0 && memcmp(oa.data(), ob.data(), ra) != 0)) {
      if (b64fail++ < 5) fprintf(stderr, "b64 mismatch mode=%d len=%zu simdutf=%td utf=%td\n", mode, enc.size(), ra, rb);
    }
    std::string ip = enc;
    ptrdiff_t ri = new_b64_decode(ip.data(), ip.size(), ip.data());
    if (ri != ra || (ra > 0 && memcmp(ip.data(), oa.data(), ra) != 0)) {
      if (b64fail++ < 5) fprintf(stderr, "b64 in-place mismatch mode=%d len=%zu\n", mode, enc.size());
    }
  }
  printf("base64 decode: 300000 random inputs, %d mismatches\n", b64fail);
  return failures + b64fail;
}

using Clock = std::chrono::steady_clock;

static std::string corpus(const char* name) {
  std::u32string base;
  if (!strcmp(name, "box")) base = U"│ ── ┌──┐ ██▓▒░ ├┤ └──┘ │  ⣿⣷⣦ 1.2G ▏";
  else if (!strcmp(name, "latin")) base = U"é déjà vu, où est la gare? Ça coûte trop cher. Über naïve façade ";
  else if (!strcmp(name, "cjk")) base = U"中文文本测试，终端模拟器需要快速解码。日本語のテキストも混ざっています。한국어 ";
  else if (!strcmp(name, "cjk3")) base = U"中文文本测试，终端模拟器需要快速解码。日本語のテキストも混ざっています。한국어";
  else if (!strcmp(name, "korean")) base = U"터미널 에뮬레이터는 텍스트를 빠르게 디코딩해야 합니다. 한국어 문장에는 공백이 많습니다. ";
  else if (!strcmp(name, "japanese")) base = U"端末エミュレータはテキストを高速にデコードする必要があります。Zigで書かれたutfライブラリを使います。";
  else if (!strcmp(name, "cyrillic")) base = U"Привет, мир! Это проверка декодирования текста в терминале. ";
  else if (!strcmp(name, "emoji")) base = U"🙂 🚀🔥 ok 👍🏽 ✅ 🎉 ";
  std::string out;
  while (out.size() < (1 << 17))
    for (char32_t c : base) put_cp(out, c);
  return out;
}

// ghostty-gen +utf8 (src/synthetic/Utf8.zig): each character's encoded
// length drawn by weight (1, 2, 3, 4 bytes), then a code point uniform over
// that length's range, a surrogate drawn again; `wide`, by weight with the
// lengths, a CJK ideograph from U+4E00 to U+9FFF; `space`, the chance of a
// space after each character. `mixed` is its default (all weights 1, ASCII
// from 0x00, so control characters and ESC), `four` four-byte only, `wide`
// ideographs only.
static std::string ghostty_gen(const char* name, size_t len) {
  std::mt19937_64 g(0x6768);
  double w[5] = {0, 1, 1, 1, 1}, space = 0;  // wide, one, two, three, four
  if (!strcmp(name, "gfour")) w[1] = w[2] = w[3] = 0;
  else if (!strcmp(name, "gwide")) { w[0] = 1; w[1] = w[2] = w[3] = w[4] = 0; }
  else if (!strcmp(name, "gwidesp")) { w[0] = 1; w[1] = w[2] = w[3] = w[4] = 0; space = 0.1; }
  std::discrete_distribution<int> pick(w, w + 5);
  std::string s;
  while (s.size() < len) {
    int k = pick(g);
    uint32_t cp;
    for (;;) {
      static const uint32_t lo[5] = {0x4E00, 0, 0x80, 0x800, 0x10000}, hi[5] = {0x9FFF, 0x7F, 0x7FF, 0xFFFF, 0x10FFFF};
      cp = lo[k] + g() % (hi[k] - lo[k] + 1);
      if (cp < 0xD800 || cp > 0xDFFF) break;
    }
    put_cp(s, cp);
    if (space > 0 && std::uniform_real_distribution<double>(0, 1)(g) < space) s += ' ';
  }
  return s;
}

static size_t trim_to(const std::string& s, size_t n) {
  while (n > 0 && (static_cast<unsigned char>(s[n]) & 0xC0) == 0x80) n--;
  return n;
}

// A buffer at the start of a page of its own.
static char* page_copy(const std::string& s) {
  void* p = nullptr;
  posix_memalign(&p, 16384, s.size() + 16384);
  memset(p, 0, s.size() + 16384);
  memcpy(p, s.data(), s.size());
  return static_cast<char*>(p);
}

struct Row {
  std::string op, input;
  size_t bytes;
  std::function<size_t()> arm[4];
  size_t iters[4];
};

static const char* arms[4] = {"simdutf", "base", "new", "alt"};
static const int NARMS = 4;

int main(int argc, char** argv) {
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  if (argc > 1 && !strcmp(argv[1], "test")) return difftest() ? 1 : 0;
  int rounds = argc > 2 ? atoi(argv[2]) : 10;
  const char* filter = argc > 3 ? argv[3] : "";
  double sample_ns = (getenv("BENCH_MS") ? atof(getenv("BENCH_MS")) : 20.0) * 1e6;

  std::vector<Row> rows;
  // Output 2 KiB past a page, as the repo's harness places it.
  static char* outbuf = nullptr;
  {
    void* p = nullptr;
    posix_memalign(&p, 16384, (1 << 20) * 4 + 16384);
    memset(p, 0, (1 << 20) * 4 + 16384);
    outbuf = static_cast<char*>(p) + 2048;
  }
  uint32_t* out32 = reinterpret_cast<uint32_t*>(outbuf);
  for (const char* name : {"box", "latin", "cjk", "cjk3", "korean", "japanese", "cyrillic", "emoji"}) {
    std::string text = corpus(name);
    const uint8_t* in = reinterpret_cast<const uint8_t*>(page_copy(text));
    for (size_t n : {16, 64, 256, 4096, 65536}) {
      size_t len = trim_to(text, n);
      Row r{"Utf8ToUtf32", std::string(name) + "-" + std::to_string(len), len, {}, {}};
      r.arm[0] = [=] { return simdutf_decode_utf8(in, len, out32); };
      r.arm[1] = [=] { return base_decode_utf8(in, len, out32); };
      r.arm[2] = [=] { return new_decode_utf8(in, len, out32); };
      r.arm[3] = [=] { return alt_decode_utf8(in, len, out32); };
      rows.push_back(r);
      uint16_t* out16 = reinterpret_cast<uint16_t*>(outbuf);
      Row u{"Utf8ToUtf16le", std::string(name) + "-" + std::to_string(len), len, {}, {}};
      // The vendored simdutf has no UTF-16: arm 0 is base again, so these
      // rows' ratios are base / arm.
      u.arm[0] = [=] { return base_to_utf16(in, len, out16); };
      u.arm[1] = [=] { return base_to_utf16(in, len, out16); };
      u.arm[2] = [=] { return new_to_utf16(in, len, out16); };
      u.arm[3] = [=] { return alt_to_utf16(in, len, out16); };
      rows.push_back(u);
    }
  }
  for (const char* name : {"gmixed", "gfour", "gwide", "gwidesp"}) {
    std::string text = ghostty_gen(name, 1 << 17);
    const uint8_t* in = reinterpret_cast<const uint8_t*>(page_copy(text));
    for (size_t n : {64, 256, 1024, 4096, 65536}) {
      size_t len = trim_to(text, n);
      Row r{"Utf8ToUtf32", std::string(name) + "-" + std::to_string(len), len, {}, {}};
      r.arm[0] = [=] { return simdutf_decode_utf8(in, len, out32); };
      r.arm[1] = [=] { return base_decode_utf8(in, len, out32); };
      r.arm[2] = [=] { return new_decode_utf8(in, len, out32); };
      r.arm[3] = [=] { return alt_decode_utf8(in, len, out32); };
      rows.push_back(r);
    }
  }
  {
    // 64 KiB of ghostty-gen's default output, Ghostty's read size, decoded
    // the way its stream does: up to each ESC, which with the character
    // after it goes to the parser instead.
    static std::string text = ghostty_gen("gmixed", 1 << 16);
    const uint8_t* in = reinterpret_cast<const uint8_t*>(page_copy(text));
    static std::vector<std::pair<size_t, size_t>> segs;
    size_t at = 0;
    for (size_t i = 0; i < text.size(); i++)
      if (text[i] == 0x1B) {
        segs.push_back({at, i - at});
        i++;
        while (i + 1 < text.size() && (static_cast<unsigned char>(text[i + 1]) & 0xC0) == 0x80) i++;
        at = i + 1;
      }
    if (at < text.size()) segs.push_back({at, text.size() - at});
    auto run = [=](size_t (*f)(const uint8_t*, size_t, uint32_t*)) {
      return [=] {
        size_t n = 0;
        for (auto [o, l] : segs) n += f(in + o, l, out32);
        return n;
      };
    };
    Row r{"Utf8ToUtf32", "gstream-" + std::to_string(segs.size()), text.size(), {}, {}};
    r.arm[0] = run(simdutf_decode_utf8);
    r.arm[1] = run(base_decode_utf8);
    r.arm[2] = run(new_decode_utf8);
    r.arm[3] = run(alt_decode_utf8);
    rows.push_back(r);
  }
  {
    static std::string tiny = std::string(64, 'a') + corpus("cjk");
    const uint8_t* in = reinterpret_cast<const uint8_t*>(page_copy(tiny));
    for (size_t len : {1, 8}) {
      Row r{"Utf8ToUtf32", "ascii-" + std::to_string(len), len, {}, {}};
      r.arm[0] = [=] { return simdutf_decode_utf8(in, len, out32); };
      r.arm[1] = [=] { return base_decode_utf8(in, len, out32); };
      r.arm[2] = [=] { return new_decode_utf8(in, len, out32); };
      r.arm[3] = [=] { return alt_decode_utf8(in, len, out32); };
      rows.push_back(r);
    }
  }
  for (size_t n : {48, 192, 3072, 3 << 16, 3 << 20}) {
    std::string raw(n, 0);
    for (auto& c : raw) c = char(rng());
    std::string enc(simdutf::base64_length_from_binary(n), 0);
    simdutf::binary_to_base64(raw.data(), n, enc.data());
    const char* in = page_copy(enc);
    size_t len = enc.size();
    Row r{"Base64Decode", "random-" + std::to_string(len), len, {}, {}};
    r.arm[0] = [=] { return (size_t)simdutf_b64_decode(in, len, outbuf); };
    r.arm[1] = [=] { return (size_t)base_b64_decode(in, len, outbuf); };
    r.arm[2] = [=] { return (size_t)new_b64_decode(in, len, outbuf); };
    r.arm[3] = [=] { return (size_t)alt_b64_decode(in, len, outbuf); };
    rows.push_back(r);
  }
  rows.erase(std::remove_if(rows.begin(), rows.end(),
                            [&](const Row& r) {
                              std::string name = r.op + "/" + r.input + "$", f = filter;
                              size_t at = 0;
                              for (;;) {
                                size_t comma = f.find(',', at);
                                std::string tok = f.substr(at, comma == std::string::npos ? std::string::npos : comma - at);
                                if (name.find(tok) != std::string::npos) return false;
                                if (comma == std::string::npos) return true;
                                at = comma + 1;
                              }
                            }),
             rows.end());

  printf("goos: darwin\ngoarch: arm64\ncpu: Apple M4 Pro\n");
  printf("# simdutf %s, implementation %s\n", SIMDUTF_VERSION, simdutf::get_active_implementation()->name().data());
  size_t sink = 0;
  // Check the arms agree, then size each arm's loop to the sample time.
  for (auto& r : rows) {
    size_t want = r.arm[0]();
    for (int a = 1; a < NARMS; a++)
      if (r.arm[a]() != want) { fprintf(stderr, "%s/%s: %s disagrees\n", r.op.c_str(), r.input.c_str(), arms[a]); return 1; }
    for (int a = 0; a < NARMS; a++) {
      size_t n = 1;
      for (;;) {
        auto t0 = Clock::now();
        for (size_t i = 0; i < n; i++) sink += r.arm[a]();
        double ns = std::chrono::duration<double, std::nano>(Clock::now() - t0).count();
        if (ns > sample_ns / 8) { r.iters[a] = std::max<size_t>(1, size_t(n * sample_ns / ns)); break; }
        n *= 2;
      }
    }
  }
  for (int round = 0; round < rounds; round++) {
    for (size_t j = 0; j < rows.size(); j++) {
      auto& r = rows[j];
      for (int i = 0; i < NARMS; i++) {
        int a = (round + j + i) % NARMS;
        size_t n = r.iters[a];
        auto t0 = Clock::now();
        for (size_t k = 0; k < n; k++) sink += r.arm[a]();
        double ns = std::chrono::duration<double, std::nano>(Clock::now() - t0).count() / n;
        printf("Benchmark%s/%s/arm=%s %zu %.2f ns/op %.2f MB/s\n", r.op.c_str(), r.input.c_str(), arms[a], n, ns,
               r.bytes / ns * 1000);
      }
    }
    fflush(stdout);
  }
  fprintf(stderr, "sink %zu\n", sink & 1);
  return 0;
}
