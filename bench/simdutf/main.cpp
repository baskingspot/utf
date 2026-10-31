// bench-simdutf: the simdutf arm of `just bench-compare` (bench/README.md),
// simdutf from nixpkgs with its runtime dispatch, which picks the best
// kernel for this CPU, or the one SIMDUTF_FORCE_IMPLEMENTATION names (the
// check output names it on stderr).
//
// Usage, from the repository root, with the same contract as every arm:
//
//   bench-simdutf bench [OP...]   rows in the Go benchmark format
//   bench-simdutf check [OP...]   one checksum line per row
//
// OP is a name from bench/ops.tsv, which also gives each operation's row
// name, corpus directory, and output size; none means all. BENCHTIME_MS
// (default 100) is how long each row's timed loop runs, sized the way Go's
// testing.B sizes one.

#include <simdutf.h>

#include <algorithm>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace {

// What one call returns, for the checksum: validity, the bytes written, or
// a count.
struct Out {
  enum Kind { valid, len, count } kind;
  size_t value;
};

Out validity(bool v) { return {Out::valid, v}; }
Out written(size_t n) { return {Out::len, n}; }

using Fn = Out (*)(const char *in, size_t n, char *out);

// Runs F n times over the input and returns the nanoseconds it took. A
// template, so the loop calls F directly, as the other arms' loops do.
template <Fn F>
uint64_t timed(const char *in, size_t len, char *out, uint64_t n) {
  auto start = std::chrono::steady_clock::now();
  for (uint64_t i = 0; i < n; i++) {
    // The input escapes every iteration, so no call is hoisted out.
    asm volatile("" : : "g"(in) : "memory");
    Out r = F(in, len, out);
    asm volatile("" : : "g"(r.kind), "g"(r.value) : "memory");
  }
  auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - start)
                .count();
  return ns > 0 ? uint64_t(ns) : 1;
}

// The shapes of simdutf's functions, as templates over the function, so
// each wrapper calls it directly. S and D are the source and destination
// code units; lengths are in code units.

template <class S, bool (*F)(const S *, size_t) noexcept>
Out validate(const char *in, size_t n, char *) {
  return validity(F(reinterpret_cast<const S *>(in), n / sizeof(S)));
}

template <class S, simdutf::result (*F)(const S *, size_t) noexcept>
Out validate_err(const char *in, size_t n, char *) {
  return validity(F(reinterpret_cast<const S *>(in), n / sizeof(S)).error ==
                  simdutf::SUCCESS);
}

template <class S, class D, simdutf::result (*F)(const S *, size_t, D *) noexcept>
Out checked(const char *in, size_t n, char *out) {
  auto r = F(reinterpret_cast<const S *>(in), n / sizeof(S),
             reinterpret_cast<D *>(out));
  if (r.error != simdutf::SUCCESS)
    return validity(false);
  return written(r.count * sizeof(D));
}

template <class S, class D, size_t (*F)(const S *, size_t, D *) noexcept>
Out valid(const char *in, size_t n, char *out) {
  return written(F(reinterpret_cast<const S *>(in), n / sizeof(S),
                   reinterpret_cast<D *>(out)) *
                 sizeof(D));
}

template <class S, size_t (*F)(const S *, size_t) noexcept>
Out length(const char *in, size_t n, char *) {
  return {Out::count, F(reinterpret_cast<const S *>(in), n / sizeof(S))};
}

// simdutf has no checked UTF-16 byte swap: validate, then swap.
template <simdutf::result (*V)(const char16_t *, size_t) noexcept>
Out swap_checked(const char *in, size_t n, char *out) {
  auto src = reinterpret_cast<const char16_t *>(in);
  if (V(src, n / 2).error != simdutf::SUCCESS)
    return validity(false);
  simdutf::change_endianness_utf16(src, n / 2, reinterpret_cast<char16_t *>(out));
  return written(n);
}

Out swap_valid(const char *in, size_t n, char *out) {
  simdutf::change_endianness_utf16(reinterpret_cast<const char16_t *>(in), n / 2,
                                   reinterpret_cast<char16_t *>(out));
  return written(n);
}

template <simdutf::base64_options O>
Out base64_encode(const char *in, size_t n, char *out) {
  return written(simdutf::binary_to_base64(in, n, out, O));
}

template <simdutf::base64_options O, simdutf::last_chunk_handling_options L>
Out base64_decode(const char *in, size_t n, char *out) {
  auto r = simdutf::base64_to_binary(in, n, out, O, L);
  if (r.error != simdutf::SUCCESS)
    return validity(false);
  return written(r.count);
}

struct Impl {
  Fn run;
  uint64_t (*timed)(const char *, size_t, char *, uint64_t);
};

template <Fn F> constexpr Impl impl() { return {F, timed<F>}; }

using namespace simdutf;
using c16 = char16_t;
using c32 = char32_t;

// Each operation in bench/ops.tsv, by name. Latin-1 cannot be invalid, so
// simdutf has one form for conversions from it, which both rows time.
const std::map<std::string, Impl> impls = {
    {"validate-ascii", impl<validate<char, validate_ascii>>()},
    {"validate-ascii-err", impl<validate_err<char, validate_ascii_with_errors>>()},
    {"validate-utf8", impl<validate<char, validate_utf8>>()},
    {"validate-utf8-err", impl<validate_err<char, validate_utf8_with_errors>>()},
    {"validate-utf16le", impl<validate<c16, validate_utf16le>>()},
    {"validate-utf16le-err", impl<validate_err<c16, validate_utf16le_with_errors>>()},
    {"validate-utf16be", impl<validate<c16, validate_utf16be>>()},
    {"validate-utf16be-err", impl<validate_err<c16, validate_utf16be_with_errors>>()},
    {"validate-utf32", impl<validate<c32, validate_utf32>>()},
    {"validate-utf32-err", impl<validate_err<c32, validate_utf32_with_errors>>()},

    {"utf8-to-utf16le", impl<checked<char, c16, convert_utf8_to_utf16le_with_errors>>()},
    {"valid-utf8-to-utf16le", impl<valid<char, c16, convert_valid_utf8_to_utf16le>>()},
    {"utf8-to-utf16be", impl<checked<char, c16, convert_utf8_to_utf16be_with_errors>>()},
    {"valid-utf8-to-utf16be", impl<valid<char, c16, convert_valid_utf8_to_utf16be>>()},
    {"utf8-to-utf32", impl<checked<char, c32, convert_utf8_to_utf32_with_errors>>()},
    {"valid-utf8-to-utf32", impl<valid<char, c32, convert_valid_utf8_to_utf32>>()},
    {"utf8-to-latin1", impl<checked<char, char, convert_utf8_to_latin1_with_errors>>()},
    {"valid-utf8-to-latin1", impl<valid<char, char, convert_valid_utf8_to_latin1>>()},

    {"utf16le-to-utf8", impl<checked<c16, char, convert_utf16le_to_utf8_with_errors>>()},
    {"valid-utf16le-to-utf8", impl<valid<c16, char, convert_valid_utf16le_to_utf8>>()},
    {"utf16le-to-utf16be", impl<swap_checked<validate_utf16le_with_errors>>()},
    {"valid-utf16le-to-utf16be", impl<swap_valid>()},
    {"utf16le-to-utf32", impl<checked<c16, c32, convert_utf16le_to_utf32_with_errors>>()},
    {"valid-utf16le-to-utf32", impl<valid<c16, c32, convert_valid_utf16le_to_utf32>>()},
    {"utf16le-to-latin1", impl<checked<c16, char, convert_utf16le_to_latin1_with_errors>>()},
    {"valid-utf16le-to-latin1", impl<valid<c16, char, convert_valid_utf16le_to_latin1>>()},

    {"utf16be-to-utf8", impl<checked<c16, char, convert_utf16be_to_utf8_with_errors>>()},
    {"valid-utf16be-to-utf8", impl<valid<c16, char, convert_valid_utf16be_to_utf8>>()},
    {"utf16be-to-utf16le", impl<swap_checked<validate_utf16be_with_errors>>()},
    {"valid-utf16be-to-utf16le", impl<swap_valid>()},
    {"utf16be-to-utf32", impl<checked<c16, c32, convert_utf16be_to_utf32_with_errors>>()},
    {"valid-utf16be-to-utf32", impl<valid<c16, c32, convert_valid_utf16be_to_utf32>>()},
    {"utf16be-to-latin1", impl<checked<c16, char, convert_utf16be_to_latin1_with_errors>>()},
    {"valid-utf16be-to-latin1", impl<valid<c16, char, convert_valid_utf16be_to_latin1>>()},

    {"utf32-to-utf8", impl<checked<c32, char, convert_utf32_to_utf8_with_errors>>()},
    {"valid-utf32-to-utf8", impl<valid<c32, char, convert_valid_utf32_to_utf8>>()},
    {"utf32-to-utf16le", impl<checked<c32, c16, convert_utf32_to_utf16le_with_errors>>()},
    {"valid-utf32-to-utf16le", impl<valid<c32, c16, convert_valid_utf32_to_utf16le>>()},
    {"utf32-to-utf16be", impl<checked<c32, c16, convert_utf32_to_utf16be_with_errors>>()},
    {"valid-utf32-to-utf16be", impl<valid<c32, c16, convert_valid_utf32_to_utf16be>>()},
    {"utf32-to-latin1", impl<checked<c32, char, convert_utf32_to_latin1_with_errors>>()},
    {"valid-utf32-to-latin1", impl<valid<c32, char, convert_valid_utf32_to_latin1>>()},

    {"latin1-to-utf8", impl<valid<char, char, convert_latin1_to_utf8>>()},
    {"valid-latin1-to-utf8", impl<valid<char, char, convert_latin1_to_utf8>>()},
    {"latin1-to-utf16le", impl<valid<char, c16, convert_latin1_to_utf16le>>()},
    {"valid-latin1-to-utf16le", impl<valid<char, c16, convert_latin1_to_utf16le>>()},
    {"latin1-to-utf16be", impl<valid<char, c16, convert_latin1_to_utf16be>>()},
    {"valid-latin1-to-utf16be", impl<valid<char, c16, convert_latin1_to_utf16be>>()},
    {"latin1-to-utf32", impl<valid<char, c32, convert_latin1_to_utf32>>()},
    {"valid-latin1-to-utf32", impl<valid<char, c32, convert_latin1_to_utf32>>()},

    {"utf16-from-utf8", impl<length<char, utf16_length_from_utf8>>()},
    {"utf16-from-utf32", impl<length<c32, utf16_length_from_utf32>>()},
    {"utf8-from-utf16le", impl<length<c16, utf8_length_from_utf16le>>()},
    {"utf8-from-utf16be", impl<length<c16, utf8_length_from_utf16be>>()},
    {"utf8-from-utf32", impl<length<c32, utf8_length_from_utf32>>()},
    {"utf8-from-latin1", impl<length<char, utf8_length_from_latin1>>()},
    {"count-utf8", impl<length<char, count_utf8>>()},
    {"count-utf16le", impl<length<c16, count_utf16le>>()},
    {"count-utf16be", impl<length<c16, count_utf16be>>()},

    {"base64-encode", impl<base64_encode<base64_default>>()},
    {"base64-encode-url", impl<base64_encode<base64_url>>()},
    {"base64-decode", impl<base64_decode<base64_default, loose>>()},
    {"base64-decode-url", impl<base64_decode<base64_url, loose>>()},
    {"base64-decode-strict", impl<base64_decode<base64_default, strict>>()},
    {"base64-decode-partial", impl<base64_decode<base64_default, stop_before_partial>>()},
    {"base64-decode-mime", impl<base64_decode<base64_default, loose>>()},
};

void fail(const std::string &message) {
  std::fprintf(stderr, "bench-simdutf: %s\n", message.c_str());
  std::exit(1);
}

// An operation from bench/ops.tsv.
struct Op {
  std::string arg, row, dir;
  size_t num, den; // output bytes per input byte
  size_t out_len(size_t n) const { return num == 0 ? 0 : n * num / den + 64; }
};

std::vector<Op> read_ops() {
  std::ifstream file("bench/ops.tsv");
  if (!file)
    fail("open bench/ops.tsv (run from the repository root)");
  std::vector<Op> ops;
  for (std::string line; std::getline(file, line);) {
    if (line.empty() || line[0] == '#')
      continue;
    std::istringstream fields(line);
    Op op;
    std::string out;
    std::getline(fields, op.arg, '\t');
    std::getline(fields, op.row, '\t');
    std::getline(fields, op.dir, '\t');
    std::getline(fields, out, '\t');
    auto slash = out.find('/');
    op.num = std::stoul(out.substr(0, slash));
    op.den = slash == std::string::npos ? 1 : std::stoul(out.substr(slash + 1));
    ops.push_back(op);
  }
  for (const auto &[arg, _] : impls) {
    if (std::none_of(ops.begin(), ops.end(), [&](const Op &op) { return op.arg == arg; }))
      fail("operation " + arg + " is not in bench/ops.tsv");
  }
  return ops;
}

struct Input {
  std::string name;
  std::vector<char> data;
};

// Every file in bench/corpus-gen/<dir>, smallest first, then by name.
std::vector<Input> load(const std::string &dir) {
  namespace fs = std::filesystem;
  fs::path path = fs::path("bench/corpus-gen") / dir;
  std::error_code ec;
  fs::directory_iterator it(path, ec);
  if (ec)
    fail("open " + path.string() + ": " + ec.message() + " (run `just bench-corpus`)");
  std::vector<Input> inputs;
  for (const auto &entry : it) {
    // Read at the file's size, so the buffer is never grown and copied.
    std::vector<char> data(entry.file_size());
    std::ifstream(entry.path(), std::ios::binary)
        .read(data.data(), std::streamsize(data.size()));
    inputs.push_back({entry.path().filename().string(), std::move(data)});
  }
  std::sort(inputs.begin(), inputs.end(), [](const Input &a, const Input &b) {
    if (a.data.size() != b.data.size())
      return a.data.size() < b.data.size();
    return a.name < b.name;
  });
  return inputs;
}

uint64_t fnv1a(const char *p, size_t n) {
  uint64_t h = 0xcbf29ce484222325ull;
  for (size_t i = 0; i < n; i++)
    h = (h ^ static_cast<unsigned char>(p[i])) * 0x100000001b3ull;
  return h;
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2 ||
      (std::strcmp(argv[1], "bench") != 0 && std::strcmp(argv[1], "check") != 0)) {
    std::fprintf(stderr, "usage: bench-simdutf bench|check [OP...]\n");
    return 2;
  }
  bool check = std::strcmp(argv[1], "check") == 0;
  std::vector<Op> ops = read_ops();
  std::vector<std::string> wanted(argv + 2, argv + argc);
  for (const auto &w : wanted) {
    if (std::none_of(ops.begin(), ops.end(), [&](const Op &op) { return w == op.arg; })) {
      std::fprintf(stderr, "bench-simdutf: unknown operation %s\n", w.c_str());
      return 2;
    }
  }
  uint64_t goal = 100'000'000;
  if (const char *ms = std::getenv("BENCHTIME_MS"))
    goal = std::strtoull(ms, nullptr, 10) * 1'000'000;
  if (check) {
    auto name = simdutf::get_active_implementation()->name();
    std::fprintf(stderr, "bench-simdutf: simdutf %s, kernel %.*s\n",
                 SIMDUTF_VERSION, int(name.size()), name.data());
  }

  for (const Op &op : ops) {
    if (!wanted.empty() &&
        std::find(wanted.begin(), wanted.end(), op.arg) == wanted.end())
      continue;
    auto found = impls.find(op.arg);
    if (found == impls.end()) {
      std::printf("# SKIP Benchmark%s: simdutf has no equivalent\n", op.row.c_str());
      continue;
    }
    const Impl &f = found->second;
    for (Input &in : load(op.dir)) {
      // Aligned for any code unit, and left uninitialized, as the other
      // arms' buffers are, so only the pages written count in RSS.
      std::unique_ptr<char32_t[]> buf(new char32_t[op.out_len(in.data.size()) / 4 + 1]);
      char *out = reinterpret_cast<char *>(buf.get());
      const char *data = in.data.data();
      size_t len = in.data.size();
      if (check) {
        Out r = f.run(data, len, out);
        switch (r.kind) {
        case Out::valid:
          std::printf("%s/%s\tvalid=%s\n", op.row.c_str(), in.name.c_str(),
                      r.value ? "true" : "false");
          break;
        case Out::count:
          std::printf("%s/%s\tcount=%zu\n", op.row.c_str(), in.name.c_str(), r.value);
          break;
        case Out::len:
          std::printf("%s/%s\tlen=%zu fnv=%016" PRIx64 "\n", op.row.c_str(),
                      in.name.c_str(), r.value, fnv1a(out, r.value));
          break;
        }
        continue;
      }
      // Go's testing.B loop sizing: grow n until a run takes the goal.
      const uint64_t max_n = 1'000'000'000;
      uint64_t n = 1;
      uint64_t ns = f.timed(data, len, out, n);
      while (ns < goal && n < max_n) {
        uint64_t last = n;
        uint64_t next = uint64_t((unsigned __int128)goal * last / ns);
        next += next / 5;
        n = std::min({std::max(next, last + 1), 100 * last, max_n});
        ns = f.timed(data, len, out, n);
      }
      std::printf("Benchmark%s/%s\t%" PRIu64 "\t%.2f ns/op\t%.2f MB/s\n",
                  op.row.c_str(), in.name.c_str(), n, double(ns) / double(n),
                  double(len) * double(n) * 1e3 / double(ns));
      std::fflush(stdout);
    }
  }
  return 0;
}
