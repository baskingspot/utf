// Command bench-go is the Go arm of `just bench-compare` (bench/README.md):
// the standard library's unicode/utf8, unicode/utf16, and encoding/base64.
//
// Usage, from the repository root, with the same contract as every arm:
//
//	bench-go bench [OP...]   rows in the Go benchmark format
//	bench-go check [OP...]   one checksum line per row
//
// OP is validate-utf8, validate-utf8-err, utf8-to-utf16le, utf16le-to-utf8,
// base64-encode, or base64-decode; none means all. BENCHTIME_MS (default
// 100) is how long each row's timed loop runs; Go's own testing.Benchmark
// sizes it.
//
// The standard library has no UTF-8 validator that reports a position, so
// both validation operations time utf8.Valid. It has no slice-to-slice
// transcoder either: the conversions decode one rune at a time and append
// it to a preallocated buffer, which is how a Go program avoids allocating.
package main

import (
	"encoding/base64"
	"encoding/binary"
	"flag"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

const corpus = "bench/corpus-gen"

// out is what one call returns, for the checksum: validity, or the bytes
// written.
type out struct {
	valid bool
	n     int // -1 for a validation result
}

type input struct {
	name  string
	bytes []byte
	units []uint16
}

type op struct {
	arg, row, dir string
	outLen        func(int) int
	run           func(in *input, out8 []byte, out16 []uint16) out
}

var ops = []op{
	{"validate-utf8", "ValidateUtf8", "utf8", zero, validate},
	{"validate-utf8-err", "ValidateUtf8Err", "utf8-err", zero, validate},
	{"utf8-to-utf16le", "Utf8ToUtf16le", "utf8", func(n int) int { return n + 1 }, utf8ToUtf16},
	{"utf16le-to-utf8", "Utf16leToUtf8", "utf16le", func(n int) int { return 3*n + 3 }, utf16ToUtf8},
	{"base64-encode", "Base64Encode", "binary", base64.StdEncoding.EncodedLen, base64Encode},
	{"base64-decode", "Base64Decode", "base64", base64.StdEncoding.DecodedLen, base64Decode},
}

func zero(int) int { return 0 }

func validate(in *input, _ []byte, _ []uint16) out {
	return out{utf8.Valid(in.bytes), -1}
}

func utf8ToUtf16(in *input, _ []byte, dst []uint16) out {
	dst = dst[:0]
	for b := in.bytes; len(b) > 0; {
		r, size := utf8.DecodeRune(b)
		if r == utf8.RuneError && size == 1 {
			return out{false, -1}
		}
		dst = utf16.AppendRune(dst, r)
		b = b[size:]
	}
	return out{true, 2 * len(dst)}
}

func utf16ToUtf8(in *input, dst []byte, _ []uint16) out {
	dst = dst[:0]
	s := in.units
	for i := 0; i < len(s); i++ {
		r := rune(s[i])
		if utf16.IsSurrogate(r) {
			if i+1 == len(s) {
				return out{false, -1}
			}
			r = utf16.DecodeRune(r, rune(s[i+1]))
			if r == utf8.RuneError {
				return out{false, -1}
			}
			i++
		}
		dst = utf8.AppendRune(dst, r)
	}
	return out{true, len(dst)}
}

func base64Encode(in *input, dst []byte, _ []uint16) out {
	base64.StdEncoding.Encode(dst, in.bytes)
	return out{true, base64.StdEncoding.EncodedLen(len(in.bytes))}
}

func base64Decode(in *input, dst []byte, _ []uint16) out {
	n, err := base64.StdEncoding.Decode(dst, in.bytes)
	if err != nil {
		return out{false, -1}
	}
	return out{true, n}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "bench-go: "+format+"\n", args...)
	os.Exit(1)
}

// load reads every file in bench/corpus-gen/<dir>, smallest first, then by
// name.
func load(dir string) []input {
	path := filepath.Join(corpus, dir)
	entries, err := os.ReadDir(path)
	if err != nil {
		fail("open %s: %v (run `just bench-corpus`)", path, err)
	}
	var inputs []input
	for _, entry := range entries {
		data, err := os.ReadFile(filepath.Join(path, entry.Name()))
		if err != nil {
			fail("read %s: %v", entry.Name(), err)
		}
		// Only the UTF-16 inputs need their code units.
		var units []uint16
		if dir == "utf16le" {
			units = make([]uint16, len(data)/2)
			for i := range units {
				units[i] = binary.LittleEndian.Uint16(data[2*i:])
			}
		}
		inputs = append(inputs, input{entry.Name(), data, units})
	}
	slices.SortFunc(inputs, func(a, b input) int {
		if len(a.bytes) != len(b.bytes) {
			return len(a.bytes) - len(b.bytes)
		}
		if a.name < b.name {
			return -1
		}
		return 1
	})
	return inputs
}

var sink out

func main() {
	testing.Init()
	flag.Parse()
	if flag.NArg() < 1 || (flag.Arg(0) != "bench" && flag.Arg(0) != "check") {
		fmt.Fprintln(os.Stderr, "usage: bench-go bench|check [OP...]")
		os.Exit(2)
	}
	check := flag.Arg(0) == "check"
	wanted := flag.Args()[1:]
	for _, w := range wanted {
		if !slices.ContainsFunc(ops, func(o op) bool { return o.arg == w }) {
			fmt.Fprintf(os.Stderr, "bench-go: unknown operation %s\n", w)
			os.Exit(2)
		}
	}
	benchtime := 100 * time.Millisecond
	if ms := os.Getenv("BENCHTIME_MS"); ms != "" {
		n, err := strconv.Atoi(ms)
		if err != nil {
			fail("BENCHTIME_MS needs a number")
		}
		benchtime = time.Duration(n) * time.Millisecond
	}
	flag.Set("test.benchtime", benchtime.String())

	for _, o := range ops {
		if len(wanted) > 0 && !slices.Contains(wanted, o.arg) {
			continue
		}
		for _, in := range load(o.dir) {
			n := o.outLen(len(in.bytes))
			// Only UTF-8 to UTF-16 writes code units; the rest write bytes.
			var out8 []byte
			var out16 []uint16
			if o.arg == "utf8-to-utf16le" {
				out16 = make([]uint16, n)
			} else {
				out8 = make([]byte, n)
			}
			if check {
				r := o.run(&in, out8, out16)
				if r.n < 0 {
					fmt.Printf("%s/%s\tvalid=%t\n", o.row, in.name, r.valid)
					continue
				}
				h := fnv.New64a()
				if o.arg == "utf8-to-utf16le" {
					for _, u := range out16[:r.n/2] {
						h.Write(binary.LittleEndian.AppendUint16(nil, u))
					}
				} else {
					h.Write(out8[:r.n])
				}
				fmt.Printf("%s/%s\tlen=%d fnv=%016x\n", o.row, in.name, r.n, h.Sum64())
				continue
			}
			result := testing.Benchmark(func(b *testing.B) {
				b.SetBytes(int64(len(in.bytes)))
				for b.Loop() {
					sink = o.run(&in, out8, out16)
				}
			})
			fmt.Printf("Benchmark%s/%s\t%s\n", o.row, in.name, result.String())
		}
	}
}
