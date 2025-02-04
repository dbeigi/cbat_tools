set -x

dummy_dir=../dummy

compile () {
  make
}

run () {
  bap $dummy_dir/hello_world.out --pass=wp \
    --wp-compare=true \
    --wp-file1=main-original.bpj \
    --wp-file2=main-rop.bpj \
    --wp-inline=true
}

compile && run
