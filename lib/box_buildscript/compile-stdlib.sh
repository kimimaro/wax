#!/bin/zsh

# Compiles the wax stdlib into one file
${PROJECT_DIR}/Wax/buildscript/lua32 "$PROJECT_DIR/Wax/buildscript/luac32.lua" wax wax32.dat "$PROJECT_DIR/Wax/stdlib/" "$PROJECT_DIR/Wax/stdlib/init.lua" -L "$PROJECT_DIR/Wax/stdlib"/**/*.lua

# Dumps the compiled file into a byte array, then it places this into the source code
cat > "$PROJECT_DIR/Wax/wax_stdlib32.h" <<EOF
// DO NOT MODIFY
// This is auto generated, it contains a compiled version of the wax stdlib
#define WAX_STDLIB32 {$(hexdump -v -e '1/1 "%d,"' wax32.dat)}
EOF

# clean up
rm wax32.dat


# Compiles the wax stdlib into one file
${PROJECT_DIR}/Wax/buildscript/lua64 "$PROJECT_DIR/Wax/buildscript/luac64.lua" wax wax64.dat "$PROJECT_DIR/Wax/stdlib/" "$PROJECT_DIR/Wax/stdlib/init.lua" -L "$PROJECT_DIR/Wax/stdlib"/**/*.lua

# Dumps the compiled file into a byte array, then it places this into the source code
cat > "$PROJECT_DIR/Wax/wax_stdlib64.h" <<EOF
// DO NOT MODIFY
// This is auto generated, it contains a compiled version of the wax stdlib
#define WAX_STDLIB64 {$(hexdump -v -e '1/1 "%d,"' wax64.dat)}
EOF

# clean up
rm wax64.dat