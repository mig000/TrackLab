#!/bin/zsh
# swift test só com as Command Line Tools: o plugin de macros do swift-testing não está no caminho padrão.
cd "${0:A:h}"
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
