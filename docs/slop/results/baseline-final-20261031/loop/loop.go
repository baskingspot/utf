// bench-go's timed loop around a call that returns at once.
package main

import (
	"flag"
	"fmt"
	"testing"
)

type out struct {
	kind  byte
	value int
}
type input struct{ bytes []byte }
type buffers struct{ b8 []byte }
type fn func(in *input, dst buffers) out

//go:noinline
func noop(in *input, _ buffers) out { return out{'c', len(in.bytes)} }

var sink out

func main() {
	testing.Init()
	flag.Set("test.benchtime", "50000000x")
	in := input{bytes: make([]byte, 16)}
	b := buffers{b8: make([]byte, 64)}
	var run fn = noop
	for i := 0; i < 5; i++ {
		r := testing.Benchmark(func(tb *testing.B) {
			for tb.Loop() {
				sink = run(&in, b)
			}
		})
		fmt.Printf("go %.3f ns/op\n", float64(r.T.Nanoseconds())/float64(r.N))
	}
}
