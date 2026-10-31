hb () 
{ 
    ( cd $1/bench && taskset -c 0-1 nix develop /home/user/workspace/repo -c zig build -p /home/user/workspace/ab/out/h-$2 -Dutf-cpu=${3:-native} ${4:+-Dutf-dispatch=$4} 2>&1 | grep -v "warning" | tail -5 )
}
