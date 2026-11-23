#!/bin/bash
# Join Videos — Services menu installer / Instalador do menu Serviços / Instalador do menu Serviços / Instalador del menú Servicios
# Adds "Photos > Services > Join Videos". Requires the Join Videos app.

LANG_FIRST="$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ",')"
case "$LANG_FIRST" in
  pt-PT*|pt_PT*) CODE=pt-PT ;;
  pt*)           CODE=pt-BR ;;
  es*)           CODE=es ;;
  *)             CODE=en ;;
esac

case "$CODE" in
  pt-PT)
    NAME="Juntar Vídeos"
    M_NOAPP="A app \"Juntar Vídeos\" não está instalada. Instale-a primeiro (JuntarVideos.dmg) e volte a abrir este instalador."
    M_OK="Pronto! No Fotografias, selecione os vídeos e use: Fotografias › Serviços › $NAME"
    M_TIP="Dica: Definições do Sistema › Teclado › Atalhos de teclado › Serviços permite dar-lhe um atalho de teclado." ;;
  pt-BR)
    NAME="Juntar Vídeos"
    M_NOAPP="O app \"Juntar Vídeos\" não está instalado. Instale-o primeiro (JuntarVideos.dmg) e abra este instalador novamente."
    M_OK="Pronto! No Fotos, selecione os vídeos e use: Fotos › Serviços › $NAME"
    M_TIP="Dica: Ajustes do Sistema › Teclado › Atalhos de Teclado › Serviços permite definir um atalho de teclado." ;;
  es)
    NAME="Unir Vídeos"
    M_NOAPP="La app \"Unir Vídeos\" no está instalada. Instálala primero (JuntarVideos.dmg) y vuelve a abrir este instalador."
    M_OK="¡Listo! En Fotos, selecciona los vídeos y usa: Fotos › Servicios › $NAME"
    M_TIP="Consejo: en Ajustes del Sistema › Teclado › Atajos de teclado › Servicios puedes asignarle un atajo." ;;
  *)
    NAME="Join Videos"
    M_NOAPP="The \"Join Videos\" app isn't installed. Install it first (JuntarVideos.dmg) and open this installer again."
    M_OK="Done! In Photos, select the videos and use: Photos › Services › $NAME"
    M_TIP="Tip: System Settings › Keyboard › Keyboard Shortcuts › Services lets you assign a keyboard shortcut." ;;
esac

APP_PATH="$(mdfind "kMDItemCFBundleIdentifier == 'pt.juntarvideos.app'" | head -1)"
if [ -z "$APP_PATH" ]; then
  echo "$M_NOAPP"
  ESC="${M_NOAPP//\"/\\\"}"
  osascript -e "display dialog \"$ESC\" buttons {\"OK\"} default button 1 with icon caution" >/dev/null 2>&1
  exit 1
fi

SERV_DIR="$HOME/Library/Services"
mkdir -p "$SERV_DIR"
# remove versões antigas do Serviço
rm -rf "$SERV_DIR/Juntar Vídeos.workflow" "$SERV_DIR/Unir Vídeos.workflow" "$SERV_DIR/Join Videos.workflow"
W="$SERV_DIR/$NAME.workflow"
mkdir -p "$W/Contents"

cat > "$W/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>NSServices</key>
  <array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>__NAME__</string></dict>
    <key>NSMessage</key><string>runWorkflowAsService</string>
    <key>NSRequiredContext</key><dict><key>NSApplicationIdentifier</key><string>com.apple.Photos</string></dict>
  </dict></array>
</dict></plist>
PL
sed -i '' "s/__NAME__/$NAME/" "$W/Contents/Info.plist"

cat > "$W/Contents/document.wflow" <<'WF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>AMApplicationBuild</key><string>523</string>
  <key>AMApplicationVersion</key><string>2.10</string>
  <key>AMDocumentVersion</key><string>2</string>
  <key>actions</key>
  <array><dict><key>action</key><dict>
    <key>AMAccepts</key><dict><key>Container</key><string>List</string><key>Optional</key><true/><key>Types</key><array><string>com.apple.cocoa.string</string></array></dict>
    <key>AMActionVersion</key><string>2.0.3</string>
    <key>AMApplication</key><array><string>Automator</string></array>
    <key>AMProvides</key><dict><key>Container</key><string>List</string><key>Types</key><array><string>com.apple.cocoa.string</string></array></dict>
    <key>ActionBundlePath</key><string>/System/Library/Automator/Run Shell Script.action</string>
    <key>ActionName</key><string>Run Shell Script</string>
    <key>ActionParameters</key><dict>
      <key>COMMAND_STRING</key><string>open -b pt.juntarvideos.app "juntarvideos://from-photos"</string>
      <key>CheckedForUserDefaultShell</key><true/>
      <key>inputMethod</key><integer>1</integer>
      <key>shell</key><string>/bin/bash</string>
      <key>source</key><string></string>
    </dict>
    <key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
    <key>CFBundleVersion</key><string>2.0.3</string>
    <key>CanShowSelectedItemsWhenRun</key><false/>
    <key>CanShowWhenRun</key><true/>
    <key>Category</key><array><string>AMCategoryUtilities</string></array>
    <key>Class Name</key><string>RunShellScriptAction</string>
    <key>InputUUID</key><string>B1C0A4E2-0C57-4C1E-9B7A-4D3E8F1A2B01</string>
    <key>OutputUUID</key><string>B1C0A4E2-0C57-4C1E-9B7A-4D3E8F1A2B02</string>
    <key>UUID</key><string>B1C0A4E2-0C57-4C1E-9B7A-4D3E8F1A2B03</string>
    <key>UnlocalizedApplications</key><array><string>Automator</string></array>
    <key>arguments</key><dict/>
    <key>isViewVisible</key><true/>
    <key>location</key><string>309.000000:253.000000</string>
    <key>nibPath</key><string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
  </dict></dict></array>
  <key>connectors</key><dict/>
  <key>workflowMetaData</key>
  <dict>
    <key>serviceInputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
    <key>serviceOutputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
    <key>serviceProcessesInput</key><integer>0</integer>
    <key>workflowTypeIdentifier</key><string>com.apple.Automator.servicesMenu</string>
  </dict>
</dict></plist>
WF

/System/Library/CoreServices/pbs -update 2>/dev/null || true

echo
echo "$M_OK"
echo "$M_TIP"
