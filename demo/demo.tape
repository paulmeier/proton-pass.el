# Records demo/demo.gif with https://github.com/charmbracelet/vhs
#   make demo
# Runs terminal Emacs against demo/pass-cli (a fake CLI, made-up vault).

Output demo/demo.gif

Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 720
Set Padding 16
Set TypingSpeed 60ms
Set Theme "Builtin Dark"

Env COLORTERM "truecolor"
Env TERM "xterm-256color"
Env PROTON_PASS_DEMO_STATE "/tmp/proton-pass-demo.json"

Hide
Type "rm -f /tmp/proton-pass-demo.json; clear; ${EMACS:-emacs} -nw -Q -l demo/init.el" Enter
Sleep 2.5s
Show

# The vault browser
Sleep 1.5s
Down 3
Sleep 700ms

# View an item: secrets are masked
Enter
Sleep 2.5s

# Copy the password, then a TOTP code -- both clear themselves after 45s
Type "w"
Sleep 2s
Type "o"
Sleep 2s
Type "q"
Sleep 1s

# Create a login with a generated password
Type "I"
Sleep 600ms
Type "Mastodon"
Enter
Sleep 400ms
Type "octocat"
Enter
Sleep 2.5s

# Move an item to trash
Ctrl+S
Type "Home"
Enter
Sleep 600ms
Type "d"
Sleep 600ms
Type "yes"
Enter
Sleep 2s

# From any other buffer: copy a password with completion. Bound to C-t
# in demo/init.el because M-x and C-c don't make it through the recorder.
Type "q"
Sleep 800ms
Ctrl+T
Sleep 800ms
Type "tail"
Sleep 800ms
Enter
Sleep 3s
