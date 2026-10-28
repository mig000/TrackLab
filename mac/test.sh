#!/bin/zsh
# swift test. As Command Line Tools 26 trazem o _Testing_Foundation.framework sem o módulo Swift, então o
# swift-testing não compila só com elas; se o Xcode estiver instalado, os testes usam o dele (sem mudar o
# xcode-select). Sem Xcode, o caminho das CLT (plugin de macros fora do caminho padrão).
cd "${0:A:h}"
xcode=/Applications/Xcode.app/Contents/Developer
if [[ -z ${DEVELOPER_DIR:-} && -d $xcode/Platforms/MacOSX.platform/Developer/Library/Frameworks/_Testing_Foundation.framework/Modules ]]; then
  export DEVELOPER_DIR=$xcode
  exec swift test "$@"
fi
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
