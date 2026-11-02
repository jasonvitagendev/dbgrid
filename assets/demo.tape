# Re-records assets/demo.gif. Needs vhs (brew install vhs) and the test database
# from CONTRIBUTING.md on localhost:5432. Run from the repository root: vhs assets/demo.tape
Output assets/demo.gif
Set Shell zsh
Set FontSize 14
Set Width 1500
Set Height 800
Set Framerate 20
Set Padding 10
Set Theme "Catppuccin Mocha"

Hide
Type "export DBGRID_TEST_URL=postgres://postgres@localhost:5432/dbgrid_test" Enter
Type "clear" Enter
Type "nvim -u tests/minimal_init.lua --cmd 'set notermguicolors' -c 'set laststatus=0 showtabline=0' -c 'luafile tests/demo.lua'" Enter
Sleep 2s
Show

Sleep 2s
Type "]c"
Sleep 800ms
Enter
Sleep 2500ms
Ctrl+w
Type "h"
Sleep 600ms
Type "jjj"
Sleep 500ms
Type "\v"
Sleep 2500ms
Type "\v"
Sleep 800ms
Ctrl+w
Type "l"
Sleep 400ms
Type "[c"
Sleep 2s
