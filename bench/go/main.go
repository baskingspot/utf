// Command bench-go is the Go arm of `just bench-compare` (bench/README.md):
// the standard library's unicode/utf8, unicode/utf16, and encoding/base64.
//
// Usage, from the repository root, with the same contract as every arm:
//
//	bench-go bench [OP...]   rows in the Go benchmark format
//	bench-go check [OP...]   one checksum line per row
//
// OP is a name from bench/ops.tsv, which also gives each operation's row
// name, corpus directory, and output size; none means all. BENCHTIME_MS
// (default 100) is how long each row's timed loop runs; Go's own
// testing.Benchmark sizes it.
//
// The standard library has no UTF-8 validator that reports a position, so
// both validation operations time utf8.Valid. It has no slice-to-slice
// transcoder either: the conversions decode one rune at a time and store
// or append it to a preallocated buffer, which is how a Go program avoids
// allocating.
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
	"strings"
	"testing"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

const corpus = "bench/corpus-gen"

// out is what one call returns, for the checksum: validity, the bytes
// written, or a count.
type out struct {
	kind  byte // 'v', 'l', or 'c'
	value int
}

func valid(v bool) out {
	if v {
		return out{'v', 1}
	}
	return out{'v', 0}
}

type input struct {
	name    string
	bytes   []byte
	units16 []uint16
	units32 []rune
}

type buffers struct {
	b8  []byte
	b16 []uint16
	b32 []rune
}

// op is an operation from bench/ops.tsv.
type op struct {
	arg, row, dir string
	num, den      int
}

func (o op) outLen(n int) int {
	if o.num == 0 {
		return 0
	}
	return n*o.num/o.den + 64
}

type fn func(in *input, dst buffers) out

var strict = base64.StdEncoding.Strict()

// impls maps each operation this arm has to its function. StdEncoding
// rejects a missing pad, so it does part of the strict decode's work in
// base64-decode too; it skips CR and LF, so it decodes MIME's lines.
var impls = map[string]fn{
	"validate-utf8":        validate,
	"validate-utf8-err":    validate,
	"utf8-to-utf16le":      utf8ToUtf16,
	"utf8-to-utf32":        utf8ToUtf32,
	"utf16le-to-utf8":      utf16ToUtf8,
	"utf32-to-utf8":        utf32ToUtf8,
	"count-utf8":           count,
	"base64-encode":        encoder(base64.StdEncoding),
	"base64-encode-url":    encoder(base64.RawURLEncoding),
	"base64-decode":        decoder(base64.StdEncoding),
	"base64-decode-url":    decoder(base64.RawURLEncoding),
	"base64-decode-strict": decoder(strict),
	"base64-decode-mime":   decoder(base64.StdEncoding),
}

func validate(in *input, _ buffers) out {
	return valid(utf8.Valid(in.bytes))
}

func count(in *input, _ buffers) out {
	return out{'c', utf8.RuneCount(in.bytes)}
}

func utf8ToUtf16(in *input, b buffers) out {
	dst := b.b16[:0]
	for s := in.bytes; len(s) > 0; {
		r, size := utf8.DecodeRune(s)
		if r == utf8.RuneError && size == 1 {
			return valid(false)
		}
		dst = utf16.AppendRune(dst, r)
		s = s[size:]
	}
	return out{'l', 2 * len(dst)}
}

func utf8ToUtf32(in *input, b buffers) out {
	dst := b.b32
	n := 0
	for s := in.bytes; len(s) > 0; n++ {
		r, size := utf8.DecodeRune(s)
		if r == utf8.RuneError && size == 1 {
			return valid(false)
		}
		dst[n] = r
		s = s[size:]
	}
	return out{'l', 4 * n}
}

func utf16ToUtf8(in *input, b buffers) out {
	dst := b.b8[:0]
	s := in.units16
	for i := 0; i < len(s); i++ {
		r := rune(s[i])
		if utf16.IsSurrogate(r) {
			if i+1 == len(s) {
				return valid(false)
			}
			r = utf16.DecodeRune(r, rune(s[i+1]))
			if r == utf8.RuneError {
				return valid(false)
			}
			i++
		}
		dst = utf8.AppendRune(dst, r)
	}
	return out{'l', len(dst)}
}

func utf32ToUtf8(in *input, b buffers) out {
	dst := b.b8[:0]
	for _, r := range in.units32 {
		if !utf8.ValidRune(r) {
			return valid(false)
		}
		dst = utf8.AppendRune(dst, r)
	}
	return out{'l', len(dst)}
}

func encoder(e *base64.Encoding) fn {
	return func(in *input, b buffers) out {
		e.Encode(b.b8, in.bytes)
		return out{'l', e.EncodedLen(len(in.bytes))}
	}
}

func decoder(e *base64.Encoding) fn {
	return func(in *input, b buffers) out {
		n, err := e.Decode(b.b8, in.bytes)
		if err != nil {
			return valid(false)
		}
		return out{'l', n}
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "bench-go: "+format+"\n", args...)
	os.Exit(1)
}

func readOps() []op {
	text, err := os.ReadFile("bench/ops.tsv")
	if err != nil {
		fail("open bench/ops.tsv: %v (run from the repository root)", err)
	}
	var ops []op
	for _, line := range strings.Split(string(text), "\n") {
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.Split(line, "\t")
		num, den, _ := strings.Cut(f[3], "/")
		if den == "" {
			den = "1"
		}
		o := op{arg: f[0], row: f[1], dir: f[2]}
		o.num, _ = strconv.Atoi(num)
		o.den, _ = strconv.Atoi(den)
		ops = append(ops, o)
	}
	for arg := range impls {
		if !slices.ContainsFunc(ops, func(o op) bool { return o.arg == arg }) {
			fail("operation %s is not in bench/ops.tsv", arg)
		}
	}
	return ops
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
		in := input{name: entry.Name(), bytes: data}
		// Only the UTF-16 and UTF-32 inputs need their code units.
		if strings.Contains(dir, "utf16le") {
			in.units16 = make([]uint16, len(data)/2)
			for i := range in.units16 {
				in.units16[i] = binary.LittleEndian.Uint16(data[2*i:])
			}
		}
		if strings.Contains(dir, "utf32") {
			in.units32 = make([]rune, len(data)/4)
			for i := range in.units32 {
				in.units32[i] = rune(binary.LittleEndian.Uint32(data[4*i:]))
			}
		}
		inputs = append(inputs, in)
	}
	slices.SortFunc(inputs, func(a, b input) int {
		if len(a.bytes) != len(b.bytes) {
			return len(a.bytes) - len(b.bytes)
		}
		return strings.Compare(a.name, b.name)
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
	ops := readOps()
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
		run, ok := impls[o.arg]
		if !ok {
			fmt.Printf("# SKIP Benchmark%s: Go's standard library has no equivalent\n", o.row)
			continue
		}
		for _, in := range load(o.dir) {
			n := o.outLen(len(in.bytes))
			// Each buffer holds the operation's output code units.
			var b buffers
			switch {
			case strings.HasSuffix(o.arg, "-to-utf16le"):
				b.b16 = make([]uint16, n/2)
			case strings.HasSuffix(o.arg, "-to-utf32"):
				b.b32 = make([]rune, n/4)
			default:
				b.b8 = make([]byte, n)
			}
			if check {
				r := run(&in, b)
				switch r.kind {
				case 'v':
					fmt.Printf("%s/%s\tvalid=%t\n", o.row, in.name, r.value == 1)
				case 'c':
					fmt.Printf("%s/%s\tcount=%d\n", o.row, in.name, r.value)
				default:
					// Wide output is hashed as its little-endian bytes.
					h := fnv.New64a()
					switch {
					case b.b16 != nil:
						for _, u := range b.b16[:r.value/2] {
							h.Write(binary.LittleEndian.AppendUint16(nil, u))
						}
					case b.b32 != nil:
						for _, u := range b.b32[:r.value/4] {
							h.Write(binary.LittleEndian.AppendUint32(nil, uint32(u)))
						}
					default:
						h.Write(b.b8[:r.value])
					}
					fmt.Printf("%s/%s\tlen=%d fnv=%016x\n", o.row, in.name, r.value, h.Sum64())
				}
				continue
			}
			// Fault every page in before timing: a masked store that
			// overhangs into a page nothing has written takes a microcode
			// assist on every call.
			clear(b.b8)
			clear(b.b16)
			clear(b.b32)
			result := testing.Benchmark(func(tb *testing.B) {
				tb.SetBytes(int64(len(in.bytes)))
				for tb.Loop() {
					sink = run(&in, b)
				}
			})
			fmt.Printf("Benchmark%s/%s\t%s\n", o.row, in.name, result.String())
		}
	}
}
